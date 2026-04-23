/*
 * Script: sql/diagnostics/activity.sql
 *
 * Purpose: Shows currently running queries and their status.
 *
 * Description:
 * This query provides a snapshot of `pg_stat_activity`, filtered to show only
 * active queries. It is a fundamental tool for understanding the current
 * workload on the database. It excludes idle connections and the current
 * session running this tool.
 *
 * Red Flags:
 * - High `runtime`: Queries that have been running for a long time are often problematic.
 * - `wait_event` is not NULL: The query is waiting on a resource (e.g., 'Lock', 'IO'). This is a key indicator for bottlenecks.
 * - `state = 'active'` but `wait_event` is NULL: The query is likely CPU-bound.
 *
 * Interpretation:
 * - The `runtime` column shows how long the current query has been executing.
 * - `wait_event_type` and `wait_event` tell you exactly what a query is waiting for, if anything.
 * - The `query` column shows the text of the running query, truncated for readability.
 *
 * Safety:
 * This script is read-only. It queries the `pg_stat_activity` view, which is
 * a memory-based view and is extremely fast to access. The `statement_timeout`
 * set by `pgtools.sh` provides an additional safety guarantee.
 */
SELECT
  pid,
  usename,
  application_name,
  state,
  wait_event_type,
  wait_event,
  now() - query_start AS runtime,
  left(query, 200) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND pid <> pg_backend_pid()
ORDER BY query_start;