/*
 * Script: missing_indexes.sql
 * Purpose: Identify potentially beneficial indexes based on query patterns and table usage
 * 
 * Usage:
 *   psql -d database_name -f optimization/missing_indexes.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - pg_stat_statements extension enabled (for query analysis)
 *   - Privileges: pg_monitor role or pg_stat_all_tables access
 *
 * Output:
 *   - Tables with high sequential scan ratios
 *   - Columns frequently used in WHERE clauses without indexes
 *   - Foreign key columns missing indexes
 *   - Unused indexes that could be dropped
 *   - Index recommendations with estimated benefit
 *
 * Notes:
 *   - Requires pg_stat_statements: CREATE EXTENSION pg_stat_statements;
 *   - Analysis improves with longer observation periods
 *   - Consider table size and query frequency when implementing suggestions
 *   - Test index impact on INSERT/UPDATE performance
 *   - Review recommendations with actual query plans
 */

-- Tables with high sequential scan activity (potential index candidates)
SELECT 
    schemaname || '.' || relname AS table_name,
    seq_scan AS sequential_scans,
    seq_tup_read AS sequential_tuples_read,
    idx_scan AS index_scans,
    idx_tup_fetch AS index_tuples_fetched,
    n_live_tup AS estimated_rows,
    pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS table_size,
    CASE 
        WHEN seq_scan = 0 THEN 0
        ELSE ROUND((seq_scan * 100.0 / NULLIF(seq_scan + COALESCE(idx_scan, 0), 0))::numeric, 2)
    END AS seq_scan_percentage,
    CASE 
        WHEN seq_tup_read = 0 THEN 0
        ELSE ROUND((seq_tup_read / NULLIF(seq_scan, 0))::numeric, 0)
    END AS avg_tuples_per_seq_scan,
    CASE 
        WHEN seq_scan > 1000 AND seq_scan > COALESCE(idx_scan, 0) * 2 
        THEN 'HIGH PRIORITY: Frequent sequential scans'
        WHEN seq_scan > 100 AND seq_tup_read > n_live_tup * 10 
        THEN 'MEDIUM PRIORITY: Large sequential scans'
        WHEN seq_scan > idx_scan AND n_live_tup > 10000 
        THEN 'LOW PRIORITY: Consider indexing for large table'
        ELSE 'OK: Reasonable scan patterns'
    END AS index_recommendation_priority,
    'ANALYZE ' || schemaname || '.' || relname || '; -- Check column distributions' AS suggested_analysis
FROM pg_stat_user_tables
WHERE n_live_tup > 1000  -- Only consider tables with substantial data
ORDER BY 
    (seq_scan * seq_tup_read) DESC,  -- Prioritize by scan impact
    seq_scan DESC
LIMIT 20;

-- Foreign key columns without supporting indexes (common performance issue)
WITH fk_columns AS (
    SELECT 
        tc.table_schema,
        tc.table_name,
        kcu.column_name,
        tc.constraint_name,
        ccu.table_name AS referenced_table_name,
        ccu.column_name AS referenced_column_name
    FROM information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
        ON tc.constraint_name = kcu.constraint_name
        AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage AS ccu
        ON ccu.constraint_name = tc.constraint_name
        AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
),
existing_indexes AS (
    SELECT 
        schemaname,
        tablename,
        indexname,
        indexdef
    FROM pg_indexes
)
SELECT 
    fk.table_schema || '.' || fk.table_name AS table_name,
    fk.column_name AS fk_column,
    fk.referenced_table_name AS references_table,
    fk.referenced_column_name AS references_column,
    CASE 
        WHEN ei.indexname IS NULL 
        THEN 'MISSING: No index found on foreign key column'
        ELSE 'EXISTS: ' || ei.indexname
    END AS index_status,
    CASE 
        WHEN ei.indexname IS NULL 
        THEN format('CREATE INDEX CONCURRENTLY idx_%s_%s ON %s.%s (%s);',
                   fk.table_name, 
                   fk.column_name,
                   fk.table_schema,
                   fk.table_name, 
                   fk.column_name)
        ELSE '-- Index already exists'
    END AS suggested_index_creation,
    st.n_live_tup AS estimated_rows,
    pg_size_pretty(pg_relation_size(fk.table_schema||'.'||fk.table_name)) AS table_size
