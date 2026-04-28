
/*
 * Script: bloating.sql
 * Purpose: Detect table and index bloat to identify candidates for VACUUM/REINDEX
 * 
 * ANNOTATED EXAMPLE:
 *   # Check current bloating status
 *   psql -d production -f monitoring/bloating.sql
 *
 *   # Focus on tables with high bloat (>20%)
 *   psql -d production -f monitoring/bloating.sql | awk '$6 > 20 {print}'
 *
 *   # Weekly bloat monitoring report
 *   psql -d production -f monitoring/bloating.sql > weekly_bloat_$(date +%Y%m%d).log
 *
 * SAMPLE OUTPUT:
 *   table_name     | total_size | dead_tuples | live_tuples | dead_tuple_percent | table_size | last_vacuum         | last_autovacuum
 *   ---------------|------------|-------------|-------------|-------------------|------------|--------------------|-----------------
 *   public.orders  | 2.1 GB     | 450000      | 1800000     | 20.00             | 1.8 GB     | 2025-10-20 02:30:00| 2025-10-24 18:45:00
 *   public.sessions| 856 MB     | 890000      | 120000      | 88.12             | 720 MB     | NULL               | 2025-10-23 03:15:00
 *   public.users   | 1.2 GB     | 75000       | 950000      | 7.32              | 1.1 GB     | 2025-10-24 02:00:00| NULL
 *
 * INTERPRETATION:
 *   - orders: 20% dead tuples - schedule VACUUM soon
 *   - sessions: 88% dead tuples - CRITICAL, needs immediate VACUUM FULL
 *   - users: 7% dead tuples - healthy, no immediate action needed
 *
 * BLOAT THRESHOLDS AND ACTIONS:
 *   - 0-10%: Healthy - no action required
 *   - 10-20%: Monitor - consider scheduling VACUUM
 *   - 20-40%: Warning - schedule VACUUM during maintenance window
 *   - 40-60%: Critical - immediate VACUUM required
 *   - >60%: Emergency - consider VACUUM FULL or table rebuild
 *
 * MAINTENANCE ACTIONS:
 *   # Standard VACUUM (recommended for 20-40% bloat)
 *   VACUUM ANALYZE public.orders;
 *
 *   # Aggressive VACUUM for high bloat (40-60%)
 *   VACUUM (FULL, ANALYZE) public.sessions;
 *
 *   # Automated maintenance using pgtools
 *   ./maintenance/auto_maintenance.sh --operation vacuum --dead-threshold 20
 *
 * PREVENTION STRATEGIES:
 *   - Tune autovacuum settings for high-update tables
 *   - Schedule regular VACUUM operations during low-traffic periods
 *   - Monitor table growth patterns and adjust thresholds
 *   - Consider partitioning for very large tables
 *
 * AUTOVACUUM TUNING EXAMPLE:
 *   ALTER TABLE high_update_table SET (
 *       autovacuum_vacuum_threshold = 50,
 *       autovacuum_vacuum_scale_factor = 0.1,
 *       autovacuum_analyze_threshold = 25,
 *       autovacuum_analyze_scale_factor = 0.05
 *   );
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: pg_monitor role or pg_stat_all_tables access
 *   - track_counts = on (default in PostgreSQL)
 *
 * Output Description:
 *   - table_name: Schema-qualified table name
 *   - total_size: Total size including indexes and TOAST data
 *   - dead_tuples: Number of dead tuples (deleted/updated rows not yet vacuumed)
 *   - live_tuples: Number of live tuples (active rows)
 *   - dead_tuple_percent: Percentage of dead tuples (key metric for bloat)
 *   - table_size: Size of table data only (excluding indexes)
 *   - last_vacuum: Timestamp of last manual VACUUM
 *   - last_autovacuum: Timestamp of last automatic VACUUM
 *
 * PERFORMANCE IMPACT:
 *   - High bloat increases table scan times
 *   - Reduces buffer cache efficiency
 *   - Increases storage costs and backup times
 *   - Can lead to index bloat and degraded query performance
 *
 * MONITORING SCHEDULE:
 *   - Daily: Check critical production tables
 *   - Weekly: Full database bloat analysis
 *   - Monthly: Review autovacuum effectiveness
 *   - After bulk operations: Immediate bloat check
 */

-- Table bloat estimation
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size,
    n_dead_tup AS dead_tuples,
    n_live_tup AS live_tuples,
    ROUND(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_tuple_percent,
    pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) AS table_size,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 50;