/*
 * Script: wait_event_analysis.sql
 * Purpose: Comprehensive analysis of PostgreSQL wait events and performance bottlenecks
 * 
 * This script analyzes wait events to identify performance bottlenecks in PostgreSQL.
 * Wait events indicate what processes are waiting for and help diagnose performance issues.
 * 
 * Requires: PostgreSQL 15+, pg_stat_activity access
 * Privileges: pg_monitor role or superuser
 * 
 * Usage: psql -f performance/wait_event_analysis.sql
 * 
 * Author: pgtools
 * Version: 1.0
 * Date: 2024-10-25
 */

\echo '================================================='
\echo 'PostgreSQL Wait Event Analysis'
\echo '================================================='
\echo ''

-- Current wait events summary
\echo '--- CURRENT WAIT EVENTS SUMMARY ---'
SELECT 
    wait_event_type,
    wait_event,
    COUNT(*) as waiting_processes,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM pg_stat_activity 
WHERE wait_event IS NOT NULL
    AND state = 'active'
GROUP BY wait_event_type, wait_event
ORDER BY waiting_processes DESC;

\echo ''

-- Lock wait analysis
\echo '--- LOCK WAIT ANALYSIS ---'
SELECT 
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS current_statement_in_blocking_process,
    blocked_activity.wait_event,
    blocked_activity.wait_event_type,
    EXTRACT(EPOCH FROM (now() - blocked_activity.query_start))::INT AS blocked_duration_seconds
FROM pg_catalog.pg_locks blocked_locks
    JOIN pg_catalog.pg_stat_activity blocked_activity 
        ON blocked_activity.pid = blocked_locks.pid
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
    JOIN pg_catalog.pg_stat_activity blocking_activity 
        ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted
ORDER BY blocked_duration_seconds DESC;

\echo ''

-- I/O wait events
\echo '--- I/O WAIT EVENTS ---'
SELECT 
    wait_event_type,
    wait_event,
    COUNT(*) as processes,
    CASE wait_event
        WHEN 'DataFileRead' THEN 'Reading data files from disk'
        WHEN 'DataFileWrite' THEN 'Writing data files to disk'
        WHEN 'WALWrite' THEN 'Writing WAL to disk'
        WHEN 'WALSync' THEN 'Syncing WAL to disk'
        WHEN 'CheckpointSync' THEN 'Syncing files during checkpoint'
        WHEN 'CheckpointWrite' THEN 'Writing files during checkpoint'
        WHEN 'BufferIO' THEN 'Buffer I/O operations'
        ELSE 'Other I/O operation'
    END as description
FROM pg_stat_activity 
WHERE wait_event_type = 'IO'
    AND wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY processes DESC;

\echo ''

-- CPU and activity analysis
\echo '--- CPU AND ACTIVITY ANALYSIS ---'
SELECT 
    state,
    COUNT(*) as processes,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage,
    CASE state
        WHEN 'active' THEN 'Currently executing'
        WHEN 'idle' THEN 'Waiting for new command'
        WHEN 'idle in transaction' THEN 'In transaction, waiting for command'
        WHEN 'idle in transaction (aborted)' THEN 'In failed transaction'
        WHEN 'fastpath function call' THEN 'Executing fastpath function'
        WHEN 'disabled' THEN 'Disabled connection'
        ELSE 'Other state'
    END as description
FROM pg_stat_activity 
GROUP BY state
ORDER BY processes DESC;

\echo ''

-- Long running queries with wait events
\echo '--- LONG RUNNING QUERIES WITH WAIT EVENTS ---'
SELECT 
    pid,
    usename,
    application_name,
    client_addr,
    wait_event_type,
    wait_event,
    state,
    EXTRACT(EPOCH FROM (now() - query_start))::INT AS duration_seconds,
    EXTRACT(EPOCH FROM (now() - state_change))::INT AS state_duration_seconds,
    LEFT(query, 100) || '...' AS query_snippet
FROM pg_stat_activity 
WHERE state = 'active'
    AND query_start < now() - interval '30 seconds'
ORDER BY duration_seconds DESC
LIMIT 20;

\echo ''

-- Wait event statistics (if pg_stat_statements available)
\echo '--- WAIT EVENT TRENDS (requires pg_stat_statements) ---'
DO $analysis$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        RAISE NOTICE 'pg_stat_statements extension found - analyzing wait patterns';
        
        -- This would require custom wait event tracking
        -- For now, show basic query performance metrics
        EXECUTE 'SELECT
            calls,
            total_exec_time,
            mean_exec_time,
            stddev_exec_time,
            rows,
            LEFT(query, 80) || ''...'' AS query_snippet
        FROM pg_stat_statements
        WHERE mean_exec_time > 1000
        ORDER BY mean_exec_time DESC
        LIMIT 10';
    ELSE
        RAISE NOTICE 'pg_stat_statements extension not available';
        RAISE NOTICE 'Install with: CREATE EXTENSION pg_stat_statements;';
    END IF;
END;
$analysis$;

\echo ''

