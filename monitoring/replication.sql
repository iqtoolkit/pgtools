/*
 * Script: replication.sql
 * Purpose: Monitor replication lag and slot status for streaming replication
 *
 * ANNOTATED EXAMPLE:
 *   # Monitor replication status on primary server
 *   psql -d production -f monitoring/replication.sql
 *
 *   # Check replication status every 30 seconds
 *   watch -n 30 "psql -d production -f monitoring/replication.sql"
 *
 *   # Save replication status for trending
 *   psql -d production -f monitoring/replication.sql > replication_$(date +%Y%m%d_%H%M).log
 *
 *   # Check specific standby server
 *   psql -d production -f monitoring/replication.sql | grep "standby-1"
 *
 * SAMPLE OUTPUT - Replication Slots:
 *   slot_name    | slot_type | database | active | replication_lag_bytes | flush_lag_bytes
 *   -------------|-----------|----------|--------|----------------------|----------------
 *   standby_slot | physical  | NULL     | t      | 256 MB               | 128 MB
 *   backup_slot  | physical  | NULL     | f      | 2048 MB              | 2048 MB
 *
 * SAMPLE OUTPUT - Standby Status:
 *   application_name | client_addr   | state     | sync_state | write_lag_time | flush_lag_time | replay_lag_time
 *   ------------------|---------------|-----------|------------|----------------|----------------|----------------
 *   standby-1        | 192.168.1.10  | streaming | sync       | 00:00:01       | 00:00:02       | 00:00:03
 *   standby-2        | 192.168.1.11  | streaming | async      | 00:00:15       | 00:00:18       | 00:00:22
 *   backup-server    | 192.168.1.20  | startup   | async      | NULL           | NULL           | NULL
 *
 * INTERPRETATION:
 *   - standby-1: Healthy synchronous replica with minimal lag
 *   - standby-2: Healthy asynchronous replica with acceptable lag
 *   - backup-server: In startup/recovery mode (not yet streaming)
 *   - backup_slot: Inactive slot accumulating WAL (potential issue)
 *
 * REPLICATION STATES:
 *   - startup: Standby is starting up or in recovery
 *   - catchup: Standby is catching up to primary
 *   - streaming: Normal replication state (healthy)
 *   - backup: Used by backup tools (pg_basebackup)
 *
 * SYNC STATES:
 *   - sync: Synchronous replication (commits wait for confirmation)
 *   - async: Asynchronous replication (commits don't wait)
 *   - potential: Can become sync if current sync fails
 *
 * ALERT THRESHOLDS:
 *   CRITICAL (Immediate Action):
 *   - Replication lag > 5 minutes on sync replicas
 *   - Replication lag > 2 GB on any replica
 *   - Inactive slots with > 10 GB lag
 *   - No active replicas (single point of failure)
 *
 *   WARNING (Monitor Closely):
 *   - Replication lag > 1 minute on sync replicas
 *   - Replication lag > 10 minutes on async replicas
 *   - Replication lag > 1 GB on any replica
 *   - Standby in 'catchup' state for > 30 minutes
 *
 *   MONITOR (Track Trends):
 *   - Replication lag > 30 seconds consistently
 *   - Growing lag trends over time
 *   - Frequent sync/async state changes
 *
 * TROUBLESHOOTING STEPS:
 *   1. High Lag Issues:
 *      # Check network connectivity to standby
 *      ping standby_server_ip
 *      
 *      # Check standby server resources
 *      ssh standby_server "top; df -h; iostat"
 *      
 *      # Review WAL shipping settings
 *      SHOW archive_command;
 *      SHOW wal_level;
 *
 *   2. Inactive Slots:
 *      # Remove unused replication slots (CAREFUL!)
 *      SELECT pg_drop_replication_slot('unused_slot_name');
 *
 *   3. Standby Connection Issues:
 *      # Check standby server logs
 *      tail -f /var/log/postgresql/postgresql-*.log
 *      
 *      # Verify standby configuration
 *      # Check primary_conninfo in postgresql.conf or recovery.conf
 *
 * MAINTENANCE ACTIONS:
 *   # Monitor replication slot disk usage
 *   SELECT slot_name, 
 *          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
 *   FROM pg_replication_slots 
 *   WHERE pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824; -- 1GB
 *
 *   # Check WAL file accumulation
 *   SELECT count(*) as wal_file_count 
 *   FROM pg_ls_waldir() 
 *   WHERE name ~ '^[0-9A-F]{24}$';
 *
 * PERFORMANCE TUNING:
 *   # Optimize for replication performance
 *   ALTER SYSTEM SET wal_sender_timeout = '60s';
 *   ALTER SYSTEM SET wal_receiver_timeout = '60s';
 *   ALTER SYSTEM SET max_wal_senders = 10;
 *   ALTER SYSTEM SET wal_keep_segments = 64; -- PG < 13
 *   ALTER SYSTEM SET wal_keep_size = '1GB';  -- PG 13+
 *
 * MONITORING INTEGRATION:
 *   # Export metrics for Prometheus/Grafana
 *   psql -d production -t -A -F',' -f monitoring/replication.sql > replication_metrics.csv
 *
 *   # Automated alerting example
 *   LAG_SECONDS=$(psql -d production -t -c "SELECT EXTRACT(epoch FROM (now()-pg_last_xact_replay_timestamp()))")
 *   if (( $(echo "$LAG_SECONDS > 300" | bc -l) )); then
 *       echo "ALERT: Replication lag exceeds 5 minutes" | mail -s "PostgreSQL Replication Alert" admin@company.com
 *   fi
 *
 * Requirements:
 *   - PostgreSQL 15+ (streaming replication)
 *   - Privileges: Superuser or pg_monitor role (to access replication views)
 *   - Must run on PRIMARY server (not standby)
 *   - Network connectivity to standby servers for accurate monitoring
 *
 * Output Description:
 *   Replication Slots:
 *   - slot_name: Name of the replication slot
 *   - slot_type: physical (streaming) or logical (logical replication)
 *   - database: Database name (NULL for physical slots)
 *   - active: Whether slot is currently active
 *   - replication_lag_bytes: Bytes behind from restart LSN
 *   - flush_lag_bytes: Bytes behind from confirmed flush LSN
 *
 *   Standby Status:
 *   - application_name: Name configured in standby's primary_conninfo
 *   - client_addr: IP address of standby server
 *   - state: Current replication state
 *   - sync_state: Synchronization mode
 *   - write_lag_time: Time lag for write confirmation
 *   - flush_lag_time: Time lag for flush confirmation  
 *   - replay_lag_time: Time lag for replay confirmation
 *
 * DISASTER RECOVERY NOTES:
 *   - Document all standby server configurations
 *   - Test failover procedures regularly
 *   - Monitor replication lag during peak hours
 *   - Ensure adequate WAL retention for recovery
 *   - Keep standby servers synchronized with primary configuration changes
 */

\ir ../lib/preflight.sql
DO $preflight$ BEGIN PERFORM pg_temp.pgtools_check('pg_monitor', NULL); END $preflight$;

-- Replication slots and lag
SELECT
    slot_name,
    slot_type,
    database,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS replication_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS flush_lag_bytes
FROM pg_replication_slots
ORDER BY active DESC, slot_name;

-- Standby status and time lag
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) AS sending_lag,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn)) AS write_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)) AS flush_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
    write_lag AS write_lag_time,
    flush_lag AS flush_lag_time,
    replay_lag AS replay_lag_time
FROM pg_stat_replication
ORDER BY application_name;
--Replication lag
SELECT now()-pg_last_xact_replay_timestamp() as replication_lag;