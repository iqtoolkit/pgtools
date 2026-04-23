/*
 * Script: sql/diagnostics/locks.sql
 *
 * Purpose: Displays current lock contention and identifies blocking queries.
 *
* Description:
 * This is a critical first-response query to diagnose slow or hung systems.
 * It joins `pg_locks` with `pg_stat_activity` to show which queries are
 * holding locks and which are waiting for them. The output is ordered to
 * show waiting locks first.
 *
 * Red Flags:
 * - `granted = 'f'`: A query is waiting for a lock, indicating a blocking situation.
 * - `state = 'idle in transaction'`: A session is holding locks while not actively running a query. This is a common cause of blocking.
 * - `mode = 'AccessExclusiveLock'`: A highly restrictive lock is being held (e.g., by ALTER TABLE, DROP TABLE), blocking almost all other operations on that table.
 * - High `query_age`: A query has been running for a long time, potentially holding locks and blocking others.
 *
 * Interpretation:
 * - Look for rows where `granted` is `f` (false). The `pid` in that row is the *blocked* process.
 * - To find the *blocking* process, you need to find which other process holds a conflicting lock on the same `relation`, `transactionid`, etc.
 * - The `query` and `query_age` columns are essential for understanding the context of the lock.
 *
 * Safety:
 * This script is read-only. It queries standard `pg_catalog` views (`pg_locks`,
 * `pg_stat_activity`, `pg_database`) which are designed for diagnostics.
 * While generally fast, it can be slower on systems with thousands of active
 * connections or locks. The `statement_timeout` set by `pgtools.sh` provides
 * a safety guarantee.
 */
SELECT
    l.locktype,
    l.relation::regclass AS relation,
    l.mode,
    l.granted,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    age(now(), a.query_start) AS query_age,
    a.state,
    a.wait_event_type,
    a.wait_event,
    a.query
FROM pg_locks l
LEFT JOIN pg_stat_activity a ON l.pid = a.pid
WHERE a.pid IS NOT NULL
  AND a.pid <> pg_backend_pid()
ORDER BY l.granted, a.query_start;