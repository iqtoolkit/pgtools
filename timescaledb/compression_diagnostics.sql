/*
 * Script: compression_diagnostics.sql
 * Purpose: Evaluate TimescaleDB compression configuration, effectiveness, and backlog
 *
 * Usage:
 *   psql -d database_name -f timescaledb/compression_diagnostics.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - TimescaleDB extension installed
 *   - Privileges: Any user with access to timescaledb_information views
 *
 * Output:
 *   1. Compression settings and policy status per hypertable
 *   2. Compression effectiveness (before/after sizes, ratio)
 *   3. Chunks that should be compressed but aren't (compression backlog)
 *
 * Interpretation:
 *   - segmentby should match the high-cardinality column you filter on (device_id, user_id, etc.)
 *   - segmentby NULL or wrong → bad compression ratios AND slow decompression queries
 *   - Healthy time-series data typically compresses 90%+; <70% suggests misconfigured segmentby/orderby
 *   - Large backlog of uncompressed chunks indicates background worker exhaustion
 *
 * Notes:
 *   - Check timescaledb.max_background_workers if compression is falling behind
 *   - See background_jobs.sql for worker saturation diagnostics
 */

\echo '=== Compression Settings and Policy Status ==='
SELECT
    ht.hypertable_name,
    cs.segmentby,
    cs.orderby,
    j.job_id,
    j.schedule_interval,
    js.last_run_status,
    js.last_successful_finish,
    js.total_failures
FROM timescaledb_information.hypertables ht
LEFT JOIN timescaledb_information.compression_settings cs
    ON cs.hypertable_name = ht.hypertable_name
LEFT JOIN timescaledb_information.jobs j
    ON j.hypertable_name = ht.hypertable_name
    AND j.proc_name = 'policy_compression'
LEFT JOIN timescaledb_information.job_stats js
    ON js.job_id = j.job_id;

\echo ''
\echo '=== Compression Effectiveness ==='
SELECT
    hypertable_name,
    pg_size_pretty(before_compression_total_bytes)  AS before,
    pg_size_pretty(after_compression_total_bytes)   AS after,
    round(
        100.0 * (1 - after_compression_total_bytes::numeric
                 / NULLIF(before_compression_total_bytes, 0)),
        1
    ) AS compression_pct
FROM hypertable_compression_stats();

\echo ''
\echo '=== Uncompressed Chunks Past Compression Window ==='
SELECT
    hypertable_name,
    chunk_name,
    range_end,
    pg_size_pretty(total_bytes) AS size,
    is_compressed
FROM timescaledb_information.chunks
WHERE NOT is_compressed
    AND range_end < now() - INTERVAL '1 day'
ORDER BY range_end;
