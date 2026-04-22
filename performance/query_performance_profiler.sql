/*
 * Script: query_performance_profiler.sql
 * Purpose: Comprehensive query performance analysis and profiling
 * 
 * This script provides detailed analysis of query performance, including
 * execution statistics, resource usage, and optimization recommendations.
 * 
 * Requires: PostgreSQL 15+, pg_stat_statements extension
 * Privileges: pg_monitor role or superuser
 * 
 * Usage: psql -f performance/query_performance_profiler.sql
 * 
 * Author: pgtools
 * Version: 1.0
 * Date: 2024-10-25
 */

\echo '================================================='
\echo 'PostgreSQL Query Performance Profiler'
\echo '================================================='
\echo ''

-- Check if pg_stat_statements is available
DO $check$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RAISE EXCEPTION 'pg_stat_statements extension is required. Install with: CREATE EXTENSION pg_stat_statements;';
    END IF;
END;
$check$;

-- Performance overview
\echo '--- QUERY PERFORMANCE OVERVIEW ---'
SELECT 
    COUNT(*) as total_queries,
    SUM(calls) as total_calls,
    ROUND(SUM(total_exec_time)::numeric, 2) as total_exec_time_ms,
    ROUND(AVG(mean_exec_time)::numeric, 2) as avg_mean_time_ms,
    ROUND((SUM(total_exec_time) / SUM(calls))::numeric, 2) as overall_avg_time_ms,
    SUM(rows) as total_rows_returned
FROM pg_stat_statements;

\echo ''

-- Top queries by total execution time
\echo '--- TOP QUERIES BY TOTAL EXECUTION TIME ---'
SELECT 
    queryid,
    calls,
    ROUND(total_exec_time::numeric, 2) as total_time_ms,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    ROUND(stddev_exec_time::numeric, 2) as stddev_time_ms,
    ROUND(((total_exec_time / sum(total_exec_time) OVER()) * 100)::numeric, 2) as percent_total_time,
    rows,
    ROUND(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 2) as hit_percent,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
ORDER BY total_exec_time DESC 
LIMIT 20;

\echo ''

-- Slowest queries by average execution time
\echo '--- SLOWEST QUERIES BY AVERAGE EXECUTION TIME ---'
SELECT 
    queryid,
    calls,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    ROUND(max_exec_time::numeric, 2) as max_time_ms,
    ROUND(min_exec_time::numeric, 2) as min_time_ms,
    ROUND(stddev_exec_time::numeric, 2) as stddev_time_ms,
    rows,
    ROUND(rows::numeric / GREATEST(calls, 1), 2) as avg_rows_per_call,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
WHERE calls > 5  -- Filter out one-off queries
ORDER BY mean_exec_time DESC 
LIMIT 20;

\echo ''

-- Most frequently called queries
\echo '--- MOST FREQUENTLY CALLED QUERIES ---'
SELECT 
    queryid,
    calls,
    ROUND(total_exec_time::numeric, 2) as total_time_ms,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    ROUND(((calls::numeric / sum(calls) OVER()) * 100)::numeric, 2) as percent_total_calls,
    rows,
    ROUND(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 2) as hit_percent,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
ORDER BY calls DESC 
LIMIT 20;

\echo ''

-- Queries with poor cache hit ratio
\echo '--- QUERIES WITH POOR CACHE HIT RATIO ---'
SELECT 
    queryid,
    calls,
    shared_blks_read,
    shared_blks_hit,
    ROUND(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 2) as hit_percent,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    shared_blks_read + shared_blks_hit as total_blocks,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
WHERE shared_blks_read + shared_blks_hit > 1000  -- Significant I/O
    AND shared_blks_read > 0
ORDER BY hit_percent ASC, total_blocks DESC
LIMIT 20;

\echo ''

-- I/O intensive queries
\echo '--- I/O INTENSIVE QUERIES ---'
SELECT 
    queryid,
    calls,
    shared_blks_read,
    shared_blks_written,
    shared_blks_dirtied,
    local_blks_read,
    local_blks_written,
    temp_blks_read,
    temp_blks_written,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
WHERE shared_blks_read + shared_blks_written + temp_blks_read + temp_blks_written > 10000
ORDER BY (shared_blks_read + shared_blks_written + temp_blks_read + temp_blks_written) DESC
LIMIT 15;

