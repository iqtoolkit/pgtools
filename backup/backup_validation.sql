/*
 * Script: backup_validation.sql
 * Purpose: Validate backup completeness, integrity, and restore readiness
 * 
 * Usage:
 *   psql -d database_name -f backup/backup_validation.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: pg_monitor role or superuser for full validation
 *
 * Output:
 *   - Database size and backup metrics
 *   - WAL archiving status and gaps
 *   - Backup recoverability indicators
 *   - Point-in-time recovery readiness
 *   - Backup age and frequency analysis
 *
 * Notes:
 *   - Should be run regularly to ensure backup health
 *   - Identifies potential backup issues before they become critical
 *   - Validates both physical and logical backup readiness
 *   - Checks for common backup misconfigurations
 *   - Essential for disaster recovery planning
 */

-- Database size and growth metrics for backup planning
SELECT 
    datname AS database_name,
    pg_size_pretty(pg_database_size(datname)) AS current_size,
    CASE 
        WHEN pg_database_size(datname) > 1024^3 THEN 'Large (>1GB) - Consider parallel backup'
        WHEN pg_database_size(datname) > 100*1024^2 THEN 'Medium (>100MB) - Standard backup OK'
        ELSE 'Small (<100MB) - Fast backup expected'
    END AS backup_complexity,
    age(datfrozenxid) AS xid_age,
    CASE 
        WHEN age(datfrozenxid) > 1000000000 THEN 'CRITICAL: Backup needed before wraparound'
        WHEN age(datfrozenxid) > 500000000 THEN 'WARNING: Consider backup frequency increase'
        ELSE 'OK'
    END AS wraparound_risk
FROM pg_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY pg_database_size(datname) DESC;

-- WAL archiving status and health
SELECT 
    CASE 
        WHEN current_setting('archive_mode') = 'on' THEN 'Enabled'
        ELSE 'DISABLED - Physical backup recovery limited'
    END AS archive_mode_status,
    current_setting('archive_command') AS archive_command,
    CASE 
        WHEN current_setting('archive_command') = '' THEN 'WARNING: No archive command configured'
        WHEN current_setting('archive_command') LIKE '%/bin/true%' THEN 'WARNING: Archive command disabled'
        ELSE 'Configured'
    END AS archive_command_status,
    current_setting('wal_level') AS wal_level,
    CASE 
        WHEN current_setting('wal_level') IN ('replica', 'logical') THEN 'Suitable for backup'
        ELSE 'WARNING: WAL level may be insufficient for PITR'
    END AS wal_level_status;

-- WAL archiving statistics and potential issues
SELECT 
    archived_count AS total_archived,
    last_archived_wal AS last_archived_file,
    last_archived_time,
    CASE 
        WHEN last_archived_time < now() - interval '1 hour' THEN 'WARNING: No recent archiving activity'
        WHEN last_archived_time < now() - interval '15 minutes' THEN 'NOTICE: Archive lag detected'
        ELSE 'OK: Recent archiving activity'
    END AS archiving_health,
    failed_count AS total_failed,
    last_failed_wal AS last_failed_file,
    last_failed_time,
    CASE 
        WHEN failed_count > 0 AND last_failed_time > now() - interval '1 day' THEN 'ERROR: Recent archive failures'
        WHEN failed_count > 0 THEN 'WARNING: Historical archive failures'
        ELSE 'OK: No recent failures'
    END AS failure_status
FROM pg_stat_archiver;

-- Current WAL position and backup LSN tracking
SELECT 
    pg_current_wal_lsn() AS current_wal_lsn,
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')
    ) AS total_wal_generated,
    CASE 
        WHEN extract(epoch from now() - pg_postmaster_start_time()) < 3600 
        THEN 'Recent startup - WAL position may not indicate backup age'
        ELSE 'Normal operation'
    END AS wal_position_context;

-- Replication slots status (affects WAL retention for backups)
SELECT 
    slot_name,
    slot_type,
    database,
    active,
    restart_lsn,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS wal_lag_size,
    CASE 
        WHEN active = false THEN 'WARNING: Inactive slot retaining WAL'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 10*1024^3 
        THEN 'CRITICAL: Slot lagging >10GB - may affect backup retention'
        WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1*1024*1024*1024 
        THEN 'WARNING: Slot lagging >1GB'
        ELSE 'OK'
    END AS slot_health
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

-- Backup-relevant configuration parameters
SELECT 
    name AS parameter,
    setting AS current_value,
    unit,
    CASE name
        WHEN 'max_wal_size' THEN 
            CASE 
                WHEN setting::bigint < 1024 THEN 'Consider increasing for better backup performance'
                ELSE 'Adequate for most backups'
            END
        WHEN 'wal_keep_size' THEN
            CASE 
                WHEN setting = '0' THEN 'Default - relies on replication slots'
                WHEN setting::bigint < 1024 THEN 'Consider increasing for backup safety'
                ELSE 'Should provide backup safety buffer'
            END
        WHEN 'archive_timeout' THEN
            CASE 
                WHEN setting = '0' THEN 'No forced archiving - may delay backup completeness'
                WHEN setting::int > 3600 THEN 'Long timeout - may delay backup freshness'
                ELSE 'Reasonable for backup timeliness'
            END
        WHEN 'checkpoint_timeout' THEN
            CASE 
                WHEN setting::int > 1800 THEN 'Long interval - may affect backup consistency'
                ELSE 'Adequate for backup needs'
            END
        ELSE 'Review documentation for backup implications'
    END AS backup_relevance
