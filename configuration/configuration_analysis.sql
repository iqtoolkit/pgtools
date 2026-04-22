/*
 * Script: configuration_analysis.sql
 * Purpose: Comprehensive PostgreSQL configuration analysis and recommendations
 * 
 * This script analyzes current PostgreSQL configuration settings and provides
 * recommendations for optimization based on workload patterns and best practices.
 * 
 * Requires: PostgreSQL 15+
 * Privileges: pg_monitor role or superuser for full analysis
 * 
 * Usage: psql -f configuration/configuration_analysis.sql
 * 
 * Author: pgtools
 * Version: 1.0
 * Date: 2024-10-25
 */

\echo '================================================='
\echo 'PostgreSQL Configuration Analysis'
\echo '================================================='
\echo ''

-- PostgreSQL version and basic info
\echo '--- POSTGRESQL VERSION AND BASIC INFORMATION ---'
SELECT 
    version() as postgresql_version,
    current_setting('server_version_num')::int as version_number,
    current_setting('data_directory') as data_directory,
    current_setting('config_file') as config_file,
    pg_postmaster_start_time() as server_start_time,
    EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::int / 3600 as uptime_hours
;

\echo ''

-- Memory configuration analysis
\echo '--- MEMORY CONFIGURATION ANALYSIS ---'
WITH memory_settings AS (
    SELECT 
        name,
        setting,
        unit,
        source,
        CASE 
            WHEN unit = 'kB' THEN setting::bigint * 1024
            WHEN unit = 'MB' THEN setting::bigint * 1024 * 1024
            WHEN unit = 'GB' THEN setting::bigint * 1024 * 1024 * 1024
            WHEN unit = '8kB' THEN setting::bigint * 8192
            ELSE setting::bigint
        END as bytes_value,
        short_desc
    FROM pg_settings
    WHERE name IN (
        'shared_buffers', 
        'work_mem', 
        'maintenance_work_mem',
        'effective_cache_size',
        'wal_buffers',
        'max_connections',
        'shared_preload_libraries'
    )
)
SELECT 
    name as parameter,
    setting || COALESCE(' ' || unit, '') as current_value,
    pg_size_pretty(bytes_value) as size_pretty,
    source as config_source,
    short_desc as description,
    CASE name
        WHEN 'shared_buffers' THEN 
            CASE 
                WHEN bytes_value < 128 * 1024 * 1024 THEN 'LOW - Consider 25% of RAM'
                WHEN bytes_value > 8 * 1024 * 1024 * 1024 THEN 'HIGH - May cause issues'
                ELSE 'REASONABLE'
            END
        WHEN 'work_mem' THEN 
            CASE 
                WHEN bytes_value < 4 * 1024 * 1024 THEN 'LOW - May cause temp files'
                WHEN bytes_value > 1024 * 1024 * 1024 THEN 'HIGH - Risk of OOM'
                ELSE 'REASONABLE'
            END
        WHEN 'maintenance_work_mem' THEN
            CASE 
                WHEN bytes_value < 64 * 1024 * 1024 THEN 'LOW - Slow maintenance ops'
                WHEN bytes_value > 2 * 1024 * 1024 * 1024 THEN 'HIGH - May be excessive'
                ELSE 'REASONABLE'
            END
        WHEN 'effective_cache_size' THEN
            CASE 
                WHEN bytes_value < 1 * 1024 * 1024 * 1024 THEN 'LOW - Underestimating OS cache'
                ELSE 'Check if realistic for your system'
            END
        ELSE 'Review based on workload'
    END as assessment
FROM memory_settings
ORDER BY bytes_value DESC NULLS LAST;

\echo ''

-- Connection and concurrency settings
\echo '--- CONNECTION AND CONCURRENCY SETTINGS ---'
SELECT 
    name as parameter,
    setting as current_value,
    unit,
    source,
    short_desc as description,
    CASE name
        WHEN 'max_connections' THEN
            CASE 
                WHEN setting::int > 1000 THEN 'HIGH - Consider connection pooling'
                WHEN setting::int < 20 THEN 'LOW - May be insufficient'
                ELSE 'REASONABLE'
            END
        WHEN 'max_worker_processes' THEN
            CASE 
                WHEN setting::int < 8 THEN 'LOW - May limit parallelism'
                WHEN setting::int > 64 THEN 'HIGH - May be excessive'
                ELSE 'REASONABLE'
            END
        WHEN 'max_parallel_workers_per_gather' THEN
            CASE 
                WHEN setting::int = 0 THEN 'DISABLED - No parallel queries'
                WHEN setting::int > 8 THEN 'HIGH - Diminishing returns likely'
                ELSE 'REASONABLE'
            END
        ELSE 'Review based on workload'
    END as assessment
