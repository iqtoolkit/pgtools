/*
 * Script: locks.sql
 * Purpose: Display current locks in the database with query information
 *
 * Usage:
 *   psql -d database_name -f monitoring/locks.sql
 *
 * ANNOTATED EXAMPLE:
 *   # Check for locks during performance issues
 *   psql -d production -f monitoring/locks.sql
 *
 *   # Save output to file for analysis
 *   psql -d production -f monitoring/locks.sql > locks_$(date +%Y%m%d_%H%M).log
 *
 *   # Filter for waiting locks only
 *   psql -d production -f monitoring/locks.sql | grep "f.*active"
 *
 * SAMPLE OUTPUT:
 *   locktype | relation | mode              | granted | pid  | usename | query_age | state  | query
 *   ---------|----------|-------------------|---------|------|---------|-----------|--------|-------
 *   relation | users    | AccessShareLock   | t       | 1234 | app_user| 00:00:15  | active | SELECT * FROM users WHERE id = 1
 *   relation | orders   | RowExclusiveLock  | t       | 5678 | app_user| 00:01:30  | active | UPDATE orders SET status = 'shipped'
 *   relation | products | AccessShareLock   | f       | 9012 | app_user| 00:02:45  | active | SELECT * FROM products JOIN orders
 *
 * INTERPRETATION:
 *   - First two rows: Normal operations with granted locks
 *   - Third row: WAITING lock (granted=f) - potential blocking situation
 *   - query_age shows how long the query has been running
 *   - AccessExclusiveLock would indicate DDL operations (ALTER, DROP)
 *
 * COMMON LOCK MODES:
 *   - AccessShareLock: SELECT queries (least restrictive)
 *   - RowShareLock: SELECT FOR UPDATE/SHARE
 *   - RowExclusiveLock: INSERT, UPDATE, DELETE
 *   - ShareUpdateExclusiveLock: VACUUM, ANALYZE, CREATE INDEX CONCURRENTLY
 *   - ShareLock: CREATE INDEX (non-concurrent)
 *   - ShareRowExclusiveLock: CREATE TRIGGER, some ALTER TABLE
 *   - ExclusiveLock: REFRESH MATERIALIZED VIEW CONCURRENTLY
 *   - AccessExclusiveLock: DROP TABLE, TRUNCATE, ALTER TABLE (most restrictive)
 *
 * TROUBLESHOOTING STEPS:
 *   1. Identify waiting locks (granted = f)
 *   2. Find blocking process using postgres_locking_blocking.sql
 *   3. Consider terminating long-running blocking queries
 *   4. Review application logic for lock optimization
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: pg_monitor role or sufficient permissions to view pg_locks and pg_stat_activity
 *
 * Output Description:
 *   - locktype: Type of lockable object (relation, tuple, transactionid, etc.)
 *   - relation: Name of locked table/index (NULL for non-relation locks)
 *   - mode: Lock mode indicating level of restrictiveness
 *   - granted: Whether lock is granted (t) or waiting (f)
 *   - pid: Process ID holding or waiting for the lock
 *   - usename: Database user name
 *   - query_age: How long the current query has been running
 *   - state: Current state of the session (active, idle, idle in transaction)
 *   - query: The actual SQL query being executed
 *
 * CRITICAL ALERTS:
 *   - Any AccessExclusiveLock during business hours
 *   - Locks waiting longer than 5 minutes
 *   - Multiple processes waiting on the same resource
 *   - Locks held by idle in transaction sessions
 */

\ir ../lib/preflight.sql
DO $preflight$ BEGIN PERFORM pg_temp.pgtools_check('pg_monitor', NULL); END $preflight$;

SELECT
    l.locktype,
    l.database,
    l.relation::regclass AS relation,
    l.page,
    l.tuple,
    l.virtualxid,
    l.transactionid,
    l.mode,
    l.granted,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    age(now(), a.query_start) AS query_age,
    a.state,
    a.query
FROM pg_locks l
LEFT JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    OR l.database IS NULL
ORDER BY l.granted, a.query_start;