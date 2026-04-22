
-- PostgreSQL Troubleshooting Query Pack

-- 1. Disk Usage by Tables and Index
SELECT
  schemaname,
  relname AS table_name,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_relation_size(relid)) AS table_size,
  pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) AS index_and_toast_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 10;

-- 2. Replication lag (on replica)
select now()-pg_last_xact_replay_timestamp() as replication_lag;


-- 3.Replication Slots and Their Status
SELECT slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;


-- 4. Check for Bloat Estimation on Tables
WITH bloat_info AS (
  SELECT
    schemaname,
    tablename,
    pg_relation_size(schemaname || '.' || tablename) AS table_size,
    pg_total_relation_size(schemaname || '.' || tablename) AS total_size
  FROM pg_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
)
SELECT schemaname, tablename,
       pg_size_pretty(table_size) AS table_size,
       pg_size_pretty(total_size) AS total_size,
       pg_size_pretty(total_size - table_size) AS bloat_estimate
FROM bloat_info
ORDER BY total_size - table_size DESC
LIMIT 10;


-- 5. Check for Disk Full or Near Full Tablespaces
SELECT spcname,
       pg_size_pretty(pg_tablespace_size(spcname)) AS size,
       pg_tablespace_location(oid) AS location
FROM pg_tablespace
ORDER BY pg_tablespace_size(spcname) DESC;


-- 6. PostgreSQL Configuration Parameters
SELECT name, setting, unit, category, short_desc
FROM pg_settings
ORDER BY category, name;


-- 7. Check for Deadlocks in the Logs
SELECT *
FROM pg_catalog.pg_stat_activity
WHERE query ~* 'deadlock';


-- 8. Check Connection Saturation
SELECT COUNT(*) AS total_connections,
       MAX(setting::int) AS max_connections
FROM pg_stat_activity, pg_settings
WHERE name = 'max_connections';


-- 9. Check for Locks Held Too Long
SELECT a.pid, mode, relation::regclass, granted, age(clock_timestamp(), query_start) AS duration, query
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE granted
  AND age(clock_timestamp(), query_start) > interval '5 minutes'
ORDER BY duration DESC;


-- 10. Current connections per database
SELECT datname, COUNT(*) AS connections
FROM pg_stat_activity
GROUP BY datname
ORDER BY connections DESC;


-- 11. Check remaining connections vs limit
SELECT max_conn, used_conn, max_conn - used_conn AS available
FROM (
  SELECT COUNT(*) AS used_conn FROM pg_stat_activity
) AS used,
(SELECT setting::int AS max_conn FROM pg_settings WHERE name = 'max_connections') AS max;


-- 12. Most I/O-heavy queries (pg_stat_statements must be enabled)
SELECT query, shared_blks_read, local_blks_read, temp_blks_read
FROM pg_stat_statements
ORDER BY shared_blks_read DESC
LIMIT 10;


-- 13. Most CPU-intensive queries
SELECT query, total_exec_time, calls, mean_exec_time
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;


-- 14. Tables due for vacuum/freeze
SELECT oid::regclass AS table_name,
       /* number of transactions over "vacuum_freeze_table_age" */
       age(c.relfrozenxid)
       - current_setting('vacuum_freeze_table_age')::integer AS overdue_by
FROM pg_class AS c 
WHERE c.relkind IN ('r','m','t')  /* tables, matviews, TOAST tables */
  AND age(c.relfrozenxid)
      > least(
           /* it is ok to go a bit beyond the limit where VACUUM is triggered */
           current_setting('autovacuum_freeze_max_age')::integer + 50000000,
           /* but at this point, we'll get warnings */
           2^31 - 40000000
        )
ORDER BY /* worst first */ age(c.relfrozenxid) DESC;


-- 15. Autovacuum activity
SELECT psa.pid, relname, phase, wait_event_type, wait_event, query
FROM pg_stat_progress_vacuum pspv
  JOIN pg_stat_activity psa on psa.pid=pspv.pid
JOIN pg_class pc ON pspv.relid = pc.oid;


-- 16. All current locks with wait status
SELECT pid, mode, granted, relation::regclass, query
FROM pg_locks
JOIN pg_stat_activity USING (pid)
WHERE relation IS NOT NULL;

-- 17. Duplicate indexes
SELECT indrelid::regclass AS table,
       array_agg(indexrelid::regclass) AS dup_indexes
FROM pg_index
GROUP BY indrelid, indkey
HAVING COUNT(*) > 1;


-- 18. Indexes with low usage and high size
SELECT relname AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan < 50
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 10;


-- 19. Replication status (on primary)
SELECT pid, state, client_addr, sync_state, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;


-- 20. WAL activity
SELECT slot_name, database, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;


-- 21. Top relations by total size
SELECT relname AS object,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 10;


-- 22. Buffer cache hit ratio (should be >99%)
SELECT sum(blks_hit) / (sum(blks_hit) + sum(blks_read)) AS hit_ratio
FROM pg_stat_database;


-- 23. Show non-default settings
SELECT name, setting, unit, source
FROM pg_settings
WHERE source NOT IN ('default', 'override');


-- 24. Autovacuum tuning settings
SELECT name, setting
FROM pg_settings
WHERE name ILIKE 'autovacuum%';

-- 25. Quick Health Check (Wraparound Risk)
SELECT datname, age(datfrozenxid) AS xid_age, pg_size_pretty(pg_database_size(datname)) AS db_size
FROM pg_database
ORDER BY age(datfrozenxid) DESC;