\echo ''

-- Queries using temporary files
\echo '--- QUERIES USING TEMPORARY FILES ---'
SELECT 
    queryid,
    calls,
    temp_blks_read,
    temp_blks_written,
    ROUND((temp_blks_written * 8192)::numeric / 1024 / 1024, 2) as temp_mb_written,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    rows,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 15;

\echo ''

-- Query variance analysis (inconsistent performance)
\echo '--- QUERIES WITH HIGH PERFORMANCE VARIANCE ---'
SELECT 
    queryid,
    calls,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    ROUND(stddev_exec_time::numeric, 2) as stddev_time_ms,
    ROUND(max_exec_time::numeric, 2) as max_time_ms,
    ROUND(min_exec_time::numeric, 2) as min_time_ms,
    ROUND((stddev_exec_time / GREATEST(mean_exec_time, 1)) * 100, 2) as coefficient_of_variation,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
WHERE calls > 10  -- Sufficient sample size
    AND stddev_exec_time > 0
    AND mean_exec_time > 100  -- Focus on slower queries
ORDER BY (stddev_exec_time / GREATEST(mean_exec_time, 1)) DESC
LIMIT 20;

\echo ''

-- WAL generation analysis
\echo '--- QUERIES GENERATING MOST WAL ---'
SELECT 
    queryid,
    calls,
    wal_records,
    wal_fpi,  -- Full Page Images
    wal_bytes,
    ROUND((wal_bytes::numeric / 1024 / 1024), 2) as wal_mb,
    ROUND((wal_bytes::numeric / GREATEST(calls, 1) / 1024), 2) as avg_wal_kb_per_call,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    LEFT(query, 120) || '...' as query_snippet
FROM pg_stat_statements 
WHERE wal_bytes > 0
ORDER BY wal_bytes DESC
LIMIT 15;

\echo ''

-- JIT compilation analysis (PostgreSQL 15+ with JIT enabled)
\echo '--- JIT COMPILATION ANALYSIS ---'
DO $jit$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns 
               WHERE table_name = 'pg_stat_statements' 
               AND column_name = 'jit_functions') THEN
        
        EXECUTE 'SELECT 
            queryid,
            calls,
            jit_functions,
            jit_generation_time,
            jit_inlining_count,
            jit_inlining_time,
            jit_optimization_count,
            jit_optimization_time,
            jit_emission_count,
            jit_emission_time,
            ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
            LEFT(query, 100) || ''...'' as query_snippet
        FROM pg_stat_statements 
        WHERE jit_functions > 0
        ORDER BY jit_generation_time + jit_inlining_time + jit_optimization_time + jit_emission_time DESC
        LIMIT 10';
    ELSE
        RAISE NOTICE 'JIT compilation statistics not available (requires PostgreSQL 15+ with JIT enabled)';
    END IF;
END;
$jit$;

\echo ''

-- Resource usage summary by query pattern
\echo '--- RESOURCE USAGE BY QUERY PATTERNS ---'
WITH query_patterns AS (
    SELECT 
        CASE 
            WHEN query ILIKE 'SELECT%' THEN 'SELECT'
            WHEN query ILIKE 'INSERT%' THEN 'INSERT'
            WHEN query ILIKE 'UPDATE%' THEN 'UPDATE'
            WHEN query ILIKE 'DELETE%' THEN 'DELETE'
            WHEN query ILIKE 'CREATE%' THEN 'CREATE'
            WHEN query ILIKE 'ALTER%' THEN 'ALTER'
            ELSE 'OTHER'
        END as query_type,
        calls,
        total_exec_time,
        shared_blks_read,
        shared_blks_hit,
        shared_blks_written,
        temp_blks_written
    FROM pg_stat_statements
)
SELECT 
    query_type,
    COUNT(*) as query_count,
    SUM(calls) as total_calls,
    ROUND(SUM(total_exec_time)::numeric, 2) as total_time_ms,
    ROUND(AVG(total_exec_time / GREATEST(calls, 1))::numeric, 2) as avg_time_per_call_ms,
    SUM(shared_blks_read + shared_blks_hit) as total_blocks_accessed,
    SUM(shared_blks_written) as total_blocks_written,
    SUM(temp_blks_written) as total_temp_blocks,
    ROUND(100.0 * SUM(shared_blks_hit) / NULLIF(SUM(shared_blks_hit + shared_blks_read), 0), 2) as avg_hit_ratio