-- Connection pool wait analysis
\echo '--- CONNECTION POOL ANALYSIS ---'
SELECT 
    application_name,
    COUNT(*) as total_connections,
    COUNT(*) FILTER (WHERE state = 'active') as active_connections,
    COUNT(*) FILTER (WHERE state = 'idle') as idle_connections,
    COUNT(*) FILTER (WHERE state = 'idle in transaction') as idle_in_transaction,
    COUNT(*) FILTER (WHERE wait_event IS NOT NULL) as waiting_connections,
    ROUND(AVG(EXTRACT(EPOCH FROM (now() - query_start)))) as avg_query_duration_seconds
FROM pg_stat_activity 
WHERE application_name IS NOT NULL
GROUP BY application_name
ORDER BY total_connections DESC;

\echo ''

-- Checkpoint and WAL wait analysis  
\echo '--- CHECKPOINT AND WAL ANALYSIS ---'
SELECT 
    wait_event,
    COUNT(*) as processes,
    CASE wait_event
        WHEN 'CheckpointStart' THEN 'Waiting for checkpoint to start'
        WHEN 'CheckpointWrite' THEN 'Writing checkpoint data'
        WHEN 'CheckpointSync' THEN 'Syncing checkpoint files'
        WHEN 'WALWrite' THEN 'Writing WAL records'
        WHEN 'WALSync' THEN 'Syncing WAL to disk'
        WHEN 'WALArchiveCommand' THEN 'WAL archive command execution'
        ELSE wait_event
    END as description
FROM pg_stat_activity 
WHERE wait_event IN (
    'CheckpointStart', 'CheckpointWrite', 'CheckpointSync',
    'WALWrite', 'WALSync', 'WALArchiveCommand'
)
GROUP BY wait_event
ORDER BY processes DESC;

\echo ''

-- Background worker analysis
\echo '--- BACKGROUND WORKER ANALYSIS ---'
SELECT 
    backend_type,
    COUNT(*) as processes,
    COUNT(*) FILTER (WHERE wait_event IS NOT NULL) as waiting_processes,
    string_agg(DISTINCT wait_event, ', ' ORDER BY wait_event) as wait_events
FROM pg_stat_activity 
WHERE backend_type IS NOT NULL
    AND backend_type != 'client backend'
GROUP BY backend_type
ORDER BY processes DESC;

\echo ''

-- Wait event recommendations
\echo '--- WAIT EVENT ANALYSIS RECOMMENDATIONS ---'
\echo ''
\echo 'COMMON WAIT EVENT INTERPRETATIONS:'
\echo ''
\echo 'I/O Related:'
\echo '  DataFileRead/Write - Check disk I/O performance, consider SSD upgrade'
\echo '  WALWrite/WALSync - Check WAL disk performance, consider separate WAL disk'
\echo '  CheckpointWrite/Sync - Tune checkpoint_completion_target and wal_buffers'
\echo ''
\echo 'Locking Related:'
\echo '  Lock - Check for long transactions, optimize queries, review locking patterns'
\echo '  LWLock - Usually brief, but many may indicate contention'
\echo ''
\echo 'CPU Related:'
\echo '  No wait events + active state - CPU bound, optimize queries or add CPU'
\echo ''
\echo 'Memory Related:'
\echo '  BufferPin - Memory/buffer contention, consider increasing shared_buffers'
\echo ''
\echo 'Network Related:'
\echo '  ClientRead/Write - Network latency or client processing delays'
\echo ''

-- Performance tuning suggestions based on current waits
WITH current_waits AS (
    SELECT 
        wait_event_type,
        wait_event,
        COUNT(*) as processes
    FROM pg_stat_activity 
    WHERE wait_event IS NOT NULL
        AND state = 'active'
    GROUP BY wait_event_type, wait_event
    HAVING COUNT(*) > 0
)
SELECT 
    'TUNING SUGGESTIONS BASED ON CURRENT WAITS:' as analysis,
    '' as suggestion
UNION ALL
SELECT 
    CASE 
        WHEN wait_event_type = 'IO' THEN 'I/O Performance Issue Detected'
        WHEN wait_event_type = 'Lock' THEN 'Locking Contention Detected' 
        WHEN wait_event_type = 'LWLock' THEN 'Lightweight Lock Contention'
        ELSE wait_event_type || ' Wait Detected'
    END,
    CASE 
        WHEN wait_event = 'DataFileRead' THEN 'Consider: faster storage, more RAM, query optimization'
        WHEN wait_event = 'WALWrite' THEN 'Consider: separate WAL disk, increase wal_buffers'
        WHEN wait_event IN ('relation', 'tuple') THEN 'Consider: shorter transactions, query optimization'
        WHEN wait_event = 'BufferPin' THEN 'Consider: increase shared_buffers'
        ELSE 'Review PostgreSQL configuration for ' || wait_event
    END
FROM current_waits
WHERE processes > 1
ORDER BY processes DESC;

\echo ''
\echo '================================================='
\echo 'Wait Event Analysis Complete'
\echo ''
\echo 'For detailed wait event documentation, see:'
\echo 'https://www.postgresql.org/docs/current/monitoring-stats.html#WAIT-EVENT-TABLE'
\echo '================================================='