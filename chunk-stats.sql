/*
 * Script: sql/timescale/chunk-stats.sql
 *
 * Purpose: Provides a high-level overview of hypertable chunk health.
 *
 * Description:
 * This query is the #1 triage tool for TimescaleDB performance issues. It
 * summarizes the number of chunks, total size, and average/min/max chunk
 * size for each hypertable.
 *
 * Red Flags:
 * - High `chunk_count` (e.g., > 500): Can lead to high query planning overhead.
 * - Large variance between `min_chunk` and `max_chunk`: Suggests inconsistent data ingestion.
 * - `avg_chunk_size` too large or small: Ideal size is ~25% of shared_buffers for the hot set.
 *
 * Safety:
 * This script is read-only and uses TimescaleDB's information views, which are
 * optimized for frequent access. Execution time is typically very fast.
 */
SELECT
  hypertable_name,
  count(*) AS chunk_count,
  pg_size_pretty(sum(total_bytes)) AS total_size,
  pg_size_pretty(avg(total_bytes)::bigint) AS avg_chunk_size,
  pg_size_pretty(min(total_bytes)) AS min_chunk,
  pg_size_pretty(max(total_bytes)) AS max_chunk
FROM timescaledb_information.chunks
GROUP BY hypertable_name
ORDER BY chunk_count DESC;