FROM pg_settings
WHERE name IN (
    'max_connections',
    'max_worker_processes',
    'max_parallel_workers',
    'max_parallel_workers_per_gather',
    'max_parallel_maintenance_workers'
)
ORDER BY name;

\echo ''

-- WAL and durability configuration
\echo '--- WAL AND DURABILITY CONFIGURATION ---'
SELECT 
    name as parameter,
    setting as current_value,
    unit,
    source,
    short_desc as description,
    CASE name
        WHEN 'wal_level' THEN
            CASE setting
                WHEN 'minimal' THEN 'MINIMAL - No replication/archiving possible'
                WHEN 'replica' THEN 'REPLICA - Standard for replication'
                WHEN 'logical' THEN 'LOGICAL - Enables logical replication'
                ELSE 'UNKNOWN'
            END
        WHEN 'fsync' THEN
            CASE setting
                WHEN 'on' THEN 'SAFE - Ensures durability'
                WHEN 'off' THEN 'DANGEROUS - Risk of data loss'
                ELSE 'UNKNOWN'
            END
        WHEN 'synchronous_commit' THEN
            CASE setting
                WHEN 'on' THEN 'SAFE - Full durability'
                WHEN 'off' THEN 'FAST - Risk of transaction loss'
                WHEN 'local' THEN 'LOCAL - No sync with standby'
                ELSE setting
            END
        WHEN 'checkpoint_completion_target' THEN
            CASE 
                WHEN setting::float < 0.5 THEN 'LOW - May cause I/O spikes'
                WHEN setting::float > 0.9 THEN 'HIGH - May delay checkpoints'
                ELSE 'REASONABLE'
            END
        WHEN 'max_wal_size' THEN
            CASE 
                WHEN pg_size_bytes(setting) < 1024 * 1024 * 1024 THEN 'LOW - Frequent checkpoints'
                WHEN pg_size_bytes(setting) > 100 * 1024 * 1024 * 1024 THEN 'HIGH - Long recovery time'
                ELSE 'REASONABLE'
            END
        ELSE 'Review based on requirements'
    END as assessment
FROM pg_settings
WHERE name IN (
    'wal_level',
    'fsync',
    'synchronous_commit',
    'wal_sync_method',
    'checkpoint_completion_target',
    'checkpoint_timeout',
    'max_wal_size',
    'min_wal_size',
    'wal_buffers'
)
ORDER BY name;

\echo ''

-- Query planner configuration
\echo '--- QUERY PLANNER CONFIGURATION ---'
SELECT 
    name as parameter,
    setting as current_value,
    unit,
    source,
    short_desc as description,
    CASE name
        WHEN 'random_page_cost' THEN
            CASE 
                WHEN setting::float = 4.0 THEN 'DEFAULT - Good for traditional disks'
                WHEN setting::float < 2.0 THEN 'LOW - Good for SSD storage'
                WHEN setting::float > 6.0 THEN 'HIGH - May favor index scans too much'
                ELSE 'CUSTOM'
            END
        WHEN 'seq_page_cost' THEN
            CASE 
                WHEN setting::float != 1.0 THEN 'MODIFIED - Ensure random_page_cost ratio is correct'
                ELSE 'DEFAULT'
            END
        WHEN 'effective_io_concurrency' THEN
            CASE 
                WHEN setting::int = 1 THEN 'LOW - Good for single disk'
                WHEN setting::int > 1000 THEN 'HIGH - May be excessive'
                ELSE 'REASONABLE'
            END
        WHEN 'default_statistics_target' THEN
            CASE 
                WHEN setting::int < 100 THEN 'LOW - May cause poor plans'
                WHEN setting::int > 1000 THEN 'HIGH - Slower ANALYZE'
                ELSE 'REASONABLE'
            END
        ELSE 'Review based on storage and workload'
    END as assessment
FROM pg_settings
WHERE name IN (
    'random_page_cost',
    'seq_page_cost', 
    'cpu_tuple_cost',
    'cpu_index_tuple_cost',
    'cpu_operator_cost',
    'effective_io_concurrency',
    'default_statistics_target',
    'constraint_exclusion',
    'enable_seqscan',
    'enable_indexscan'
)
ORDER BY name;

