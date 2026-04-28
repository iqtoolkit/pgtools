/*
 * Script: statistics_collector.sql
 * Purpose: Collect and analyze PostgreSQL table and index statistics
 * 
 * This script provides comprehensive analysis of table statistics,
 * helps identify statistics issues, and provides recommendations
 * for improving query plan accuracy.
 * 
 * Requires: PostgreSQL 15+, access to pg_stats and pg_statistic
 * Privileges: pg_monitor role or superuser
 * 
 * Usage: psql -f maintenance/statistics_collector.sql
 * 
 * Author: pgtools
 * Version: 1.0
 * Date: 2024-10-25
 */

\ir ../lib/preflight.sql
DO $preflight$ BEGIN PERFORM pg_temp.pgtools_check('pg_monitor', NULL); END $preflight$;

\echo '================================================='
\echo 'PostgreSQL Statistics Analysis'
\echo '================================================='
\echo ''

-- Statistics collection settings
\echo '--- STATISTICS CONFIGURATION ---'
SELECT 
    name,
    setting,
    unit,
    short_desc
FROM pg_settings 
WHERE name IN (
    'default_statistics_target',
    'track_activities',
    'track_counts',
    'track_io_timing',
    'track_functions'
)
ORDER BY name;

\echo ''

-- Tables with custom statistics targets
\echo '--- TABLES WITH CUSTOM STATISTICS TARGETS ---'
SELECT 
    schemaname,
    tablename,
    s.attname as column_name,
    attstattarget as statistics_target,
    CASE 
        WHEN attstattarget = -1 THEN 'Default (' || (SELECT setting FROM pg_settings WHERE name = 'default_statistics_target') || ')'
        WHEN attstattarget = 0 THEN 'No statistics'
        ELSE attstattarget::text
    END as target_description
FROM pg_stats s
JOIN pg_attribute a ON (s.schemaname = (SELECT nspname FROM pg_namespace WHERE oid = (SELECT relnamespace FROM pg_class WHERE relname = s.tablename AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = s.schemaname)))
    AND s.tablename = (SELECT relname FROM pg_class WHERE oid = a.attrelid) 
    AND s.attname = a.attname)
WHERE attstattarget != -1
    AND schemaname NOT IN ('information_schema', 'pg_catalog')
ORDER BY schemaname, tablename, s.attname;

\echo ''

-- Tables with potentially insufficient statistics
\echo '--- TABLES WITH POTENTIALLY INSUFFICIENT STATISTICS ---'
SELECT 
    schemaname,
    tablename,
    attname as column_name,
    n_distinct,
    most_common_vals,
    array_length(most_common_vals, 1) as mcv_count,
    histogram_bounds,
    array_length(histogram_bounds, 1) as histogram_buckets,
    correlation,
    CASE 
        WHEN n_distinct > 100 AND array_length(most_common_vals, 1) < 10 THEN 'LOW_MCV_COUNT'
        WHEN n_distinct > 1000 AND array_length(histogram_bounds, 1) < 20 THEN 'LOW_HISTOGRAM_RESOLUTION'
        WHEN ABS(correlation) > 0.1 AND array_length(histogram_bounds, 1) < 50 THEN 'POOR_CORRELATION_STATS'
        ELSE 'OK'
    END as statistics_quality,
    (SELECT setting FROM pg_settings WHERE name = 'default_statistics_target') as default_target
FROM pg_stats
WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
    AND (
        (n_distinct > 100 AND array_length(most_common_vals, 1) < 10) OR
        (n_distinct > 1000 AND array_length(histogram_bounds, 1) < 20) OR
        (ABS(correlation) > 0.1 AND array_length(histogram_bounds, 1) < 50)
    )
ORDER BY
    CASE
        WHEN n_distinct > 100 AND array_length(most_common_vals, 1) < 10 THEN 1
        WHEN n_distinct > 1000 AND array_length(histogram_bounds, 1) < 20 THEN 2
        WHEN ABS(correlation) > 0.1 AND array_length(histogram_bounds, 1) < 50 THEN 3
        ELSE 4
    END,
    n_distinct DESC;

\echo ''

