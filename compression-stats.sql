/*
 * Script: sql/timescale/compression-stats.sql
 *
 * Purpose: Audits compression settings, policy job status, and effectiveness.
 *
 * Description:
 * This query provides a comprehensive view of the compression status for all
 * hypertables. It joins compression settings, job status, and compression
 * ratio statistics.
 *
 * Red Flags:
 * - `segmentby` is NULL: Compression is not properly configured.
 * - `last_run_status` is 'Failed' or `total_failures` > 0: The compression policy job is failing.
 * - `compression_pct` is low (< 70%): `segmentby`/`orderby` settings may be suboptimal.
 *
 * Interpretation:
 * - A healthy hypertable will have a non-NULL `segmentby`, a 'Success' status
 *   for its compression job, and a high `compression_pct` (typically 90%+).
 *
 * Safety:
 * This script is read-only. It queries TimescaleDB information views and calls
 * the `hypertable_compression_stats()` function, which are designed for
 * efficient diagnostic use.
 */
WITH compression_info AS (
  SELECT
    ht.hypertable_name,
    cs.segmentby,
    cs.orderby,
    j.job_id,
    j.schedule_interval,
    js.last_run_status,
    js.last_successful_finish,
    js.total_failures
  FROM timescaledb_information.hypertables ht
  LEFT JOIN timescaledb_information.compression_settings cs
    ON cs.hypertable_name = ht.hypertable_name
  LEFT JOIN timescaledb_information.jobs j
    ON j.hypertable_name = ht.hypertable_name
    AND j.proc_name = 'policy_compression'
  LEFT JOIN timescaledb_information.job_stats js
    ON js.job_id = j.job_id
)
SELECT
  ci.*,
  pg_size_pretty(hcs.before_compression_total_bytes) AS before_compression,
  pg_size_pretty(hcs.after_compression_total_bytes) AS after_compression,
  round(100.0 * (1 - hcs.after_compression_total_bytes::numeric / NULLIF(hcs.before_compression_total_bytes, 0)), 1) AS compression_pct
FROM compression_info ci
LEFT JOIN hypertable_compression_stats(ci.hypertable_name) hcs ON true;