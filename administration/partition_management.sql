/*
 * Script: partition_management.sql
 * Purpose: Monitor partition health, performance, and provide maintenance utilities
 * 
 * Usage:
 *   psql -d database_name -f administration/partition_management.sql
 *
 * Requirements:
 *   - PostgreSQL 15+ (native partitioning)
 *   - Privileges: pg_monitor role or table owner permissions
 *
 * Output:
 *   - Partition hierarchy and distribution
 *   - Partition size analysis and balance
 *   - Partition pruning effectiveness
 *   - Maintenance recommendations
 *   - Automated partition management suggestions
 *
 * Notes:
 *   - Essential for partitioned table maintenance
 *   - Helps identify partition imbalances
 *   - Provides guidance for partition lifecycle management
 *   - Monitors constraint exclusion effectiveness
 *   - Supports both range and list partitioning strategies
 */

-- Partitioned tables overview and hierarchy
WITH RECURSIVE partition_tree AS (
    -- Get root partitioned tables
    SELECT 
        schemaname,
        tablename,
        schemaname||'.'||tablename AS full_name,
        0 AS level,
        ARRAY[schemaname||'.'||tablename] AS path,
        'ROOT' AS partition_type
    FROM pg_tables pt
    WHERE EXISTS (
        SELECT 1 FROM pg_partitioned_table ppt 
        JOIN pg_class pc ON ppt.partrelid = pc.oid 
        JOIN pg_namespace pn ON pc.relnamespace = pn.oid 
        WHERE pn.nspname = pt.schemaname AND pc.relname = pt.tablename
    )
    
    UNION ALL
    
    -- Get child partitions recursively  
    SELECT 
        pn.nspname AS schemaname,
        pc.relname AS tablename,
        pn.nspname||'.'||pc.relname AS full_name,
        pt.level + 1,
        pt.path || (pn.nspname||'.'||pc.relname),
        CASE 
            WHEN EXISTS (SELECT 1 FROM pg_partitioned_table ppt2 WHERE ppt2.partrelid = pc.oid)
            THEN 'INTERMEDIATE'
            ELSE 'LEAF'
        END AS partition_type
    FROM partition_tree pt
    JOIN pg_inherits pi ON pi.inhparent = (
        SELECT c.oid FROM pg_class c 
        JOIN pg_namespace n ON c.relnamespace = n.oid 
        WHERE n.nspname||'.'||c.relname = pt.full_name
    )
    JOIN pg_class pc ON pi.inhrelid = pc.oid
    JOIN pg_namespace pn ON pc.relnamespace = pn.oid
    WHERE pt.level < 10  -- Prevent infinite recursion
)
SELECT 
    REPEAT('  ', level) || full_name AS partition_hierarchy,
    level,
    partition_type,
    COALESCE(pg_size_pretty(pg_total_relation_size(full_name)), 'N/A') AS total_size,
    COALESCE(pg_size_pretty(pg_relation_size(full_name)), 'N/A') AS table_size,
    COALESCE((SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname||'.'||relname = pt.full_name), 0) AS estimated_rows,
    array_length(path, 1) AS depth_in_hierarchy
FROM partition_tree pt
ORDER BY path, level;

-- Partition size distribution and balance analysis
WITH partition_sizes AS (
    SELECT 
        pi.inhparent,
        pn_parent.nspname||'.'||pc_parent.relname AS parent_table,
        pn_child.nspname||'.'||pc_child.relname AS partition_name,
        pg_total_relation_size(pc_child.oid) AS partition_size,
        pg_relation_size(pc_child.oid) AS table_size,
        COALESCE(st.n_live_tup, 0) AS row_count,
        pg_get_expr(pc_child.relpartbound, pc_child.oid) AS partition_bounds
    FROM pg_inherits pi
    JOIN pg_class pc_parent ON pi.inhparent = pc_parent.oid
    JOIN pg_namespace pn_parent ON pc_parent.relnamespace = pn_parent.oid
    JOIN pg_class pc_child ON pi.inhrelid = pc_child.oid  
    JOIN pg_namespace pn_child ON pc_child.relnamespace = pn_child.oid
    LEFT JOIN pg_stat_user_tables st ON st.schemaname = pn_child.nspname AND st.relname = pc_child.relname
    WHERE EXISTS (
        SELECT 1 FROM pg_partitioned_table ppt WHERE ppt.partrelid = pc_parent.oid
    )
),
parent_stats AS (
    SELECT 
        parent_table,
        COUNT(*) AS partition_count,
        SUM(partition_size) AS total_size,
        AVG(partition_size) AS avg_partition_size,
        STDDEV(partition_size) AS size_stddev,
        MIN(partition_size) AS min_partition_size,
        MAX(partition_size) AS max_partition_size,
        SUM(row_count) AS total_rows,
        AVG(row_count) AS avg_partition_rows
    FROM partition_sizes
    GROUP BY parent_table
)
SELECT 
    ps.parent_table,
    ps.partition_count,
    pg_size_pretty(ps.total_size) AS total_partitioned_size,
    pg_size_pretty(ps.avg_partition_size) AS avg_partition_size,
    pg_size_pretty(ps.min_partition_size) AS smallest_partition,
    pg_size_pretty(ps.max_partition_size) AS largest_partition,
    CASE 
        WHEN ps.size_stddev > ps.avg_partition_size * 0.5 
        THEN 'HIGH VARIANCE: Unbalanced partition sizes'
        WHEN ps.size_stddev > ps.avg_partition_size * 0.2 
        THEN 'MODERATE VARIANCE: Some size imbalance'
        ELSE 'LOW VARIANCE: Well-balanced partitions'
    END AS size_balance_assessment,
    ps.total_rows AS total_estimated_rows,
    ROUND(ps.avg_partition_rows::numeric, 0) AS avg_rows_per_partition,
    CASE 
        WHEN ps.partition_count > 100 
        THEN 'WARNING: Many partitions may impact query planning performance'
        WHEN ps.partition_count < 2 
        THEN 'INFO: Very few partitions - consider partition strategy'
        ELSE 'OK: Reasonable partition count'
    END AS partition_count_assessment