FROM fk_columns fk
LEFT JOIN existing_indexes ei 
    ON ei.schemaname = fk.table_schema 
    AND ei.tablename = fk.table_name
    AND ei.indexdef LIKE '%' || fk.column_name || '%'
LEFT JOIN pg_stat_user_tables st 
    ON st.schemaname = fk.table_schema 
    AND st.relname = fk.table_name
WHERE fk.table_schema NOT IN ('information_schema', 'pg_catalog')
ORDER BY 
    CASE WHEN ei.indexname IS NULL THEN 0 ELSE 1 END,  -- Missing indexes first
    st.n_live_tup DESC NULLS LAST;

-- Unused indexes (candidates for removal)
SELECT 
    schemaname || '.' || relname AS table_name,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(schemaname||'.'||indexrelname)) AS index_size,
    idx_scan AS times_used,
    pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS table_size,
    (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname = pgu.schemaname AND relname = pgu.relname) AS table_rows,
    CASE 
        WHEN idx_scan = 0 THEN 'UNUSED: Consider dropping'
        WHEN idx_scan < 10 THEN 'RARELY USED: Investigate'
        ELSE 'ACTIVELY USED: Keep'
    END AS usage_assessment,
    CASE 
        WHEN idx_scan = 0 THEN 
            'DROP INDEX CONCURRENTLY ' || schemaname || '.' || indexrelname || '; -- Backup first!'
        ELSE '-- Index is being used'
    END AS drop_suggestion,
    (SELECT indexdef FROM pg_indexes WHERE schemaname = pgu.schemaname AND indexname = pgu.indexrelname) AS index_definition
FROM pg_stat_user_indexes pgu
WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
    AND pg_relation_size(schemaname||'.'||indexrelname) > 1024*1024  -- >1MB indexes only
ORDER BY 
    idx_scan ASC,  -- Least used first
    pg_relation_size(schemaname||'.'||indexrelname) DESC;  -- Largest unused first

-- Query patterns analysis (requires pg_stat_statements)
-- This helps identify frequently used WHERE conditions that might benefit from indexes
SELECT CASE
    WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
         AND current_setting('shared_preload_libraries', true) LIKE '%pg_stat_statements%'
    THEN 1
    ELSE 0
END AS has_pg_stat_statements
\gset

\if :has_pg_stat_statements
SELECT 
    calls AS execution_count,
    total_exec_time AS total_execution_time_ms,
    mean_exec_time AS mean_execution_time_ms,
    shared_blks_read AS blocks_read_from_disk,
    shared_blks_hit AS blocks_read_from_cache,
    CASE 
        WHEN shared_blks_read + shared_blks_hit > 0 
        THEN ROUND((shared_blks_hit * 100.0 / (shared_blks_read + shared_blks_hit))::numeric, 2)
        ELSE 0 
    END AS cache_hit_ratio,
    LEFT(query, 200) AS query_sample,
    CASE 
        WHEN mean_exec_time > 1000 AND calls > 100 
        THEN 'HIGH PRIORITY: Slow frequent query'
        WHEN shared_blks_read > 1000 AND calls > 10 
        THEN 'MEDIUM PRIORITY: High I/O query'
        WHEN calls > 1000 
        THEN 'LOW PRIORITY: Very frequent query'
        ELSE 'MONITOR: Review query pattern'
    END AS optimization_priority,
    'EXPLAIN (ANALYZE, BUFFERS) ' || LEFT(regexp_replace(query, '\$[0-9]+', '?', 'g'), 100) || '...' AS explain_suggestion
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_%'  -- Exclude monitoring queries
    AND query NOT LIKE '%information_schema%'  -- Exclude system queries
    AND calls > 5  -- Only frequently executed queries
    AND (
        mean_exec_time > 100  -- Slow queries
        OR calls > 100       -- Frequent queries
        OR shared_blks_read > 100  -- I/O intensive queries
    )