\echo ''

-- Logging configuration
\echo '--- LOGGING CONFIGURATION ---'
SELECT 
    name as parameter,
    setting as current_value,
    source,
    short_desc as description,
    CASE name
        WHEN 'log_statement' THEN
            CASE setting
                WHEN 'none' THEN 'NONE - No SQL logging'
                WHEN 'ddl' THEN 'DDL - Only schema changes'
                WHEN 'mod' THEN 'MODIFICATIONS - DML and DDL'
                WHEN 'all' THEN 'ALL - Performance impact, use carefully'
                ELSE 'UNKNOWN'
            END
        WHEN 'log_min_duration_statement' THEN
            CASE 
                WHEN setting = '-1' THEN 'DISABLED - No slow query logging'
                WHEN setting::int = 0 THEN 'ALL - Logs every statement'
                WHEN setting::int > 10000 THEN 'HIGH - Only very slow queries'
                ELSE 'ENABLED - Threshold: ' || setting || 'ms'
            END
        WHEN 'log_checkpoints' THEN
            CASE setting
                WHEN 'on' THEN 'ENABLED - Good for monitoring'
                WHEN 'off' THEN 'DISABLED - Consider enabling'
                ELSE 'UNKNOWN'
            END
        ELSE 'Review based on monitoring needs'
    END as assessment
FROM pg_settings
WHERE name IN (
    'logging_collector',
    'log_destination',
    'log_statement',
    'log_min_duration_statement',
    'log_checkpoints',
    'log_connections',
    'log_disconnections',
    'log_lock_waits',
    'log_temp_files',
    'log_autovacuum_min_duration'
)
ORDER BY name;

\echo ''

-- Autovacuum configuration
\echo '--- AUTOVACUUM CONFIGURATION ---'
SELECT 
    name as parameter,
    setting as current_value,
    unit,
    source,
    short_desc as description,
    CASE name
        WHEN 'autovacuum' THEN
            CASE setting
                WHEN 'on' THEN 'ENABLED - Essential for maintenance'
                WHEN 'off' THEN 'DISABLED - Dangerous, enable immediately'
                ELSE 'UNKNOWN'
            END
        WHEN 'autovacuum_max_workers' THEN
            CASE 
                WHEN setting::int < 3 THEN 'LOW - May cause maintenance backlogs'
                WHEN setting::int > 10 THEN 'HIGH - May cause I/O contention'
                ELSE 'REASONABLE'
            END
        WHEN 'autovacuum_vacuum_threshold' THEN
            CASE 
                WHEN setting::int > 100 THEN 'HIGH - Large tables may not vacuum'
                ELSE 'REASONABLE'
            END
        WHEN 'autovacuum_vacuum_scale_factor' THEN
            CASE 
                WHEN setting::float > 0.4 THEN 'HIGH - Tables may accumulate dead tuples'
                WHEN setting::float < 0.1 THEN 'LOW - Very frequent vacuuming'
                ELSE 'REASONABLE'
            END
        ELSE 'Review based on workload patterns'
    END as assessment
FROM pg_settings
WHERE name LIKE 'autovacuum%'
ORDER BY name;

\echo ''

-- Extension and feature configuration
\echo '--- EXTENSIONS AND FEATURES ---'
SELECT 
    extname as extension_name,
    extversion as version,
    nspname as schema,
    CASE extname
        WHEN 'pg_stat_statements' THEN 'Query performance monitoring'
        WHEN 'pg_buffercache' THEN 'Buffer cache inspection'
        WHEN 'pgstattuple' THEN 'Tuple statistics'
        WHEN 'auto_explain' THEN 'Automatic query plan logging'
        WHEN 'pg_prewarm' THEN 'Buffer prewarming'
        WHEN 'pg_hint_plan' THEN 'Query plan hinting'
        ELSE 'See PostgreSQL documentation'
    END as description
FROM pg_extension e
JOIN pg_namespace n ON e.extnamespace = n.oid
ORDER BY extname;

\echo ''

