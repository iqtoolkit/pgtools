/*
 * Script: sql/diagnostics/disk-usage.sql
 *
 * Purpose: Shows the disk usage for the largest tables and their indexes.
 *
 * Description:
 * This query lists the top 50 tables by total disk space consumption. It breaks
 * down the size into the main table data, indexes, and TOAST data, providing a
 * clear picture of where disk space is being used.
 *
 * Red Flags:
 * - An unexpectedly large table at the top of the list.
 * - `index_size` is significantly larger than `table_size`: May indicate over-indexing or bloated indexes.
 * - `toast_size` is very large: Suggests large, out-of-line data storage which can impact performance.
 *
 * Interpretation:
 * - `total_size`: The complete on-disk size of the relation.
 * - `table_size`: The size of the main data heap for the table.
 * - `index_size`: The combined size of all indexes on the table.
 * - `toast_size`: The size of the associated TOAST table for out-of-line data.
 *
 * Safety:
 * This script is read-only. It queries `pg_class` and uses standard PostgreSQL
 * size-reporting functions. It is generally fast but can be slower on databases
 * with tens of thousands of tables. The `statement_timeout` provides a safety net.
 */
SELECT
    c.relname AS table_name,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    pg_size_pretty(pg_relation_size(c.oid)) AS table_size,
    pg_size_pretty(pg_indexes_size(c.oid)) AS index_size,
    pg_size_pretty(pg_total_relation_size(c.reltoastrelid)) AS toast_size
FROM pg_class c
LEFT JOIN pg_namespace n ON (n.oid = c.relnamespace)
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 50;