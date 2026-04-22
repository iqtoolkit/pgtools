/*
 * Script: connection_pools.sql
 * Purpose: Monitor connection pooling health, efficiency, and potential issues
 * 
 * Usage:
 *   psql -d database_name -f monitoring/connection_pools.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: pg_monitor role or sufficient permissions
 *   - Works with PgBouncer, Pgpool-II, and built-in connection info
 *
 * Output:
 *   - Current connection statistics and patterns
 *   - Connection pool efficiency metrics
 *   - Connection age and idle time analysis
 *   - Application connection patterns
 *   - Connection limit utilization
 *   - Potential connection leaks detection
 *
 * Notes:
 *   - Essential for connection pool optimization
 *   - Helps identify connection bottlenecks
 *   - Detects connection leaks and inefficient patterns
 *   - Provides recommendations for pool tuning
 *   - Should be run regularly on high-traffic systems
 */

-- Connection overview and limit utilization
SELECT 
    COUNT(*) AS total_connections,
    COUNT(*) FILTER (WHERE state = 'active') AS active_connections,
    COUNT(*) FILTER (WHERE state = 'idle') AS idle_connections,
    COUNT(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction,
    COUNT(*) FILTER (WHERE state = 'idle in transaction (aborted)') AS idle_in_transaction_aborted,
    (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections,
    ROUND(
        100.0 * COUNT(*) / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'), 2
    ) AS connection_utilization_percent,
    CASE 
        WHEN COUNT(*) > (SELECT setting::int * 0.8 FROM pg_settings WHERE name = 'max_connections')
        THEN 'CRITICAL: >80% connection limit used'
        WHEN COUNT(*) > (SELECT setting::int * 0.6 FROM pg_settings WHERE name = 'max_connections')
        THEN 'WARNING: >60% connection limit used'
        ELSE 'OK: Connection usage within limits'
    END AS utilization_status
FROM pg_stat_activity;

-- Connection patterns by database and application
SELECT 
    datname AS database_name,
    application_name,
    usename AS username,
    client_addr,
    COUNT(*) AS connection_count,
    COUNT(*) FILTER (WHERE state = 'active') AS active_count,
    COUNT(*) FILTER (WHERE state = 'idle') AS idle_count,
    COUNT(*) FILTER (WHERE state LIKE 'idle in transaction%') AS idle_in_tx_count,
    ROUND(AVG(EXTRACT(EPOCH FROM (now() - backend_start)))) AS avg_connection_age_seconds,
    MAX(EXTRACT(EPOCH FROM (now() - backend_start))) AS max_connection_age_seconds,
    CASE 
        WHEN COUNT(*) FILTER (WHERE state LIKE 'idle in transaction%') > 5 
        THEN 'WARNING: Many idle-in-transaction connections'
        WHEN MAX(EXTRACT(EPOCH FROM (now() - backend_start))) > 3600 
        THEN 'NOTICE: Long-lived connections detected'
        ELSE 'Normal connection pattern'
    END AS pattern_assessment
FROM pg_stat_activity
WHERE pid != pg_backend_pid()  -- Exclude current connection
GROUP BY datname, application_name, usename, client_addr
HAVING COUNT(*) > 1  -- Only show applications with multiple connections
ORDER BY connection_count DESC, idle_in_tx_count DESC;

-- Long-running and problematic connections
SELECT 
    pid,
    usename,
    datname,
    application_name,
    client_addr,
    state,
    backend_start,
    query_start,
    state_change,
    EXTRACT(EPOCH FROM (now() - backend_start))::int AS connection_age_seconds,
    EXTRACT(EPOCH FROM (now() - query_start))::int AS query_age_seconds,
    EXTRACT(EPOCH FROM (now() - state_change))::int AS state_age_seconds,
    CASE 
        WHEN state = 'idle in transaction' AND now() - state_change > interval '5 minutes'
        THEN 'CRITICAL: Long idle-in-transaction (potential leak)'
        WHEN state = 'idle in transaction (aborted)' 
        THEN 'ERROR: Aborted transaction (needs cleanup)'
        WHEN state = 'active' AND now() - query_start > interval '30 minutes'
        THEN 'WARNING: Very long-running query'
        WHEN state = 'idle' AND now() - state_change > interval '2 hours'
        THEN 'NOTICE: Very long idle connection'
        ELSE 'Normal'
    END AS connection_status,
    LEFT(query, 100) AS query_snippet
FROM pg_stat_activity
WHERE pid != pg_backend_pid()
    AND (
        (state = 'idle in transaction' AND now() - state_change > interval '1 minute')
        OR (state = 'idle in transaction (aborted)')
        OR (state = 'active' AND now() - query_start > interval '5 minutes')
        OR (now() - backend_start > interval '1 hour')
    )
ORDER BY 
    CASE 
        WHEN state = 'idle in transaction (aborted)' THEN 1
        WHEN state = 'idle in transaction' THEN 2
        WHEN state = 'active' THEN 3
        ELSE 4
    END,
    state_change;

-- Connection pool efficiency analysis
WITH connection_stats AS (
    SELECT 
        COUNT(*) as total_connections,
        COUNT(*) FILTER (WHERE state = 'active') as active_connections,
        COUNT(*) FILTER (WHERE state = 'idle') as idle_connections,
        COUNT(*) FILTER (WHERE state LIKE 'idle in transaction%') as problematic_connections,
        AVG(EXTRACT(EPOCH FROM (now() - backend_start))) as avg_connection_age,
        (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') as max_connections
    FROM pg_stat_activity
)
SELECT
    total_connections,
    active_connections,
    idle_connections,
    problematic_connections,
    ROUND((active_connections * 100.0 / NULLIF(total_connections, 0))::numeric, 2) AS active_percentage,
    ROUND((idle_connections * 100.0 / NULLIF(total_connections, 0))::numeric, 2) AS idle_percentage,
    ROUND((problematic_connections * 100.0 / NULLIF(total_connections, 0))::numeric, 2) AS problematic_percentage,
    ROUND(avg_connection_age::numeric, 0) AS avg_connection_age_seconds,
    max_connections,
    CASE 
        WHEN active_connections * 100.0 / NULLIF(total_connections, 0) > 80 
        THEN 'Excellent: High connection utilization'
        WHEN active_connections * 100.0 / NULLIF(total_connections, 0) > 50 
        THEN 'Good: Decent connection utilization'
        WHEN active_connections * 100.0 / NULLIF(total_connections, 0) > 20 
        THEN 'Fair: Some idle connections'
        ELSE 'Poor: Many idle connections - consider connection pooling'
    END AS pool_efficiency,
    CASE 
        WHEN problematic_connections > 10 
        THEN 'CRITICAL: Many problematic connections - investigate application logic'
        WHEN problematic_connections > 5 
        THEN 'WARNING: Some problematic connections'
        ELSE 'OK: Few problematic connections'
    END AS connection_health
FROM connection_stats;

-- Connection churn analysis (requires pg_stat_database)
SELECT 
    datname AS database_name,
    numbackends AS current_backends,
    xact_commit + xact_rollback AS total_transactions,
    xact_commit AS committed_transactions,
    xact_rollback AS rolled_back_transactions,
    CASE 
        WHEN xact_commit + xact_rollback > 0 
        THEN ROUND((xact_rollback * 100.0 / (xact_commit + xact_rollback))::numeric, 2)
        ELSE 0 
    END AS rollback_percentage,
    blks_read + blks_hit AS total_block_access,
    CASE 
        WHEN blks_read + blks_hit > 0 
        THEN ROUND((blks_hit * 100.0 / (blks_read + blks_hit))::numeric, 2)
        ELSE 0 
    END AS cache_hit_ratio,
    deadlocks,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_data_size,
    stats_reset
FROM pg_stat_database 
WHERE datname NOT IN ('template0', 'template1')
ORDER BY total_transactions DESC;

-- Recommendations for connection pool optimization
WITH pool_analysis AS (
    SELECT 
        COUNT(*) as total_conn,
        COUNT(*) FILTER (WHERE state = 'active') as active_conn,
        COUNT(*) FILTER (WHERE state = 'idle') as idle_conn,
        COUNT(*) FILTER (WHERE state LIKE 'idle in transaction%') as idle_tx_conn,
        COUNT(DISTINCT application_name) as app_count,
        COUNT(DISTINCT client_addr) as client_count,
        (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') as max_conn
    FROM pg_stat_activity 
    WHERE pid != pg_backend_pid()
)
SELECT 
    'Connection Pool Recommendations' AS recommendation_type,
    CASE 
        WHEN idle_conn > active_conn * 2 
        THEN format('Consider connection pooling: %s idle vs %s active connections', idle_conn, active_conn)
        WHEN total_conn > max_conn * 0.8 
        THEN format('Increase max_connections or implement pooling: %s/%s connections used', total_conn, max_conn)
        WHEN idle_tx_conn > 5 
        THEN format('Fix application logic: %s idle-in-transaction connections detected', idle_tx_conn)
        WHEN app_count > 10 
        THEN format('Consider connection multiplexing: %s different applications connecting', app_count)
        ELSE 'Connection usage appears optimal'
    END AS primary_recommendation,
    CASE 
        WHEN idle_conn > active_conn * 2 
        THEN 'Suggested pool size: ' || GREATEST(active_conn + 2, 5)::text || ' connections per database'
        WHEN total_conn > max_conn * 0.8 
        THEN 'Consider PgBouncer with pool_mode=transaction for better efficiency'
        WHEN idle_tx_conn > 5 
        THEN 'Review application transaction management and connection handling'
        ELSE 'Monitor connection patterns and adjust as workload changes'
    END AS detailed_guidance
FROM pool_analysis;

-- PgBouncer-style connection state simulation (if using external pooler)
SELECT 
    'Connection Pool Simulation' AS analysis_type,
    COUNT(*) as total_backend_connections,
    COUNT(DISTINCT (datname, usename)) as unique_db_user_combinations,
    ROUND(AVG(EXTRACT(EPOCH FROM (now() - backend_start)))) as avg_backend_age_seconds,
    COUNT(*) FILTER (WHERE state = 'active') as would_be_server_active,
    COUNT(*) FILTER (WHERE state != 'active') as would_be_server_idle,
    CASE 
        WHEN COUNT(*) > COUNT(DISTINCT (datname, usename)) * 5 
        THEN 'High potential for pooling benefits - many connections per user/db'
        WHEN COUNT(*) > COUNT(DISTINCT (datname, usename)) * 2 
        THEN 'Moderate potential for pooling benefits'
        ELSE 'Limited pooling benefits - consider application-level optimization'
    END as pooling_benefit_assessment,
    'Estimated pool size needed: ' || 
    GREATEST(
        COUNT(*) FILTER (WHERE state = 'active') + 2,  -- Active + small buffer
        5  -- Minimum reasonable pool size
    ) || ' per database' as suggested_pool_config
FROM pg_stat_activity 
WHERE pid != pg_backend_pid();

-- Connection distribution by hour (requires historical data or multiple runs)
SELECT 
    EXTRACT(hour FROM backend_start) AS connection_start_hour,
    COUNT(*) AS connections_started,
    COUNT(*) FILTER (WHERE state = 'active') AS currently_active,
    AVG(EXTRACT(EPOCH FROM (now() - backend_start)))::int AS avg_age_seconds,
    CASE 
        WHEN COUNT(*) > (SELECT COUNT(*) * 0.2 FROM pg_stat_activity WHERE pid != pg_backend_pid())
        THEN 'Peak connection period'
        ELSE 'Normal connection period'
    END AS period_classification
FROM pg_stat_activity 
WHERE pid != pg_backend_pid()
    AND backend_start > now() - interval '24 hours'
GROUP BY EXTRACT(hour FROM backend_start)
ORDER BY connection_start_hour;