FROM parent_stats ps
ORDER BY ps.total_size DESC;

-- Individual partition details with performance metrics
SELECT 
    ps.parent_table,
    ps.partition_name,
    ps.partition_bounds,
    pg_size_pretty(ps.partition_size) AS total_size,
    pg_size_pretty(ps.table_size) AS table_size,
    ps.row_count AS estimated_rows,
    COALESCE(st.seq_scan, 0) AS sequential_scans,
    COALESCE(st.seq_tup_read, 0) AS seq_tuples_read,
    COALESCE(st.idx_scan, 0) AS index_scans,
    COALESCE(st.idx_tup_fetch, 0) AS index_tuples_fetched,
    CASE 
        WHEN COALESCE(st.seq_scan, 0) > COALESCE(st.idx_scan, 0) AND ps.row_count > 10000 
        THEN 'CONSIDER INDEXES: High sequential scan activity'
        WHEN ps.row_count = 0 
        THEN 'EMPTY: Consider dropping or archiving'
        WHEN ps.partition_size < 1024*1024 AND ps.row_count < 1000 
        THEN 'SMALL: Consider consolidating with adjacent partitions'
        ELSE 'OK: Normal partition usage'
    END AS partition_health,
    st.last_vacuum,
    st.last_analyze,
    CASE 
        WHEN st.last_vacuum < now() - interval '7 days' AND ps.row_count > 1000 
        THEN 'NEEDS VACUUM: No recent vacuum activity'
        WHEN st.last_analyze < now() - interval '7 days' AND ps.row_count > 1000 
        THEN 'NEEDS ANALYZE: Statistics may be stale'
        ELSE 'OK: Recent maintenance'
    END AS maintenance_status
FROM partition_sizes ps
LEFT JOIN pg_stat_user_tables st ON st.schemaname||'.'||st.relname = ps.partition_name
ORDER BY ps.parent_table, ps.partition_size DESC;

-- Partition constraint exclusion effectiveness
WITH partition_queries AS (
    -- This would ideally analyze pg_stat_statements for partition-aware queries
    -- For now, we'll analyze the partition structure for constraint exclusion potential
    SELECT 
        pn.nspname||'.'||pc.relname AS table_name,
        pg_get_expr(pc.relpartbound, pc.oid) AS partition_constraint,
        pg_total_relation_size(pc.oid) AS partition_size,
        CASE 
            WHEN pg_get_expr(pc.relpartbound, pc.oid) LIKE '%FOR VALUES FROM%' THEN 'RANGE'
            WHEN pg_get_expr(pc.relpartbound, pc.oid) LIKE '%FOR VALUES IN%' THEN 'LIST'
            WHEN pg_get_expr(pc.relpartbound, pc.oid) LIKE '%FOR VALUES WITH%' THEN 'HASH'
            ELSE 'OTHER'
        END AS partition_strategy,
        (SELECT setting FROM pg_settings WHERE name = 'constraint_exclusion') AS constraint_exclusion_setting
    FROM pg_class pc
    JOIN pg_namespace pn ON pc.relnamespace = pn.oid
    WHERE pc.relispartition = true
)
SELECT 
    'Partition Constraint Exclusion Analysis' AS analysis_type,
    COUNT(*) AS total_partitions,
    COUNT(DISTINCT partition_strategy) AS partition_strategies_used,
    constraint_exclusion_setting,
    CASE 
        WHEN constraint_exclusion_setting = 'off' 
        THEN 'CRITICAL: Enable constraint_exclusion for partition pruning'
        WHEN constraint_exclusion_setting = 'on' 
        THEN 'WARNING: constraint_exclusion=on may impact non-partitioned queries'
        WHEN constraint_exclusion_setting = 'partition' 
        THEN 'OPTIMAL: constraint_exclusion=partition is recommended'
        ELSE 'UNKNOWN: Check constraint_exclusion setting'
    END AS configuration_assessment,
    CASE 
        WHEN COUNT(*) > 50 
        THEN 'Consider partition pruning optimization for large partition count'
        ELSE 'Partition count should allow effective pruning'
    END AS pruning_efficiency_note
