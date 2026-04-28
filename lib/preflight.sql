/*
 * lib/preflight.sql
 * Unified preflight checker for pgtools scripts.
 *
 * Creates pg_temp.pgtools_check() — a session-scoped function that is
 * automatically dropped when the connection closes. Nothing is left in the
 * database after the session ends.
 *
 * Usage — add these two lines immediately after the header comment in any
 * pgtools script (adjust path depth as needed):
 *
 *   \ir ../lib/preflight.sql
 *   DO $preflight$ BEGIN PERFORM pg_temp.pgtools_check('pg_monitor', NULL); END $preflight$;
 *
 * Arguments (both optional, pass NULL to skip that check):
 *   required_role      — role the current user must be a member of
 *                        (superusers always pass this check)
 *   required_extension — extension that must already be installed
 *
 * On failure the function raises EXCEPTION, which (with ON_ERROR_STOP set
 * below) immediately terminates the script with a descriptive message.
 */

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION pg_temp.pgtools_check(
    required_role      text DEFAULT NULL,
    required_extension text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    is_superuser bool;
BEGIN
    SELECT rolsuper INTO is_superuser
    FROM pg_roles
    WHERE rolname = current_user;

    -- Role check: superusers bypass all role requirements
    IF required_role IS NOT NULL AND NOT COALESCE(is_superuser, false) THEN
        IF NOT pg_has_role(current_user, required_role, 'member') THEN
            RAISE EXCEPTION
                E'PREFLIGHT FAILED: role "%" is required to run this script.\n'
                'Current user "%" does not have it.\n'
                'Grant with: GRANT % TO %;',
                required_role, current_user, required_role, current_user;
        END IF;
    END IF;

    -- Extension check
    IF required_extension IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = required_extension) THEN
            RAISE EXCEPTION
                E'PREFLIGHT FAILED: extension "%" is not installed.\n'
                'Install with: CREATE EXTENSION %;',
                required_extension, required_extension;
        END IF;
    END IF;
END;
$$;