FROM query_patterns
GROUP BY query_type
ORDER BY total_time_ms DESC;

\echo ''

-- Performance degradation detection
\echo '--- PERFORMANCE DEGRADATION CANDIDATES ---'
\echo 'Note: This analysis requires historical data collection for accurate results'
WITH recent_stats AS (
    SELECT 
        queryid,
        query,
        calls,
        mean_exec_time,
        stddev_exec_time,
        shared_blks_read + shared_blks_hit as total_blocks
    FROM pg_stat_statements
    WHERE calls > 50  -- Sufficient sample size
)
SELECT 
    queryid,
    calls,
    ROUND(mean_exec_time::numeric, 2) as mean_time_ms,
    ROUND(stddev_exec_time::numeric, 2) as stddev_time_ms,
    total_blocks,
    CASE 
        WHEN stddev_exec_time > mean_exec_time * 2 THEN 'HIGH_VARIANCE'
        WHEN mean_exec_time > 5000 THEN 'VERY_SLOW'
        WHEN mean_exec_time > 1000 AND total_blocks > 50000 THEN 'IO_BOUND'
        WHEN mean_exec_time > 1000 THEN 'SLOW'
        ELSE 'NORMAL'
    END as performance_category,
    LEFT(query, 120) || '...' as query_snippet
FROM recent_stats
WHERE mean_exec_time > 100  -- Focus on queries taking more than 100ms
ORDER BY 
    CASE 
        WHEN stddev_exec_time > mean_exec_time * 2 THEN 1
        WHEN mean_exec_time > 5000 THEN 2
        WHEN mean_exec_time > 1000 AND total_blocks > 50000 THEN 3
        WHEN mean_exec_time > 1000 THEN 4
        ELSE 5
    END,
    mean_exec_time DESC
LIMIT 25;

\echo ''

-- Optimization recommendations
\echo '--- OPTIMIZATION RECOMMENDATIONS ---'
\echo ''
\echo 'PERFORMANCE OPTIMIZATION RECOMMENDATIONS:'
\echo ''
\echo '1. SLOW QUERIES (>1 second average):'
\echo '   - Review query plans with EXPLAIN (ANALYZE, BUFFERS)'
\echo '   - Check for missing indexes'
\echo '   - Consider query rewriting'
\echo '   - Analyze table statistics currency'
\echo ''
\echo '2. HIGH I/O QUERIES:'
\echo '   - Add appropriate indexes'
\echo '   - Increase shared_buffers if cache hit ratio < 95%'
\echo '   - Consider partitioning for large tables'
\echo '   - Review WHERE clause selectivity'
\echo ''
\echo '3. HIGH FREQUENCY QUERIES:'
\echo '   - Optimize even small improvements (multiplicative effect)'
\echo '   - Consider connection pooling'
\echo '   - Cache results at application level if appropriate'
\echo '   - Review if queries can be batched'
\echo ''
\echo '4. TEMPORARY FILE USAGE:'
\echo '   - Increase work_mem for sorting/hashing operations'
\echo '   - Add indexes to reduce sort requirements'
\echo '   - Consider hash vs nested loop join strategies'
\echo '   - Review query complexity and data volume'
\echo ''
\echo '5. HIGH VARIANCE QUERIES:'
\echo '   - Check for parameter sniffing issues'
\echo '   - Consider plan stability with pg_stat_statements'
\echo '   - Review data distribution and table statistics'
\echo '   - Monitor for concurrent load variations'
\echo ''

\echo '================================================='
\echo 'Query Performance Profiler Complete'
\echo ''
\echo 'Next steps:'
\echo '1. Focus on queries in the "TOP QUERIES BY TOTAL EXECUTION TIME" section'
\echo '2. Use EXPLAIN (ANALYZE, BUFFERS) on slow queries for detailed plans'
\echo '3. Check missing_indexes.sql for index recommendations'
\echo '4. Monitor cache hit ratios and I/O patterns'
\echo '5. Consider application-level optimizations for high-frequency queries'
\echo '================================================='