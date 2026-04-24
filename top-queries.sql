/*
 * Script: sql/diagnostics/top-queries.sql
 *
 * Purpose: Shows the most time-consuming queries from pg_stat_statements.
 *
 * Description:
 * This query is one of the most powerful tools for performance analysis. It
 * aggregates runtime statistics for all normalized queries that have run on
 * the system. The output shows which queries are responsible for the most
 * cumulative execution time.
 *
 * NOTE: This script requires the `pg_stat_statements` extension to be enabled.
 * If it is not enabled, this query will fail.
 *
 * Red Flags:
 * - High `total_ms`: A query that is a top contributor to overall workload.
 * - High `mean_ms`: A query that is consistently slow.
 * - High `calls` with low `mean_ms`: Potential N+1 query pattern from an application.
 * - High `pct`: A small number of queries are responsible for a large percentage of DB time.
 *
 * Interpretation:
 * - `total_ms`: The total time spent executing this query across all calls.
 * - `mean_ms`: The average execution time for a single call.
 * - `calls`: The number of times this query has been executed.
 * - `pct`: The percentage of total execution time this query represents.
 *
 * Safety:
 * This script is read-only. It queries the `pg_stat_statements` view, which is
 * designed for performance monitoring and is fast to access.
 */
SELECT
  calls,
  round(total_exec_time::numeric, 2) AS total_ms,
  round(mean_exec_time::numeric, 2) AS mean_ms,
  round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct,
  left(query, 150) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;