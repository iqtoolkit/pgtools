/*
 * Script: permission_audit.sql
 * Purpose: Comprehensive security audit of PostgreSQL permissions, roles, and access patterns
 * 
 * Usage:
 *   psql -d database_name -f security/permission_audit.sql
 *
 * Requirements:
 *   - PostgreSQL 15+
 *   - Privileges: Superuser or security officer role for complete audit
 *
 * Output:
 *   - Role hierarchy and membership analysis
 *   - Permission grants and potential security issues
 *   - Database and schema-level access review
 *   - Table and column-level security audit
 *   - Authentication and connection security
 *   - Privilege escalation risks
 *
 * Notes:
 *   - Critical for security compliance and auditing
 *   - Identifies overprivileged accounts and roles
 *   - Detects potential security misconfigurations
 *   - Should be run regularly for security monitoring
 *   - Results should be reviewed by security team
 */

-- Database-level role and permission overview
SELECT 
    r.rolname AS role_name,
    r.rolsuper AS is_superuser,
    r.rolinherit AS inherits_privileges,
    r.rolcreaterole AS can_create_roles,
    r.rolcreatedb AS can_create_databases,
    r.rolcanlogin AS can_login,
    r.rolreplication AS replication_privilege,
    r.rolbypassrls AS bypasses_rls,
    r.rolconnlimit AS connection_limit,
    CASE 
        WHEN r.rolpassword IS NULL THEN 'NO PASSWORD SET'
        ELSE 'PASSWORD SET'
    END AS password_status,
    r.rolvaliduntil AS password_expiry,
    CASE 
        WHEN r.rolsuper THEN 'CRITICAL: Superuser - unlimited access'
        WHEN r.rolcreaterole THEN 'HIGH: Can create roles - potential privilege escalation'
        WHEN r.rolcreatedb THEN 'MEDIUM: Can create databases'
        WHEN r.rolcanlogin AND r.rolpassword IS NULL THEN 'HIGH: Login without password'
        WHEN r.rolcanlogin THEN 'NORMAL: Standard login role'
        ELSE 'LOW: Non-login role'
    END AS security_risk_level,
    ARRAY(
        SELECT m.rolname 
        FROM pg_auth_members am 
        JOIN pg_roles m ON am.member = m.oid 
        WHERE am.roleid = r.oid
    ) AS role_members,
    ARRAY(
        SELECT g.rolname 
        FROM pg_auth_members am 
        JOIN pg_roles g ON am.roleid = g.oid 
        WHERE am.member = r.oid
    ) AS member_of_roles
FROM pg_roles r
WHERE r.rolname NOT LIKE 'pg_%'  -- Exclude system roles
ORDER BY 
    r.rolsuper DESC, 
    r.rolcreaterole DESC, 
    r.rolcanlogin DESC, 
    r.rolname;

-- Superuser and high-privilege role analysis
SELECT 
    'High Privilege Role Analysis' AS audit_section,
    COUNT(*) FILTER (WHERE rolsuper) AS superuser_count,
    COUNT(*) FILTER (WHERE rolcreaterole) AS role_creators_count,
    COUNT(*) FILTER (WHERE rolcreatedb) AS db_creators_count,
    COUNT(*) FILTER (WHERE rolcanlogin AND rolpassword IS NULL) AS passwordless_login_roles,
    COUNT(*) FILTER (WHERE rolbypassrls) AS rls_bypass_roles,
    CASE 
        WHEN COUNT(*) FILTER (WHERE rolsuper) > 2 
        THEN 'WARNING: Multiple superuser accounts detected'
        WHEN COUNT(*) FILTER (WHERE rolcanlogin AND rolpassword IS NULL) > 0 
        THEN 'CRITICAL: Passwordless login roles exist'
        WHEN COUNT(*) FILTER (WHERE rolcreaterole) > 3 
        THEN 'NOTICE: Many role creation privileges granted'
        ELSE 'OK: Reasonable high-privilege role distribution'
    END AS security_assessment,
    string_agg(
        CASE WHEN rolsuper THEN rolname END, ', '
    ) AS superuser_roles,
    string_agg(
        CASE WHEN rolcanlogin AND rolpassword IS NULL THEN rolname END, ', '
    ) AS passwordless_roles
