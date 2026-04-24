/*
 * Script: sql/admin/ownership.sql
 *
 * Purpose: Displays ownership information for tables, views, and materialized views.
 *
 * Description:
 * This query lists all user-defined tables, views, materialized views, and
 * foreign tables, along with their respective owners. It's a key diagnostic
 * for "permission denied" errors or when auditing for orphaned objects after
 * role changes.
 *
 * Red Flags:
 * - Objects owned by roles that no longer exist (owner will show as an OID).
 * - Critical application tables owned by a superuser or an unexpected role.
 * - Inconsistent ownership patterns across schemas or applications.
 *
 * Interpretation:
 * - `schema_name`: The schema containing the object.
 * - `object_name`: The name of the table, view, etc.
 * - `object_type`: Indicates if it's a TABLE, VIEW, MATERIALIZED VIEW, etc.
 * - `owner`: The role that owns the object.
 *
 * Safety:
 * This script is read-only. It queries standard `pg_catalog` views (`pg_class`,
 * `pg_namespace`) which are designed for efficient diagnostic use. The
 * `statement_timeout` set by `pgtools.sh` provides a safety guarantee.
 */
SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    pg_catalog.pg_get_userbyid(c.relowner) AS owner,
    CASE c.relkind
        WHEN 'r' THEN 'TABLE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE'
        WHEN 'p' THEN 'PARTITIONED TABLE'
    END AS object_type
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','v','m','f','p')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname !~ '^pg_toast'
ORDER BY n.nspname, c.relname;