-- Statistics freshness analysis
\echo '--- STATISTICS FRESHNESS ANALYSIS ---'
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    n_tup_ins + n_tup_upd + n_tup_del as total_changes_since_analyze,
    last_analyze,
    last_autoanalyze,
    GREATEST(last_analyze, last_autoanalyze) as most_recent_analyze,
    EXTRACT(HOURS FROM (now() - GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')))) as hours_since_analyze,
    CASE 
        WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 'NEVER'
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '30 days' THEN 'VERY_STALE'
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '7 days' THEN 'STALE'
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '1 day' THEN 'MODERATE'
        ELSE 'FRESH'
    END as statistics_age,
    ROUND(100.0 * (n_tup_ins + n_tup_upd + n_tup_del) / NULLIF(n_live_tup, 0), 2) as change_percentage
FROM pg_stat_user_tables
WHERE n_live_tup > 1000  -- Focus on tables with significant data
ORDER BY 
    CASE 
        WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 1
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '30 days' THEN 2
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '7 days' THEN 3
        ELSE 4
    END,
    total_changes_since_analyze DESC;

\echo ''

-- Column statistics distribution analysis
\echo '--- COLUMN STATISTICS DISTRIBUTION ANALYSIS ---'
SELECT 
    schemaname,
    tablename,
    attname,
    null_frac,
    n_distinct,
    avg_width,
    CASE 
        WHEN null_frac > 0.5 THEN 'HIGH_NULLS'
        WHEN null_frac > 0.1 THEN 'MODERATE_NULLS'
        WHEN null_frac > 0 THEN 'LOW_NULLS'
        ELSE 'NO_NULLS'
    END as null_category,
    CASE 
        WHEN n_distinct = -1 THEN 'UNIQUE'
        WHEN n_distinct > 1000 THEN 'HIGH_CARDINALITY'
        WHEN n_distinct > 100 THEN 'MODERATE_CARDINALITY' 
        WHEN n_distinct > 10 THEN 'LOW_CARDINALITY'
        ELSE 'VERY_LOW_CARDINALITY'
    END as cardinality_category,
    CASE 
        WHEN avg_width > 1000 THEN 'LARGE_VALUES'
        WHEN avg_width > 100 THEN 'MEDIUM_VALUES'
        ELSE 'SMALL_VALUES'
    END as size_category
FROM pg_stats
WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
    AND (null_frac > 0.5 OR n_distinct = -1 OR n_distinct > 1000 OR avg_width > 100)
ORDER BY schemaname, tablename, 
    CASE 
        WHEN n_distinct = -1 THEN 1
        WHEN n_distinct > 1000 THEN 2
        WHEN null_frac > 0.5 THEN 3
        ELSE 4
    END,
    n_distinct DESC;

\echo ''

-- Index statistics and usage
\echo '--- INDEX STATISTICS AND USAGE ---'
SELECT
    schemaname,
    relname,
    indexrelname,
    idx_scan as scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(schemaname||'.'||indexrelname)) as index_size,
    CASE
        WHEN idx_scan = 0 THEN 'UNUSED'
        WHEN idx_scan < 10 THEN 'RARELY_USED'
        WHEN idx_scan < 1000 THEN 'MODERATELY_USED'
        ELSE 'FREQUENTLY_USED'
    END as usage_category,
    CASE
        WHEN idx_scan > 0 AND idx_tup_read > idx_tup_fetch * 10 THEN 'INEFFICIENT'
        WHEN idx_scan > 0 AND idx_tup_read > idx_tup_fetch * 2 THEN 'MODERATE_EFFICIENCY'
        WHEN idx_scan > 0 THEN 'EFFICIENT'
        ELSE 'NOT_EVALUATED'
    END as efficiency_rating
FROM pg_stat_user_indexes
WHERE pg_relation_size(schemaname||'.'||indexrelname) > 1024 * 1024  -- >1MB
ORDER BY
    CASE
        WHEN idx_scan = 0 THEN 1
        WHEN idx_scan < 10 THEN 2
        ELSE 3
    END,
    pg_relation_size(schemaname||'.'||indexrelname) DESC;

\echo ''

-- Statistics-related performance issues
\echo '--- POTENTIAL STATISTICS-RELATED PERFORMANCE ISSUES ---'
WITH stats_issues AS (
    SELECT 
        schemaname,
        tablename,
        COUNT(*) FILTER (WHERE n_distinct > 1000 AND array_length(most_common_vals, 1) < 10) as high_cardinality_low_mcv,
        COUNT(*) FILTER (WHERE null_frac > 0.3) as high_null_columns,
        COUNT(*) FILTER (WHERE ABS(correlation) > 0.5) as high_correlation_columns,
        COUNT(*) as total_columns,
        (SELECT n_live_tup FROM pg_stat_user_tables st WHERE st.schemaname = s.schemaname AND st.relname = s.tablename) as row_count,
        (SELECT EXTRACT(HOURS FROM (now() - GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01'))))
         FROM pg_stat_user_tables st WHERE st.schemaname = s.schemaname AND st.relname = s.tablename) as hours_since_analyze
    FROM pg_stats s
    WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
    GROUP BY schemaname, tablename
)
SELECT 
    schemaname,
    tablename,
    row_count,
    hours_since_analyze,
    high_cardinality_low_mcv,
    high_null_columns,
    high_correlation_columns,
    total_columns,
    CASE 
        WHEN hours_since_analyze > 168 AND row_count > 100000 THEN 'STALE_STATS_LARGE_TABLE'
        WHEN high_cardinality_low_mcv > 0 THEN 'INSUFFICIENT_MCV_STATS'
        WHEN high_correlation_columns > total_columns * 0.5 THEN 'HIGH_CORRELATION_CONCERN'
        WHEN high_null_columns > total_columns * 0.3 THEN 'HIGH_NULL_IMPACT'
        ELSE 'OK'
    END as issue_type,
    CASE 
        WHEN hours_since_analyze > 168 AND row_count > 100000 THEN 'Run ANALYZE on this large table'
        WHEN high_cardinality_low_mcv > 0 THEN 'Consider increasing statistics_target for high cardinality columns'
        WHEN high_correlation_columns > total_columns * 0.5 THEN 'Review column correlations and consider column statistics'
        WHEN high_null_columns > total_columns * 0.3 THEN 'High NULL percentage may affect query plans'
        ELSE 'Statistics appear adequate'
    END as recommendation
FROM stats_issues
WHERE high_cardinality_low_mcv > 0 
    OR high_correlation_columns > total_columns * 0.5 
    OR high_null_columns > total_columns * 0.3
    OR (hours_since_analyze > 168 AND row_count > 100000)
ORDER BY
    CASE
        WHEN hours_since_analyze > 168 AND row_count > 100000 THEN 1
        WHEN high_cardinality_low_mcv > 0 THEN 2
        WHEN high_correlation_columns > total_columns * 0.5 THEN 3
        ELSE 4
    END,
    row_count DESC;

\echo ''

-- Extended statistics (PostgreSQL 15+)
\echo '--- EXTENDED STATISTICS ANALYSIS ---'
DO $extended_stats$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'pg_statistic_ext') THEN
        EXECUTE '
        SELECT 
            n.nspname as schema_name,
            c.relname as table_name,
            s.stxname as statistics_name,
            array_to_string(s.stxkeys, '','') as column_positions,
            CASE s.stxkind[1]
                WHEN ''d'' THEN ''n-distinct''
                WHEN ''f'' THEN ''functional dependencies''
                WHEN ''m'' THEN ''most common values''
                ELSE ''unknown''
            END as statistics_type,
            pg_size_pretty(pg_total_relation_size(n.nspname||''.''||c.relname)) as table_size
        FROM pg_statistic_ext s
        JOIN pg_class c ON s.stxrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname NOT IN (''information_schema'', ''pg_catalog'')
        ORDER BY n.nspname, c.relname, s.stxname';
    ELSE
        RAISE NOTICE 'Extended statistics not available in this PostgreSQL version';
    END IF;
END;
$extended_stats$;

\echo ''

-- Statistics maintenance recommendations
\echo '--- STATISTICS MAINTENANCE RECOMMENDATIONS ---'
\echo ''

WITH statistics_summary AS (
    SELECT 
        COUNT(*) FILTER (WHERE 
            GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')) < NOW() - INTERVAL '7 days'
            AND n_live_tup > 10000
        ) as stale_large_tables,
        COUNT(*) FILTER (WHERE last_analyze IS NULL AND last_autoanalyze IS NULL AND n_live_tup > 1000) as never_analyzed_tables,
        (SELECT COUNT(*) FROM pg_stats WHERE schemaname NOT IN ('information_schema', 'pg_catalog') 
         AND n_distinct > 1000 AND array_length(most_common_vals, 1) < 10) as insufficient_mcv_columns,
        (SELECT setting::int FROM pg_settings WHERE name = 'default_statistics_target') as default_stats_target
    FROM pg_stat_user_tables
)
SELECT 
    'IMMEDIATE STATISTICS ACTIONS:' as category,
    CASE 
        WHEN never_analyzed_tables > 0 THEN
            'ANALYZE ' || never_analyzed_tables::text || ' tables that have never been analyzed'
        ELSE 'All tables have been analyzed at least once'
    END as recommendation
FROM statistics_summary
UNION ALL
SELECT 
    'REGULAR STATISTICS MAINTENANCE:',
    CASE 
        WHEN stale_large_tables > 0 THEN
            'Update statistics on ' || stale_large_tables::text || ' large tables with stale statistics'
        ELSE 'Large table statistics are current'
    END
FROM statistics_summary
UNION ALL
SELECT 
    'STATISTICS TARGET TUNING:',
    CASE 
        WHEN insufficient_mcv_columns > 0 THEN
            'Consider increasing statistics_target for ' || insufficient_mcv_columns::text || ' high-cardinality columns'
        ELSE 'Column statistics targets appear adequate'
    END
FROM statistics_summary
UNION ALL
SELECT 
    'CONFIGURATION RECOMMENDATION:',
    CASE 
        WHEN default_stats_target < 100 THEN
            'Consider increasing default_statistics_target (current: ' || default_stats_target::text || ', recommend: 100-1000)'
        WHEN default_stats_target > 1000 THEN
            'default_statistics_target is high (' || default_stats_target::text || ') - ensure ANALYZE performance is acceptable'
        ELSE 'default_statistics_target (' || default_stats_target::text || ') appears reasonable'
    END
FROM statistics_summary;

\echo ''
\echo '================================================='
\echo 'Statistics Analysis Complete'
\echo ''
\echo 'Key recommendations:'
\echo '1. Keep table statistics current with regular ANALYZE'
\echo '2. Increase statistics_target for high-cardinality columns'
\echo '3. Monitor statistics quality for query performance'
\echo '4. Consider extended statistics for correlated columns'
\echo ''
\echo 'Automation commands:'
\echo './maintenance/auto_maintenance.sh --operation analyze'
\echo 'ALTER TABLE schema.table ALTER COLUMN high_cardinality_col SET STATISTICS 1000;'
\echo '================================================='