FROM pg_settings 
WHERE name IN (
    'max_wal_size', 
    'wal_keep_size', 
    'archive_timeout',
    'checkpoint_timeout',
    'checkpoint_completion_target',
    'wal_compression'
)
ORDER BY name;

-- Tables with potential backup challenges
SELECT 
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS table_size,
    pg_size_pretty(
        pg_total_relation_size(schemaname||'.'||relname) - 
        pg_relation_size(schemaname||'.'||relname)
    ) AS indexes_toast_size,
    n_dead_tup AS dead_tuples,
    CASE 
        WHEN pg_total_relation_size(schemaname||'.'||relname) > 10*1024^3 
        THEN 'Large table - consider parallel backup or pg_dump with jobs'
        WHEN n_dead_tup > n_live_tup * 0.2 
        THEN 'High bloat - VACUUM before backup for efficiency'
        WHEN last_vacuum IS NULL 
        THEN 'Never vacuumed - may have consistency issues'
        ELSE 'Standard backup expected'
    END AS backup_considerations,
    last_vacuum,
    last_analyze
FROM pg_stat_user_tables
WHERE pg_total_relation_size(schemaname||'.'||relname) > 100*1024*1024  -- >100MB
ORDER BY pg_total_relation_size(schemaname||'.'||relname) DESC
LIMIT 20;

-- Backup readiness summary and recommendations
SELECT 
    'Backup Readiness Summary' AS assessment_type,
    CASE 
        WHEN (SELECT current_setting('archive_mode')) = 'off' 
        THEN 'CRITICAL: Archive mode disabled - PITR not possible'
        WHEN (SELECT current_setting('archive_command')) IN ('', '/bin/true', 'exit 0')
        THEN 'CRITICAL: Archive command not configured'
        WHEN (SELECT failed_count FROM pg_stat_archiver) > 0 
             AND (SELECT last_failed_time FROM pg_stat_archiver) > now() - interval '1 day'
        THEN 'ERROR: Recent archive failures detected'
        WHEN EXISTS (
            SELECT 1 FROM pg_replication_slots 
            WHERE active = false 
            AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1*1024*1024*1024
        )
        THEN 'WARNING: Inactive replication slots may affect WAL retention'
        WHEN (SELECT max(age(datfrozenxid)) FROM pg_database) > 1000000000
        THEN 'WARNING: Transaction wraparound risk - backup urgently needed'
        ELSE 'OK: Basic backup prerequisites met'
    END AS overall_status,
    CASE 
        WHEN (SELECT current_setting('archive_mode')) = 'off' 
        THEN 'Enable archive_mode and configure archive_command for PITR'
        WHEN (SELECT current_setting('archive_command')) IN ('', '/bin/true', 'exit 0')
        THEN 'Configure proper archive_command for WAL archiving'
        WHEN (SELECT failed_count FROM pg_stat_archiver) > 0 
        THEN 'Investigate and resolve WAL archiving failures'
        ELSE 'Consider regular backup testing and validation procedures'
    END AS primary_recommendation;

-- Suggested backup commands based on database size and configuration
SELECT 
    datname AS database_name,
    CASE 
        WHEN pg_database_size(datname) > 10*1024^3 THEN
            format('pg_dump -h localhost -p 5432 -U username -Fd -j 4 -f backup_%s_%s %s',
                   datname, 
                   to_char(now(), 'YYYY-MM-DD'),
                   datname)
        WHEN pg_database_size(datname) > 1*1024*1024*1024 THEN
            format('pg_dump -h localhost -p 5432 -U username -Fc -f backup_%s_%s.dump %s',
                   datname,
                   to_char(now(), 'YYYY-MM-DD'),
                   datname)
        ELSE
            format('pg_dump -h localhost -p 5432 -U username -f backup_%s_%s.sql %s',
                   datname,
                   to_char(now(), 'YYYY-MM-DD'),
                   datname)
    END AS suggested_backup_command,
    CASE 
        WHEN pg_database_size(datname) > 10*1024^3 THEN 
            'Directory format with parallel jobs for large database'
        WHEN pg_database_size(datname) > 1*1024*1024*1024 THEN 
            'Custom format for efficient compression and selective restore'
        ELSE 
            'Plain SQL format for simple restore'
    END AS format_rationale
FROM pg_database
WHERE datname NOT IN ('template0', 'template1', 'postgres')
ORDER BY pg_database_size(datname) DESC;