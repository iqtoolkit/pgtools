/*
 * Script: chunk_health.sql
 * Purpose: Assess TimescaleDB chunk health — count, sizing, and interval configuration
 *
 * Usage:
 *   psql -d database_name -f timescaledb/chunk_health.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - TimescaleDB extension installed
 *   - Privileges: Any user with access to timescaledb_information views
 *
 * Output:
 *   1. Chunk count and size distribution per hypertable
 *   2. Chunk time interval configuration per hypertable
 *
 * Red Flags:
 *   - Chunk counts over ~500 per hypertable (planning overhead)
 *   - Huge variance between min and max chunk size
 *   - Average chunk size wildly off from ideal (~25% of shared_buffers)
 *   - Time interval too large for high-ingest tables or too small for low-ingest
 *
 * Notes:
 *   - Use set_chunk_time_interval() to fix going forward (does not reshape existing chunks)
 *   - Chunk count is the #1 silent cause of slow query planning
 */

\echo '=== Chunk Count and Size Per Hypertable ==='
SELECT
    hypertable_name,
    count(*)                                    AS chunk_count,
    pg_size_pretty(sum(total_bytes))            AS total_size,
    pg_size_pretty(avg(total_bytes)::bigint)    AS avg_chunk_size,
    pg_size_pretty(min(total_bytes))            AS min_chunk,
    pg_size_pretty(max(total_bytes))            AS max_chunk
FROM timescaledb_information.chunks
GROUP BY hypertable_name
ORDER BY chunk_count DESC;

\echo ''
\echo '=== Chunk Time Interval Configuration ==='
SELECT
    hypertable_name,
    time_interval,
    integer_interval,
    num_dimensions
FROM timescaledb_information.dimensions;
