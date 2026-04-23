/*
 * Script: sql/admin/permissions.sql
 *
 * Purpose: Provides a high-level audit of roles, their privileges, and memberships.
 *
 * Description:
 * This query gives a quick overview of all non-system roles in the database.
 * It's the first place to look when a customer reports a "permission denied"
 * error or when auditing for over-privileged accounts.
 *
 * Red Flags:
 * - `is_superuser = 't'`: Ensure only expected administrative roles have superuser status.
 * - `can_login = 't'` with `password_status = 'NO PASSWORD SET'`: A significant security risk.
 * - `can_create_roles = 't'`: This privilege can be used for privilege escalation.
 * - Unexpected roles in `member_of_roles`: A role may be inheriting dangerous privileges.
 *
 * Interpretation:
 * - `rolname`: The name of the role being audited.
 * - `is_superuser`, `can_create_roles`, `can_login`: Critical boolean flags indicating a role's power.
 * - `member_of_roles`: Shows which other roles this role inherits privileges from.
 *
 * Safety:
 * This script is read-only and queries standard `pg_catalog` views (`pg_roles`,
 * `pg_auth_members`) which are designed for fast diagnostic access. The
 * `statement_timeout` set by `pgtools.sh` provides a safety guarantee.
 */
SELECT
    r.rolname,
    r.rolsuper AS is_superuser,
    r.rolcreaterole AS can_create_roles,
    r.rolcreatedb AS can_create_databases,
    r.rolcanlogin AS can_login,
    r.rolreplication AS is_replication_role,
    CASE
        WHEN r.rolpassword IS NOT NULL THEN 'PASSWORD SET'
        ELSE 'NO PASSWORD SET'
    END AS password_status,
    ARRAY(
        SELECT g.rolname
        FROM pg_auth_members am
        JOIN pg_roles g ON am.roleid = g.oid
        WHERE am.member = r.oid
    ) AS member_of_roles
FROM pg_roles r
WHERE r.rolname NOT LIKE 'pg_%' -- Exclude system roles
ORDER BY r.rolsuper DESC, r.rolcreaterole DESC, r.rolcanlogin DESC, r.rolname;
