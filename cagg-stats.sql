/*
 * Script: sql/timescale/cagg-stats.sql
 *
 * Purpose: Checks the health and refresh status of Continuous Aggregates (CAGGs).
 *
 * Description:
 * This query shows the configuration of each CAGG and the status of its
 * associated refresh policy job. It's critical for ensuring that dashboards
 * and materialized views are not showing stale data.
 *
 * Red Flags:
 * - `last_run_status` is 'Failed': The refresh policy is failing.
 * - `time_since_refresh` is much larger than `schedule_interval`: The CAGG is stale.
 * - `total_failures` > 0: Indicates recurring problems with the refresh job.
 *
 * Interpretation:
 * A healthy CAGG has a 'Success' status, and `time_since_refresh` should be
 * close to the time of the last run, well within the `schedule_interval`.
 *
 * Safety:
 * This script is read-only and queries TimescaleDB's information views, which are
 * optimized for frequent access. Execution time is typically very fast.
 */
SELECT
  ca.view_name,
  j.job_id,
  j.schedule_interval,
  js.last_run_status,
  js.last_successful_finish,
  now() - js.last_successful_finish AS time_since_refresh,
  js.total_failures
FROM timescaledb_information.continuous_aggregates ca
JOIN timescaledb_information.jobs j
  ON j.hypertable_name = ca.materialization_hypertable_name
  AND j.proc_name = 'policy_refresh_continuous_aggregate'
LEFT JOIN timescaledb_information.job_stats js ON js.job_id = j.job_id
ORDER BY time_since_refresh DESC;