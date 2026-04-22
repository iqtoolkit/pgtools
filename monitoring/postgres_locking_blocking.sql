/*
 * Script: postgres_locking_blocking.sql
 * Purpose: Advanced lock analysis showing blocking relationships between queries
 * 
 * Usage:
 *   psql -d database_name -f monitoring/postgres_locking_blocking.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: pg_monitor role recommended
 *
 * Output:
 *   - Blocking PID (the blocker)
 *   - Blocked PID (the waiter)
 *   - Blocking query
 *   - Blocked query
 *   - Lock type causing the block
 *   - Wait duration
 *
 * Notes:
 *   - Use when queries are hanging or timing out
 *   - Blocking PID can be terminated if necessary: SELECT pg_terminate_backend(pid);
 *   - Long-running blocking queries may need optimization
 *   - Consider query timeout settings for problematic applications
 *   - Empty result means no blocking is occurring
 */

SELECT
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocking_activity.query AS blocking_query,
    blocking_activity.state AS blocking_state,
    age(now(), blocking_activity.query_start) AS blocking_duration,
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocked_activity.query AS blocked_query,
    age(now(), blocked_activity.query_start) AS blocked_duration,
    blocked_locks.mode AS blocked_lock_mode
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks 
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted
ORDER BY blocked_activity.query_start;