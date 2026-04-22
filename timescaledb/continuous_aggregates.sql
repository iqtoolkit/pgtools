/*
 * Script: continuous_aggregates.sql
 * Purpose: Monitor TimescaleDB continuous aggregate health, refresh policy lag, and staleness
 *
 * Usage:
 *   psql -d database_name -f timescaledb/continuous_aggregates.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - TimescaleDB extension installed
 *   - Privileges: Any user with access to timescaledb_information views
 *
 * Output:
 *   1. CAGG overview (compression, materialization mode, finalized status)
 *   2. Refresh policy health (schedule vs actual refresh interval, failures)
 *
 * Interpretation:
 *   - time_since_refresh >> schedule_interval means the CAGG is stale and dashboards show old data
 *   - total_failures > 0 warrants investigation via background_jobs.sql
 *   - materialized_only = true means queries never hit raw data (faster, but shows stale results)
 *
 * Notes:
 *   - To check real-world staleness (max materialized time vs now), query each CAGG view directly
 *     since the time column name varies per aggregate
 */

\echo '=== Continuous Aggregate Overview ==='
SELECT
    view_name,
    materialization_hypertable_name,
    compression_enabled,
    materialized_only,
    finalized
FROM timescaledb_information.continuous_aggregates;

\echo ''
\echo '=== Refresh Policy Health ==='
SELECT
    ca.view_name,
    j.job_id,
    j.schedule_interval,
    js.last_run_status,
    js.last_successful_finish,
    now() - js.last_successful_finish  AS time_since_refresh,
    js.total_failures,
    js.total_successes
FROM timescaledb_information.continuous_aggregates ca
JOIN timescaledb_information.jobs j
    ON j.hypertable_name = ca.materialization_hypertable_name
    AND j.proc_name = 'policy_refresh_continuous_aggregate'
LEFT JOIN timescaledb_information.job_stats js
    ON js.job_id = j.job_id;