FROM pg_roles
WHERE rolname NOT LIKE 'pg_%';

-- Database-level access permissions audit
SELECT 
    d.datname AS database_name,
    r.rolname AS role_name,
    CASE 
        WHEN d.datdba = r.oid THEN 'OWNER'
        WHEN has_database_privilege(r.rolname, d.datname, 'CONNECT') THEN 'CONNECT'
        ELSE 'NO ACCESS'
    END AS database_privilege,
    CASE 
        WHEN has_database_privilege(r.rolname, d.datname, 'CREATE') THEN 'YES' 
        ELSE 'NO' 
    END AS can_create_schemas,
    CASE 
        WHEN has_database_privilege(r.rolname, d.datname, 'TEMP') THEN 'YES' 
        ELSE 'NO' 
    END AS can_create_temp_tables,
    pg_size_pretty(pg_database_size(d.datname)) AS database_size,
    CASE 
        WHEN d.datdba = r.oid THEN 'Database owner has full control'
        WHEN r.rolsuper THEN 'Superuser has unlimited access'
        WHEN has_database_privilege(r.rolname, d.datname, 'CREATE') THEN 'Can modify database structure'
        WHEN has_database_privilege(r.rolname, d.datname, 'CONNECT') THEN 'Standard database access'
        ELSE 'No database access'
    END AS access_description
FROM pg_database d
CROSS JOIN pg_roles r
WHERE d.datname NOT IN ('template0', 'template1')
    AND r.rolname NOT LIKE 'pg_%'
    AND r.rolcanlogin  -- Only check login roles
    AND (
        d.datdba = r.oid 
        OR has_database_privilege(r.rolname, d.datname, 'CONNECT')
        OR r.rolsuper
    )
ORDER BY d.datname, r.rolname;

-- Schema-level permissions and public schema security
SELECT 
    n.nspname AS schema_name,
    r.rolname AS role_name,
    n.nspowner = r.oid AS is_owner,
    has_schema_privilege(r.rolname, n.nspname, 'USAGE') AS has_usage,
    has_schema_privilege(r.rolname, n.nspname, 'CREATE') AS has_create,
    CASE 
        WHEN n.nspname = 'public' AND has_schema_privilege(r.rolname, n.nspname, 'CREATE') 
        THEN 'WARNING: Public schema CREATE privilege'
        WHEN n.nspowner = r.oid 
        THEN 'Schema owner'
        WHEN has_schema_privilege(r.rolname, n.nspname, 'CREATE') 
        THEN 'Can create objects'
        WHEN has_schema_privilege(r.rolname, n.nspname, 'USAGE') 
        THEN 'Can access objects'
        ELSE 'No schema access'
    END AS privilege_summary,
    (SELECT COUNT(*) FROM pg_class c WHERE c.relnamespace = n.oid AND c.relkind = 'r') AS table_count,
    (SELECT COUNT(*) FROM pg_proc p WHERE p.pronamespace = n.oid) AS function_count
FROM pg_namespace n
CROSS JOIN pg_roles r
WHERE n.nspname NOT LIKE 'pg_%' 
    AND n.nspname != 'information_schema'
    AND r.rolname NOT LIKE 'pg_%'
    AND r.rolcanlogin
    AND (
        n.nspowner = r.oid 
        OR has_schema_privilege(r.rolname, n.nspname, 'USAGE')
        OR has_schema_privilege(r.rolname, n.nspname, 'CREATE')
        OR r.rolsuper
    )
ORDER BY n.nspname, r.rolname;

