/*
 * Script: maintenance_scheduler.sql
 * Purpose: Analyze and schedule PostgreSQL maintenance operations
 * 
 * This script identifies tables that need maintenance operations
 * and provides recommendations for VACUUM, ANALYZE, and REINDEX.
 * 
 * Requires: PostgreSQL 15+, pg_stat_user_tables access
 * Privileges: pg_monitor role or superuser for full analysis
 * 
 * Usage: psql -f maintenance/maintenance_scheduler.sql
 * 
 * Author: pgtools
 * Version: 1.0
 * Date: 2024-10-25
 */

\echo '================================================='
\echo 'PostgreSQL Maintenance Scheduler and Analysis'
\echo '================================================='
\echo ''

-- Current autovacuum settings
\echo '--- AUTOVACUUM CONFIGURATION ---'
SELECT 
    name,
    setting,
    unit,
    short_desc
FROM pg_settings 
WHERE name LIKE 'autovacuum%' 
    OR name IN ('vacuum_cost_delay', 'vacuum_cost_limit')
ORDER BY name;

\echo ''

-- Tables requiring VACUUM
\echo '--- TABLES REQUIRING VACUUM ---'
SELECT 
    schemaname,
    relname,
    n_dead_tup as dead_tuples,
    n_live_tup as live_tuples,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_tuple_percentage,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as table_size,
    last_vacuum,
    last_autovacuum,
    CASE 
        WHEN n_dead_tup > n_live_tup * 0.5 THEN 'URGENT'
        WHEN n_dead_tup > n_live_tup * 0.2 THEN 'HIGH'
        WHEN n_dead_tup > n_live_tup * 0.1 THEN 'MODERATE'
        ELSE 'LOW'
    END as vacuum_priority,
    CASE 
        WHEN pg_total_relation_size(schemaname||'.'||relname) > 10 * 1024^3 THEN 'LARGE_TABLE'
        WHEN pg_total_relation_size(schemaname||'.'||relname) > 1024^3 THEN 'MEDIUM_TABLE'
        ELSE 'SMALL_TABLE'
    END as size_category
FROM pg_stat_user_tables
WHERE n_dead_tup > GREATEST(n_live_tup * 0.1, 1000)  -- >10% dead tuples or >1000 dead tuples
ORDER BY 
    CASE 
        WHEN n_dead_tup > n_live_tup * 0.5 THEN 1
        WHEN n_dead_tup > n_live_tup * 0.2 THEN 2  
        WHEN n_dead_tup > n_live_tup * 0.1 THEN 3
        ELSE 4
    END,
    n_dead_tup DESC;

\echo ''