ORDER BY 
    (calls * mean_exec_time) DESC,  -- Total time impact
    calls DESC
LIMIT 20;
\else
\echo 'Skipping query pattern analysis: pg_stat_statements is unavailable in this server runtime.'
\echo 'Need to install extension pg_stat_statements and load it via shared_preload_libraries.'
\echo 'Set shared_preload_libraries = ''pg_stat_statements'' and restart PostgreSQL.'
\echo 'Install with: CREATE EXTENSION pg_stat_statements;'
\endif

-- Tables that might benefit from partial indexes
WITH table_analysis AS (
    SELECT 
        schemaname,
        relname,
        n_live_tup,
        n_dead_tup,
        seq_scan,
        seq_tup_read,
        idx_scan,
        idx_tup_fetch,
        pg_relation_size(schemaname||'.'||relname) as table_size_bytes
    FROM pg_stat_user_tables
    WHERE n_live_tup > 10000  -- Only larger tables
)
SELECT 
    schemaname || '.' || relname AS table_name,
    n_live_tup AS total_rows,
    pg_size_pretty(table_size_bytes) AS table_size,
    seq_scan AS sequential_scans,
    CASE 
        WHEN seq_tup_read > 0 AND seq_scan > 0
        THEN ROUND((seq_tup_read / seq_scan)::numeric, 0)
        ELSE 0 
    END AS avg_rows_per_seq_scan,
    CASE 
        WHEN seq_scan > 100 AND seq_tup_read > n_live_tup * 5 
        THEN 'Consider partial indexes for commonly filtered subsets'
        WHEN table_size_bytes > 1024*1024*1024 AND seq_scan > 10 
        THEN 'Large table with sequential scans - investigate WHERE conditions'
        ELSE 'Table scan patterns appear reasonable'
    END AS partial_index_recommendation,
    format('-- Example: CREATE INDEX CONCURRENTLY idx_%s_partial ON %s.%s (column_name) WHERE condition;',
           relname, schemaname, relname) AS partial_index_example
FROM table_analysis
WHERE seq_scan > 10  -- Tables with some sequential scan activity
ORDER BY (seq_scan * seq_tup_read) DESC
LIMIT 15;

-- Index maintenance recommendations
SELECT 
    'Index Maintenance Summary' AS assessment_type,
    (SELECT COUNT(*) FROM pg_stat_user_indexes WHERE idx_scan = 0) AS unused_indexes,
    (SELECT COUNT(*) FROM pg_stat_user_tables WHERE seq_scan > idx_scan AND n_live_tup > 1000) AS tables_needing_indexes,
    (SELECT pg_size_pretty(SUM(pg_relation_size(schemaname||'.'||indexrelname))) 
     FROM pg_stat_user_indexes WHERE idx_scan = 0) AS unused_index_size,
    CASE 
        WHEN (SELECT COUNT(*) FROM pg_stat_user_indexes WHERE idx_scan = 0) > 5
        THEN 'Consider removing unused indexes to improve write performance'
        WHEN (SELECT COUNT(*) FROM pg_stat_user_tables WHERE seq_scan > idx_scan AND n_live_tup > 1000) > 5
        THEN 'Several tables show high sequential scan activity'
        ELSE 'Index usage patterns appear reasonable'
    END AS primary_recommendation;

-- Composite index opportunities (advanced analysis)
-- This identifies columns that are frequently used together in WHERE clauses
SELECT 
    'Composite Index Analysis' AS analysis_type,
    'Review pg_stat_statements for queries with multiple WHERE conditions' AS methodology,
    'Look for patterns like: WHERE col1 = ? AND col2 = ? ORDER BY col3' AS pattern_to_find,
    'CREATE INDEX CONCURRENTLY idx_table_composite ON table (col1, col2, col3);' AS composite_index_example,
    'Note: Column order matters - most selective first, ORDER BY columns last' AS important_note,
    'Use EXPLAIN (ANALYZE, BUFFERS) to validate index effectiveness' AS validation_method;