-- Table-level permissions audit with sensitive data detection
SELECT 
    schemaname || '.' || tablename AS table_name,
    tableowner AS table_owner,
    r.rolname AS role_name,
    CASE 
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'SELECT') THEN 'SELECT ' ELSE ''
    END ||
    CASE 
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'INSERT') THEN 'INSERT ' ELSE ''
    END ||
    CASE 
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'UPDATE') THEN 'UPDATE ' ELSE ''
    END ||
    CASE 
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'DELETE') THEN 'DELETE ' ELSE ''
    END ||
    CASE 
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'TRUNCATE') THEN 'TRUNCATE ' ELSE ''
    END AS table_privileges,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS table_size,
    (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname = t.schemaname AND relname = t.tablename) AS estimated_rows,
    CASE 
        WHEN t.tablename ~* '(user|customer|person|employee|patient|account|payment|credit|password|ssn|tax)' 
        THEN 'SENSITIVE: Potentially contains PII/sensitive data'
        WHEN (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname = t.schemaname AND relname = t.tablename) > 1000000 
        THEN 'LARGE: High-volume table'
        ELSE 'STANDARD: Regular table'
    END AS data_sensitivity,
    CASE 
        WHEN tableowner = r.rolname THEN 'Table owner has full control'
        WHEN r.rolsuper THEN 'Superuser has unlimited access'
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'DELETE') 
            OR has_table_privilege(r.rolname, schemaname||'.'||tablename, 'TRUNCATE')
        THEN 'HIGH RISK: Can delete data'
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'UPDATE') 
        THEN 'MEDIUM RISK: Can modify data'
        WHEN has_table_privilege(r.rolname, schemaname||'.'||tablename, 'SELECT') 
        THEN 'LOW RISK: Read-only access'
        ELSE 'NO ACCESS'
    END AS risk_assessment
FROM pg_tables t
CROSS JOIN pg_roles r
WHERE t.schemaname NOT IN ('pg_catalog', 'information_schema')
    AND r.rolname NOT LIKE 'pg_%'
    AND r.rolcanlogin
    AND (
        t.tableowner = r.rolname
        OR has_table_privilege(r.rolname, t.schemaname||'.'||t.tablename, 'SELECT')
        OR has_table_privilege(r.rolname, t.schemaname||'.'||t.tablename, 'INSERT')
        OR has_table_privilege(r.rolname, t.schemaname||'.'||t.tablename, 'UPDATE')
        OR has_table_privilege(r.rolname, t.schemaname||'.'||t.tablename, 'DELETE')
        OR r.rolsuper
    )
ORDER BY 
    CASE WHEN t.tablename ~* '(user|customer|person|employee|patient|account|payment|credit|password|ssn|tax)' THEN 1 ELSE 2 END,
    pg_total_relation_size(t.schemaname||'.'||t.tablename) DESC;

-- Function and procedure security audit
SELECT 
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_userbyid(p.proowner) AS function_owner,
    CASE p.prosecdef 
        WHEN true THEN 'SECURITY DEFINER' 
        ELSE 'SECURITY INVOKER' 
    END AS security_mode,
    CASE p.proacl IS NULL
        WHEN true THEN 'PUBLIC EXECUTE'
        ELSE 'RESTRICTED ACCESS'
    END AS access_control,
    pg_get_function_arguments(p.oid) AS function_arguments,
    pg_get_function_result(p.oid) AS return_type,
    CASE 
        WHEN p.prosecdef AND p.proacl IS NULL 
        THEN 'CRITICAL: SECURITY DEFINER with PUBLIC access'
        WHEN p.prosecdef 
        THEN 'HIGH: SECURITY DEFINER function - review carefully'
        WHEN p.proname ~* '(admin|super|root|password|auth|login|create|drop|alter|delete|grant|revoke)'
        THEN 'MEDIUM: Function name suggests administrative purpose'
        ELSE 'LOW: Standard function'
    END AS security_risk,
    CASE 
        WHEN p.prosecdef AND p.proacl IS NULL 
        THEN 'Review function code and restrict access with REVOKE/GRANT'
        WHEN p.prosecdef 
        THEN 'Ensure function performs appropriate security checks'
        ELSE 'Standard function security practices apply'
    END AS security_recommendation
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 
    CASE WHEN p.prosecdef AND p.proacl IS NULL THEN 1 
         WHEN p.prosecdef THEN 2 
         ELSE 3 END,
    n.nspname, p.proname;

-- Row Level Security (RLS) audit
SELECT 
    schemaname || '.' || tablename AS table_name,
    rowsecurity AS rls_enabled,
    CASE 
        WHEN rowsecurity THEN 'ENABLED'
        ELSE 'DISABLED'
    END AS rls_status,
    (SELECT COUNT(*) FROM pg_policy WHERE polrelid = (schemaname||'.'||tablename)::regclass) AS policy_count,
    CASE 
        WHEN rowsecurity AND (SELECT COUNT(*) FROM pg_policy WHERE polrelid = (schemaname||'.'||tablename)::regclass) = 0
        THEN 'WARNING: RLS enabled but no policies defined'
        WHEN NOT rowsecurity AND tablename ~* '(user|customer|tenant|account|private)'
        THEN 'CONSIDER: Table may benefit from RLS'
        WHEN rowsecurity 
        THEN 'OK: RLS properly configured'
        ELSE 'STANDARD: No RLS required'
    END AS rls_assessment,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS table_size,
    (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname = t.schemaname AND relname = t.tablename) AS estimated_rows
