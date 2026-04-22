/*
 * Script: buffer_troubleshoot.sql
 * Purpose: Analyze shared buffer usage and cache hit ratios
 * 
 * Usage:
 *   psql -d database_name -f monitoring/buffer_troubleshoot.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: pg_monitor role recommended
 *   - Extension: pg_buffercache (must be installed)
 *
 * Output:
 *   - Buffer cache statistics
 *   - Cache hit ratios by table
 *   - Tables with poor caching
 *   - Buffer usage distribution
 *
 * Notes:
 *   - Cache hit ratio should be >95% for good performance
 *   - Low ratios indicate need for more shared_buffers or query optimization
 *   - Install pg_buffercache: CREATE EXTENSION pg_buffercache;
 *   - Can be resource-intensive, avoid running frequently on busy systems
 */

-- Overall cache hit ratio
SELECT 
    sum(heap_blks_read) AS heap_read,
    sum(heap_blks_hit) AS heap_hit,
    sum(heap_blks_hit) / NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0) AS cache_hit_ratio
FROM pg_statio_user_tables;

-- Cache hit ratio by table
SELECT 
    schemaname || '.' || relname AS table_name,
    heap_blks_read,
    heap_blks_hit,
    ROUND(heap_blks_hit * 100.0 / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) AS cache_hit_percent
FROM pg_statio_user_tables
WHERE heap_blks_read + heap_blks_hit > 0
ORDER BY cache_hit_percent ASC, heap_blks_read DESC
LIMIT 20;