FROM partition_queries
GROUP BY constraint_exclusion_setting;

-- Partition maintenance recommendations and automation
WITH maintenance_analysis AS (
    SELECT 
        ps.parent_table,
        COUNT(*) AS partition_count,
        COUNT(*) FILTER (WHERE ps.row_count = 0) AS empty_partitions,
        COUNT(*) FILTER (WHERE ps.partition_size < 1024*1024) AS small_partitions,
        COUNT(*) FILTER (WHERE st.last_vacuum < now() - interval '7 days') AS partitions_needing_vacuum,
        COUNT(*) FILTER (WHERE st.last_analyze < now() - interval '7 days') AS partitions_needing_analyze,
        MAX(ps.partition_size) AS largest_partition_size,
        MIN(ps.partition_size) AS smallest_partition_size
    FROM partition_sizes ps
    LEFT JOIN pg_stat_user_tables st ON st.schemaname||'.'||st.relname = ps.partition_name
    GROUP BY ps.parent_table
)
SELECT 
    parent_table,
    partition_count,
    empty_partitions,
    small_partitions,
    partitions_needing_vacuum,
    partitions_needing_analyze,
    pg_size_pretty(largest_partition_size) AS largest_partition,
    pg_size_pretty(smallest_partition_size) AS smallest_partition,
    CASE 
        WHEN empty_partitions > 5 
        THEN 'Consider dropping empty partitions: DROP TABLE partition_name;'
        WHEN small_partitions > partition_count * 0.3 
        THEN 'Many small partitions - consider different partitioning strategy'
        WHEN partitions_needing_vacuum > partition_count * 0.5 
        THEN 'Schedule regular VACUUM maintenance across partitions'
        WHEN partitions_needing_analyze > partition_count * 0.5 
        THEN 'Schedule regular ANALYZE maintenance across partitions'
        ELSE 'Partition maintenance appears current'
    END AS primary_recommendation,
    CASE 
        WHEN partition_count > 12 
        THEN format('-- Automated monthly cleanup example:
SELECT ''DROP TABLE '' || schemaname || ''.'' || tablename || '';''
FROM pg_tables 
WHERE tablename LIKE ''%s_%%'' 
AND (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname = pg_tables.schemaname AND relname = pg_tables.tablename) = 0;', 
        replace(parent_table, '.', '_'))
        ELSE '-- Consider partition automation for tables with many partitions'
    END AS automation_suggestion
FROM maintenance_analysis
ORDER BY partition_count DESC;

-- Partition performance impact analysis
SELECT 
    'Partition Performance Summary' AS metric_type,
    (SELECT COUNT(DISTINCT inhparent) FROM pg_inherits pi JOIN pg_class pc ON pi.inhparent = pc.oid WHERE pc.relkind = 'p') AS partitioned_tables,
    (SELECT COUNT(*) FROM pg_class WHERE relispartition = true) AS total_partitions,
    (SELECT pg_size_pretty(SUM(pg_total_relation_size(oid))) FROM pg_class WHERE relispartition = true) AS total_partitioned_data,
    CASE 
        WHEN (SELECT COUNT(*) FROM pg_class WHERE relispartition = true) > 1000 
        THEN 'CAUTION: Very high partition count may impact metadata operations'
        WHEN (SELECT COUNT(*) FROM pg_class WHERE relispartition = true) > 500 
        THEN 'MONITOR: High partition count - watch query planning performance'
        ELSE 'OK: Manageable partition count'
    END AS performance_impact,
    'Consider pg_partman extension for automated partition management' AS automation_recommendation;

-- Suggested partition management queries
SELECT 
    'Partition Management Commands' AS command_type,
    'VACUUM (ANALYZE) partition_name;' AS vacuum_command_example,
    'SELECT pg_size_pretty(pg_total_relation_size(''partition_name''));' AS size_check_example,
    'DROP TABLE IF EXISTS old_partition_name;' AS cleanup_example,
    'CREATE TABLE new_partition PARTITION OF parent_table FOR VALUES FROM (''2024-01-01'') TO (''2024-02-01'');' AS new_partition_example,
    'ALTER TABLE parent_table DETACH PARTITION old_partition;' AS detach_example,
    '-- Use pg_partman for automated time-based partition management' AS automation_note;