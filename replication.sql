/*
 * Script: sql/diagnostics/replication.sql
 *
 * Purpose: Monitors PostgreSQL streaming replication and replication slot status.
 *
 * Description:
 * This script provides a two-part overview of the database's replication health.
 * The first part shows the status of active streaming replication connections,
 * including their state and various lag metrics. The second part lists all
 * replication slots and their current lag, which is crucial for logical
 * replication or tools like pg_basebackup.
 *
 * Red Flags:
 * - `state` is not 'streaming': A replica might be disconnected or catching up.
 * - `replay_lag_seconds` is consistently increasing or very high: Indicates
 *   the replica is falling behind the primary.
 * - `lag_bytes` for a replication slot is growing: The consumer of the slot
 *   is not keeping up, potentially leading to WAL retention issues on the primary.
 * - `active = 'f'` for a replication slot: The slot is not currently in use,
 *   but might still be retaining WAL, causing disk space issues.
 *
 * Interpretation:
 * - `pg_stat_replication` provides real-time status of connected standbys.
 * - `pg_replication_slots` shows the status of persistent WAL retention points.
 * - High lag in either section warrants investigation into network, I/O, or
 *   workload on the primary/replica.
 *
 * Safety:
 * This script is read-only. It queries `pg_stat_replication` and
 * `pg_replication_slots`, which are standard PostgreSQL views designed for
 * efficient diagnostic use. The `statement_timeout` set by `pgtools.sh`
 * provides a safety guarantee.
 */

\echo '--- Streaming Replication Status ---'
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    sync_state,
    sync_priority,
    backend_start,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) AS sent_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn)) AS write_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)) AS flush_lag_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
    EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS replay_lag_seconds
FROM pg_stat_replication
ORDER BY replay_lag_bytes DESC;

\echo E'\n--- Replication Slot Status ---'
SELECT
    slot_name,
    plugin,
    slot_type,
    active,
    restart_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_bytes
FROM pg_replication_slots
ORDER BY lag_bytes DESC;