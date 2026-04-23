/*
 * Script: sql/diagnostics/bloat.sql
 *
 * Purpose: Estimates table bloat and identifies candidates for VACUUM/REINDEX.
 *
 * Description:
 * This query provides a high-level overview of table bloat by showing the
 * number of dead tuples and their percentage relative to live tuples. High
 * dead tuple counts indicate that a table needs vacuuming to reclaim space
 * and improve performance.
 *
 * Red Flags:
 * - `dead_tuple_percent` > 20%: Indicates significant bloat, consider VACUUM.
 * - `dead_tuple_percent` > 50%: Critical bloat, immediate VACUUM recommended.
 * - `last_autovacuum` is NULL or very old: Autovacuum might not be running
 *   or is misconfigured for this table.
 *
 * Interpretation:
 * - `total_size`: Total disk space used by the table, including indexes and TOAST.
 * - `dead_tuples`: Rows marked for deletion but not yet removed by VACUUM.
 * - `live_tuples`: Active, visible rows in the table.
 * - `dead_tuple_percent`: The key metric for bloat. A higher percentage means
 *   more wasted space and potentially slower queries.
 *
 * Safety:
 * This script is read-only. It queries `pg_stat_user_tables`, a standard
 * PostgreSQL statistics view, which is designed for efficient diagnostic use.
 * The `statement_timeout` set by `pgtools.sh` provides a safety guarantee.
 */
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    n_dead_tup AS dead_tuples,
    n_live_tup AS live_tuples,
    ROUND(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_tuple_percent,
    pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS table_size,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 0 -- Only show tables with dead tuples
ORDER BY n_dead_tup DESC
LIMIT 50;