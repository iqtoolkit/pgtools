/*
 * Script: txid.sql
 * Purpose: Monitor transaction ID usage and wraparound risk
 *
 * Usage:
 *   psql -d database_name -f monitoring/txid.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: Any user (uses public views)
 *
 * Output:
 *   - Current transaction ID
 *   - Database age (in transactions)
 *   - Percent to wraparound
 *   - Tables with oldest frozen XID
 *
 * Notes:
 *   - CRITICAL: Monitor regularly to prevent wraparound shutdown
 *   - Age > 1 billion transactions is concerning
 *   - Age > 2 billion forces database shutdown
 *   - High age requires aggressive VACUUM
 *   - autovacuum_freeze_max_age controls automatic freezing
 *   - Consider manual VACUUM FREEZE for high-age tables
 */

-- Current transaction ID and database age
SELECT
    datname AS database_name,
    age(datfrozenxid) AS age_in_transactions,
    ROUND(100.0 * age(datfrozenxid) / 2000000000, 2) AS percent_towards_wraparound,
    datfrozenxid,
    pg_size_pretty(pg_database_size(datname)) AS database_size
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Tables with oldest frozen XID (candidates for VACUUM FREEZE)
SELECT
    s.schemaname || '.' || s.relname AS table_name,
    age(c.relfrozenxid) AS age_in_transactions,
    ROUND(100.0 * age(c.relfrozenxid) / 2000000000, 2) AS percent_towards_wraparound,
    pg_size_pretty(pg_total_relation_size(s.schemaname||'.'||s.relname)) AS total_size,
    s.last_vacuum,
    s.last_autovacuum
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;