FROM pg_tables t
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 
    rowsecurity DESC,
    CASE WHEN tablename ~* '(user|customer|tenant|account|private)' THEN 1 ELSE 2 END,
    pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Connection and authentication security summary
SELECT 
    'Authentication Security Summary' AS security_aspect,
    (SELECT COUNT(*) FROM pg_roles WHERE rolcanlogin) AS total_login_roles,
    (SELECT COUNT(*) FROM pg_roles WHERE rolcanlogin AND rolpassword IS NULL) AS passwordless_roles,
    (SELECT COUNT(*) FROM pg_roles WHERE rolcanlogin AND rolvaliduntil < now()) AS expired_password_roles,
    (SELECT COUNT(*) FROM pg_roles WHERE rolsuper) AS superuser_roles,
    current_setting('password_encryption') AS password_encryption_method,
    current_setting('ssl') AS ssl_enabled,
    CASE 
        WHEN (SELECT COUNT(*) FROM pg_roles WHERE rolcanlogin AND rolpassword IS NULL) > 0 
        THEN 'CRITICAL: Passwordless accounts exist'
        WHEN current_setting('ssl') != 'on' 
        THEN 'WARNING: SSL not enforced'
        WHEN current_setting('password_encryption') = 'md5' 
        THEN 'NOTICE: Consider upgrading to scram-sha-256'
        ELSE 'OK: Basic authentication security configured'
    END AS security_status,
    CASE 
        WHEN (SELECT COUNT(*) FROM pg_roles WHERE rolcanlogin AND rolpassword IS NULL) > 0 
        THEN 'Set passwords for all login roles: ALTER ROLE username PASSWORD ''secure_password'';'
        WHEN current_setting('ssl') != 'on' 
        THEN 'Enable SSL in postgresql.conf: ssl = on'
        WHEN current_setting('password_encryption') = 'md5' 
        THEN 'Upgrade password encryption: password_encryption = scram-sha-256'
        ELSE 'Review pg_hba.conf for connection restrictions'
    END AS primary_recommendation;

-- Overall security compliance summary
WITH security_metrics AS (
    SELECT 
        (SELECT COUNT(*) FROM pg_roles WHERE rolsuper) AS superuser_count,
        (SELECT COUNT(*) FROM pg_roles WHERE rolcanlogin AND rolpassword IS NULL) AS passwordless_count,
        (SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public') AS public_schema_tables,
        (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid 
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') 
         AND p.prosecdef AND p.proacl IS NULL) AS risky_functions,
        (SELECT COUNT(*) FROM pg_tables WHERE rowsecurity = false 
         AND tablename ~* '(user|customer|tenant|account|private)') AS tables_needing_rls
)
SELECT 
    'Security Compliance Dashboard' AS assessment_type,
    superuser_count || ' superuser accounts' AS superuser_status,
    passwordless_count || ' passwordless login roles' AS authentication_status,
    public_schema_tables || ' tables in public schema' AS schema_security_status,
    risky_functions || ' high-risk SECURITY DEFINER functions' AS function_security_status,
    tables_needing_rls || ' sensitive tables without RLS' AS rls_status,
    CASE 
        WHEN passwordless_count > 0 OR risky_functions > 0 
        THEN 'CRITICAL: Immediate security attention required'
        WHEN superuser_count > 3 OR public_schema_tables > 10 OR tables_needing_rls > 5 
        THEN 'HIGH: Security hardening recommended'
        WHEN superuser_count > 1 OR public_schema_tables > 0 
        THEN 'MEDIUM: Security improvements suggested'
        ELSE 'GOOD: Basic security practices followed'
    END AS overall_security_grade,
    'Review and implement security recommendations above' AS next_steps
FROM security_metrics;
