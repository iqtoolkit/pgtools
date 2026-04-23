/*
 * Script: sql/diagnostics/cache-hit.sql
 *
 * Purpose: Calculates and displays table and index cache hit rates.
 *
 * Description:
 * This query provides a crucial performance metric: the percentage of blocks
 * read from the PostgreSQL buffer cache versus from disk. High cache hit
 * rates (typically > 90-95%) indicate efficient memory usage and reduced
 * reliance on slower disk I/O.
 *
 * Red Flags:
 * - `table_hit_rate_pct` or `index_hit_rate_pct` consistently below 90-95%:
 *   Indicates significant I/O pressure, potentially due to insufficient
 *   `shared_buffers`, inefficient queries, or missing/bad indexes.
 * - `total_reads` is very high for a table/index with a low hit rate:
 *   This object is frequently accessed but rarely found in cache.
 *
 * Interpretation:
 * - `table_hit_rate_pct`: Percentage of table blocks found in cache.
 * - `index_hit_rate_pct`: Percentage of index blocks found in cache.
 * - `total_reads`: Total number of blocks read (from cache + disk).
 * - `total_hits`: Total number of blocks found in cache.
 *
 * Safety:
 * This script is read-only. It queries `pg_stat_user_tables` and
 * `pg_stat_user_indexes`, which are standard PostgreSQL statistics views
 * designed for efficient diagnostic use. The `statement_timeout` set by
 * `pgtools.sh` provides a safety guarantee.
 */
SELECT
    relname AS object_name,
    CASE WHEN relkind = 'r' THEN 'TABLE' WHEN relkind = 'i' THEN 'INDEX' END AS object_type,
    blks_read + blks_hit AS total_reads,
    blks_hit AS total_hits,
    ROUND((blks_hit * 100.0 / NULLIF(blks_read + blks_hit, 0)), 2) AS hit_rate_pct
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND (blks_read + blks_hit) > 0 -- Only show objects that have been accessed
UNION ALL
SELECT
    relname AS object_name,
    'INDEX' AS object_type,
    idx_blks_read + idx_blks_hit AS total_reads,
    idx_blks_hit AS total_hits,
    ROUND((idx_blks_hit * 100.0 / NULLIF(idx_blks_read + idx_blks_hit, 0)), 2) AS hit_rate_pct
FROM pg_stat_all_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND (idx_blks_read + idx_blks_hit) > 0 -- Only show indexes that have been accessed
ORDER BY hit_rate_pct ASC, total_reads DESC
LIMIT 50;