-- Security configuration
\echo '--- SECURITY CONFIGURATION ---'
SELECT 
    name as parameter,
    setting as current_value,
    source,
    short_desc as description,
    CASE name
        WHEN 'ssl' THEN
            CASE setting
                WHEN 'on' THEN 'ENABLED - Secure connections available'
                WHEN 'off' THEN 'DISABLED - Consider enabling for security'
                ELSE 'UNKNOWN'
            END
        WHEN 'password_encryption' THEN
            CASE setting
                WHEN 'scram-sha-256' THEN 'SECURE - Modern encryption'
                WHEN 'md5' THEN 'LEGACY - Consider upgrading to scram-sha-256'
                ELSE 'CHECK - Verify encryption method'
            END
        WHEN 'row_security' THEN
            CASE setting
                WHEN 'on' THEN 'ENABLED - Row Level Security available'
                WHEN 'off' THEN 'DISABLED - No RLS enforcement'
                ELSE 'UNKNOWN'
            END
        ELSE 'Review security requirements'
    END as assessment
FROM pg_settings
WHERE name IN (
    'ssl',
    'password_encryption',
    'row_security',
    'log_statement_stats',
    'track_activities',
    'track_counts'
)
ORDER BY name;

\echo ''

-- Configuration recommendations
\echo '--- CONFIGURATION RECOMMENDATIONS ---'
\echo ''

-- Generate specific recommendations based on current settings
WITH config_analysis AS (
    SELECT 
        (SELECT setting::bigint FROM pg_settings WHERE name = 'shared_buffers') * 
        (CASE WHEN (SELECT unit FROM pg_settings WHERE name = 'shared_buffers') = '8kB' THEN 8192 ELSE 1 END) as shared_buffers_bytes,
        (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') as max_connections,
        (SELECT setting FROM pg_settings WHERE name = 'wal_level') as wal_level,
        (SELECT setting FROM pg_settings WHERE name = 'fsync') as fsync_setting,
        (SELECT setting FROM pg_settings WHERE name = 'autovacuum') as autovacuum_setting,
        (SELECT COUNT(*) FROM pg_extension WHERE extname = 'pg_stat_statements') as has_pg_stat_statements
)
SELECT 
    'MEMORY RECOMMENDATIONS:' as category,
    CASE 
        WHEN shared_buffers_bytes < 128 * 1024 * 1024 THEN 
            'shared_buffers too low - recommend 25% of RAM (current: ' || pg_size_pretty(shared_buffers_bytes) || ')'
        WHEN shared_buffers_bytes > 8 * 1024 * 1024 * 1024 THEN
            'shared_buffers very high - may cause performance issues (current: ' || pg_size_pretty(shared_buffers_bytes) || ')'
        ELSE 'shared_buffers appears reasonable'
    END as recommendation
FROM config_analysis
UNION ALL
SELECT 
    'CONNECTION RECOMMENDATIONS:',
    CASE 
        WHEN max_connections > 1000 THEN
            'max_connections very high (' || max_connections::text || ') - strongly recommend connection pooling'
        WHEN max_connections > 200 THEN
            'max_connections high (' || max_connections::text || ') - consider connection pooling'
        ELSE 'max_connections appears reasonable (' || max_connections::text || ')'
    END
FROM config_analysis
UNION ALL
SELECT 
    'DURABILITY RECOMMENDATIONS:',
    CASE 
        WHEN fsync_setting = 'off' THEN 
            'CRITICAL: fsync is OFF - data loss risk! Enable immediately'
        ELSE 'fsync properly enabled for data safety'
    END
FROM config_analysis
UNION ALL
SELECT 
    'MAINTENANCE RECOMMENDATIONS:',
    CASE 
        WHEN autovacuum_setting = 'off' THEN 
            'CRITICAL: autovacuum is DISABLED - enable immediately to prevent table bloat'
        ELSE 'autovacuum properly enabled'
    END
FROM config_analysis
UNION ALL
SELECT 
    'MONITORING RECOMMENDATIONS:',
    CASE 
        WHEN has_pg_stat_statements = 0 THEN 
            'Install pg_stat_statements extension for query performance monitoring'
        ELSE 'pg_stat_statements extension installed - good for monitoring'
    END
FROM config_analysis;

\echo ''
\echo '================================================='
\echo 'Configuration Analysis Complete'
\echo ''
\echo 'Priority Actions:'
\echo '1. Ensure fsync=on and autovacuum=on (critical for data safety)'
\echo '2. Install pg_stat_statements for query monitoring'
\echo '3. Tune shared_buffers to ~25% of RAM'
\echo '4. Consider connection pooling if max_connections > 200'
\echo '5. Enable checkpoint and slow query logging'
\echo '6. Review security settings (SSL, password encryption)'
\echo ''
\echo 'For detailed tuning guidance, see:'
\echo 'https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server'
\echo '================================================='