/*
 * Script: sql/timescale/job-errors.sql
 *
 * Purpose: Shows recent errors from TimescaleDB background jobs.
 *
 * Description:
 * This query retrieves the most recent errors logged by the TimescaleDB
 * background worker scheduler. It is the primary tool for debugging why a
 * policy (compression, CAGG refresh, retention) is failing.
 *
 * Red Flags:
 * - Any rows returned are a red flag.
 * - Repetitive `err_message` for the same `job_id`: Indicates a persistent problem.
 * - `sqlerrcode` other than '00000': Provides the specific SQL error code.
 *
 * Interpretation:
 * - `proc_name`: The type of job that failed (e.g., 'policy_compression').
 * - `err_message`: The detailed error message, often explaining the root cause
 *   (e.g., permission denied, constraint violation).
 *
 * Safety:
 * This script is read-only. It queries the `timescaledb_information.job_errors`
 * view, which is designed for efficient diagnostic use.
 */
SELECT
  job_id,
  proc_name,
  start_time,
  finish_time,
  sqlerrcode,
  err_message
FROM timescaledb_information.job_errors
ORDER BY start_time DESC
LIMIT 50;