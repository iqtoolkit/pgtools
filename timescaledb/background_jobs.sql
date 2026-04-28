/*
 * Script: background_jobs.sql
 * Purpose: Diagnose TimescaleDB background job failures and worker saturation
 *
 * Usage:
 *   psql -d database_name -f timescaledb/background_jobs.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - TimescaleDB extension installed
 *   - Privileges: Any user with access to timescaledb_information views
 *
 * Output:
 *   1. Jobs with failures or non-success status
 *   2. Recent job errors with error messages
 *   3. Background worker saturation check
 *
 * Interpretation:
 *   - If max_background_workers equals active worker count, the pool is saturated
 *     and policies are queueing — bump it (and max_worker_processes) and restart
 *   - Recurring sqlerrcode values in job_errors indicate systematic issues
 *   - Failed compression/retention jobs let data accumulate unbounded
 *
 * Notes:
 *   - Background worker exhaustion is the most common cause of stalled compression
 *     and stale continuous aggregates
 */
\ir ../lib/preflight.sql
DO $preflight$ BEGIN PERFORM pg_temp.pgtools_check(NULL, 'timescaledb'); END $preflight$;
\echo '=== Jobs With Failures or Non-Success Status ==='
SELECT
    proc_name,
    hypertable_name,
    last_run_status,
    last_successful_finish,
    total_failures,
    total_successes,
    last_run_duration
FROM timescaledb_information.job_stats
WHERE total_failures > 0
   OR last_run_status != 'Success'
ORDER BY total_failures DESC;

\echo ''
\echo '=== Recent Job Errors ==='
SELECT
    job_id,
    proc_schema,
    proc_name,
    pid,
    start_time,
    finish_time,
    sqlerrcode,
    err_message
FROM timescaledb_information.job_errors
ORDER BY start_time DESC
LIMIT 50;

\echo ''
\echo '=== Background Worker Saturation ==='
\echo 'Configured limits:'
SHOW timescaledb.max_background_workers;
SHOW max_worker_processes;

\echo ''
\echo 'Active TimescaleDB workers:'
SELECT count(*) AS active_ts_workers
FROM pg_stat_activity
WHERE application_name LIKE '%TimescaleDB Background Worker%';