-- Tables requiring ANALYZE
\echo '--- TABLES REQUIRING ANALYZE ---'
SELECT 
    schemaname,
    relname,
    n_tup_ins + n_tup_upd + n_tup_del as total_modifications,
    n_live_tup as live_tuples,
    ROUND(100.0 * (n_tup_ins + n_tup_upd + n_tup_del) / NULLIF(n_live_tup, 0), 2) as modification_percentage,
    last_analyze,
    last_autoanalyze,
    GREATEST(last_analyze, last_autoanalyze) as most_recent_analyze,
    EXTRACT(DAYS FROM (now() - GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')))) as days_since_analyze,
    CASE 
        WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 'NEVER_ANALYZED'
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '30 days' 
             AND (n_tup_ins + n_tup_upd + n_tup_del) > 10000 THEN 'VERY_STALE'
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '7 days' 
             AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000 THEN 'STALE'
        WHEN (n_tup_ins + n_tup_upd + n_tup_del) > n_live_tup * 0.1 THEN 'HIGH_CHANGES'
        ELSE 'OK'
    END as analyze_priority
FROM pg_stat_user_tables
WHERE (last_analyze IS NULL AND last_autoanalyze IS NULL)
    OR (GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')) < NOW() - INTERVAL '7 days' 
        AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000)
    OR ((n_tup_ins + n_tup_upd + n_tup_del) > n_live_tup * 0.1)
ORDER BY 
    CASE
        WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 1
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '30 days'
             AND (n_tup_ins + n_tup_upd + n_tup_del) > 10000 THEN 2
        WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '7 days'
             AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000 THEN 3
        WHEN (n_tup_ins + n_tup_upd + n_tup_del) > n_live_tup * 0.1 THEN 4
        ELSE 5
    END,
    total_modifications DESC;

\echo ''

-- Index bloat analysis
\echo '--- INDEX BLOAT ANALYSIS ---'
WITH index_bloat AS (
    SELECT 
        schemaname,
        relname,
        indexname,
        pg_size_pretty(pg_relation_size(schemaname||'.'||indexname)) as index_size,
        pg_relation_size(schemaname||'.'||indexname) as index_size_bytes,
        idx_scan,
        idx_tup_read,
        idx_tup_fetch,
        -- Estimate bloat (this is a simplified calculation)
        CASE 
            WHEN idx_scan = 0 THEN 'UNUSED'
            WHEN pg_relation_size(schemaname||'.'||indexname) = 0 THEN 'EMPTY'
            ELSE 'NORMAL'
        END as bloat_status
    FROM pg_stat_user_indexes
    WHERE pg_relation_size(schemaname||'.'||indexname) > 10 * 1024 * 1024  -- >10MB
)
SELECT 
    schemaname,
    relname,
    indexname,
    index_size,
    idx_scan as times_used,
    bloat_status,
    CASE 
        WHEN bloat_status = 'UNUSED' AND index_size_bytes > 100 * 1024 * 1024 THEN 'CONSIDER_DROPPING'
        WHEN bloat_status = 'UNUSED' AND index_size_bytes > 10 * 1024 * 1024 THEN 'REVIEW_USAGE'
        WHEN idx_scan > 0 AND idx_tup_read > idx_tup_fetch * 10 THEN 'POSSIBLE_BLOAT'
        ELSE 'OK'
    END as reindex_recommendation
FROM index_bloat
WHERE bloat_status != 'NORMAL' OR idx_tup_read > idx_tup_fetch * 10
ORDER BY index_size_bytes DESC;

\echo ''

-- Maintenance workload analysis
\echo '--- MAINTENANCE WORKLOAD ESTIMATION ---'
WITH maintenance_workload AS (
    SELECT 
        COUNT(*) FILTER (WHERE n_dead_tup > GREATEST(n_live_tup * 0.1, 1000)) as tables_need_vacuum,
        COUNT(*) FILTER (WHERE n_dead_tup > n_live_tup * 0.2) as tables_urgent_vacuum,
        COUNT(*) FILTER (WHERE 
            (last_analyze IS NULL AND last_autoanalyze IS NULL) OR
            (GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')) < NOW() - INTERVAL '7 days' 
             AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000) OR
            ((n_tup_ins + n_tup_upd + n_tup_del) > n_live_tup * 0.1)
        ) as tables_need_analyze,
        SUM(pg_total_relation_size(schemaname||'.'||relname)) FILTER (
            WHERE n_dead_tup > GREATEST(n_live_tup * 0.1, 1000)
        ) as vacuum_data_size,
        SUM(pg_total_relation_size(schemaname||'.'||relname)) FILTER (
            WHERE (last_analyze IS NULL AND last_autoanalyze IS NULL) OR
                  (GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')) < NOW() - INTERVAL '7 days' 
                   AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000) OR
                  ((n_tup_ins + n_tup_upd + n_tup_del) > n_live_tup * 0.1)
        ) as analyze_data_size
    FROM pg_stat_user_tables
)
SELECT 
    tables_need_vacuum,
    tables_urgent_vacuum,
    tables_need_analyze,
    pg_size_pretty(COALESCE(vacuum_data_size, 0)) as vacuum_workload_size,
    pg_size_pretty(COALESCE(analyze_data_size, 0)) as analyze_workload_size,
    CASE 
        WHEN tables_urgent_vacuum > 5 THEN 'HIGH - Immediate attention needed'
        WHEN tables_need_vacuum > 10 THEN 'MODERATE - Schedule maintenance soon'
        WHEN tables_need_vacuum > 0 THEN 'LOW - Regular maintenance sufficient'
        ELSE 'MINIMAL - System healthy'
    END as maintenance_urgency
FROM maintenance_workload;

\echo ''

-- Autovacuum effectiveness analysis  
\echo '--- AUTOVACUUM EFFECTIVENESS ANALYSIS ---'
SELECT 
    schemaname,
    relname,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_percentage,
    last_vacuum,
    last_autovacuum,
    CASE 
        WHEN last_autovacuum IS NULL AND n_dead_tup > 10000 THEN 'AUTOVACUUM_NOT_RUNNING'
        WHEN last_autovacuum < NOW() - INTERVAL '7 days' AND n_dead_tup > n_live_tup * 0.2 THEN 'AUTOVACUUM_INSUFFICIENT'
        WHEN n_dead_tup > n_live_tup * 0.3 THEN 'NEEDS_TUNING'
        ELSE 'OK'
    END as autovacuum_effectiveness,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as table_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;

\echo ''

-- Maintenance scheduling recommendations
\echo '--- MAINTENANCE SCHEDULING RECOMMENDATIONS ---'
\echo ''

-- Generate specific recommendations
WITH maintenance_analysis AS (
    SELECT 
        COUNT(*) FILTER (WHERE n_dead_tup > GREATEST(n_live_tup * 0.2, 5000)) as urgent_vacuum_count,
        COUNT(*) FILTER (WHERE n_dead_tup > GREATEST(n_live_tup * 0.1, 1000)) as vacuum_count,
        COUNT(*) FILTER (WHERE 
            (last_analyze IS NULL AND last_autoanalyze IS NULL AND n_live_tup > 1000) OR
            (GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')) < NOW() - INTERVAL '7 days' 
             AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000)
        ) as analyze_count,
        (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_max_workers') as autovacuum_workers,
        (SELECT setting FROM pg_settings WHERE name = 'autovacuum') as autovacuum_enabled
    FROM pg_stat_user_tables
)
SELECT 
    'IMMEDIATE ACTIONS RECOMMENDED:' as category,
    CASE 
        WHEN urgent_vacuum_count > 0 THEN
            'Run VACUUM on ' || urgent_vacuum_count::text || ' tables with >20% dead tuples immediately'
        ELSE 'No urgent VACUUM operations needed'
    END as recommendation
FROM maintenance_analysis
UNION ALL
SELECT 
    'REGULAR MAINTENANCE:',
    CASE 
        WHEN vacuum_count > 0 THEN
            'Schedule VACUUM for ' || vacuum_count::text || ' tables during maintenance window'
        ELSE 'No additional VACUUM operations needed'
    END
FROM maintenance_analysis
UNION ALL
SELECT 
    'STATISTICS UPDATES:',
    CASE 
        WHEN analyze_count > 0 THEN
            'Run ANALYZE on ' || analyze_count::text || ' tables to update query planner statistics'
        ELSE 'Table statistics are current'
    END
FROM maintenance_analysis
UNION ALL
SELECT 
    'AUTOVACUUM STATUS:',
    CASE 
        WHEN autovacuum_enabled = 'off' THEN 
            'CRITICAL: Autovacuum is disabled - enable immediately!'
        WHEN autovacuum_workers < 3 AND vacuum_count > 10 THEN
            'Consider increasing autovacuum_max_workers (current: ' || autovacuum_workers::text || ')'
        ELSE 'Autovacuum configuration appears adequate'
    END
FROM maintenance_analysis;

\echo ''

-- Sample maintenance commands
\echo '--- SAMPLE MAINTENANCE COMMANDS ---'
\echo ''
\echo 'Manual VACUUM commands for urgent tables:'

SELECT 'VACUUM (VERBOSE, ANALYZE) ' || schemaname || '.' || relname || ';' as vacuum_command
FROM pg_stat_user_tables
WHERE n_dead_tup > GREATEST(n_live_tup * 0.2, 5000)
ORDER BY n_dead_tup DESC
LIMIT 10;

\echo ''
\echo 'ANALYZE commands for tables with stale statistics:'

SELECT 'ANALYZE (VERBOSE) ' || schemaname || '.' || relname || ';' as analyze_command
FROM pg_stat_user_tables
WHERE (last_analyze IS NULL AND last_autoanalyze IS NULL AND n_live_tup > 1000)
    OR (GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')) < NOW() - INTERVAL '7 days' 
        AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000)
ORDER BY n_tup_ins + n_tup_upd + n_tup_del DESC
LIMIT 10;

\echo ''
\echo '================================================='
\echo 'Maintenance Analysis Complete'
\echo ''
\echo 'Automation options:'
\echo '1. Use pgtools auto_maintenance.sh for automated maintenance'
\echo '2. Schedule regular maintenance windows'
\echo '3. Monitor autovacuum effectiveness'
\echo '4. Adjust autovacuum settings if needed'
\echo ''
\echo 'Commands:'
\echo './maintenance/auto_maintenance.sh --operation auto --verbose'
\echo './maintenance/auto_maintenance.sh --operation vacuum --dead-threshold 15'
\echo './maintenance/auto_maintenance.sh --operation analyze --schema public'
\echo '================================================='