/*
 * Script: replication_tiering.sql
 * Purpose: Monitor TimescaleDB Tiger Lake / tiered storage replication slot health
 *
 * Usage:
 *   psql -d database_name -f timescaledb/replication_tiering.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - TimescaleDB extension installed
 *   - Privileges: Superuser or pg_monitor role (for pg_replication_slots)
 *
 * Output:
 *   Replication slots related to Tiger Lake / Iceberg tiering with WAL lag
 *
 * Interpretation:
 *   - Growing lag_bytes that doesn't come back down means replication is stuck
 *   - Check for long-running CAGG refreshes on the source hypertable (known interaction)
 *   - Inactive slots hold WAL on disk indefinitely — drop or re-enable them
 *
 * Notes:
 *   - This script filters for Tiger Lake / Iceberg-related slots only
 *   - For general replication slot monitoring, see monitoring/replication.sql
 */

\ir ../lib/preflight.sql
DO $preflight$ BEGIN PERFORM pg_temp.pgtools_check('pg_monitor', 'timescaledb'); END $preflight$;

\echo '=== Tiger Lake / Tiered Storage Replication Slots ==='
SELECT
    slot_name,
    plugin,
    slot_type,
    active,
    restart_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS lag_bytes
FROM pg_replication_slots
WHERE slot_name LIKE '%tigerlake%'
   OR plugin LIKE '%iceberg%';
