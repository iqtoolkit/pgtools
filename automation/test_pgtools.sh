#!/bin/bash
#
# Script: test_pgtools.sh
# Purpose: Test runner and validation for pgtools scripts
# Usage: ./automation/test_pgtools.sh [OPTIONS]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGTOOLS_ROOT="$(dirname "$SCRIPT_DIR")"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "[$(date '+%H:%M:%S')] ${BLUE}INFO${NC} $*"; }
warn() { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}WARN${NC} $*"; }
error() { echo -e "[$(date '+%H:%M:%S')] ${RED}ERROR${NC} $*"; }
success() { echo -e "[$(date '+%H:%M:%S')] ${GREEN}SUCCESS${NC} $*"; }

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Default values
RUN_FAST="false"
RUN_FULL="false" 
TEST_PATTERN="*"
VERBOSE="false"

usage() {
    cat << EOF
PostgreSQL Tools Testing Framework

Usage: $0 [OPTIONS]

OPTIONS:
    --fast              Run fast tests only (connection, syntax)
    --full              Run full test suite including database operations
    -p, --pattern GLOB  Test pattern to run (default: all tests)
    -v, --verbose       Verbose test output
    -h, --help          Show this help

TEST CATEGORIES:
    connection          Database connection tests
    syntax              SQL syntax validation
    permissions         Permission requirement checks
    automation          Automation script tests
    integration         End-to-end integration tests

EXAMPLES:
    $0 --fast                       # Quick validation tests
    $0 --full                       # Complete test suite
    $0 --pattern "connection*"      # Only connection tests
    $0 --verbose --full             # Full tests with verbose output

CONFIGURATION:
    Database connection settings are loaded from:
    - $SCRIPT_DIR/pgtools.conf
    - Environment variables (PGHOST, PGPORT, PGDATABASE, PGUSER)

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --fast)
            RUN_FAST="true"
            shift
            ;;
        --full)
            RUN_FULL="true"
            shift
            ;;
        -p|--pattern)
            TEST_PATTERN="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# If neither fast nor full specified, default to fast
if [[ "$RUN_FAST" == "false" && "$RUN_FULL" == "false" ]]; then
    RUN_FAST="true"
fi

# Load configuration
CONFIG_FILE="$SCRIPT_DIR/pgtools.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1091
    # shellcheck source=pgtools.conf
    source "$CONFIG_FILE"
fi

# Environment-driven skip guards (populated in main() before syntax tests run).
# Scripts that require superuser or specific extensions are skipped when the
# CI/test database cannot support them, rather than reporting a false failure.
SKIP_SUPERUSER_SCRIPTS="false"
SKIP_EXTENSION_SCRIPTS="false"
HAS_PG_STAT_STATEMENTS="false"
HAS_PG_BUFFERCACHE="false"

detect_environment_capabilities() {
    # Superuser gate — permission_audit.sql and switch_pg_wal_file.sql need it.
    local is_super
    if is_super="$(psql -tA -c "SELECT current_setting('is_superuser', true);" 2>/dev/null)"; then
        if [[ "$(echo "$is_super" | tr -d '[:space:]')" != "on" ]]; then
            SKIP_SUPERUSER_SCRIPTS="true"
        fi
    else
        SKIP_SUPERUSER_SCRIPTS="true"
    fi

    # Detect extension availability once so per-file gating is deterministic.
    if psql -tA -c "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements' LIMIT 1;" 2>/dev/null | grep -q 1; then
        HAS_PG_STAT_STATEMENTS="true"
    fi

    if psql -tA -c "SELECT 1 FROM pg_extension WHERE extname = 'pg_buffercache' LIMIT 1;" 2>/dev/null | grep -q 1; then
        HAS_PG_BUFFERCACHE="true"
    fi

    if [[ "$HAS_PG_STAT_STATEMENTS" == "false" && "$HAS_PG_BUFFERCACHE" == "false" ]]; then
        SKIP_EXTENSION_SCRIPTS="true"
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        log "Environment detection: SKIP_SUPERUSER_SCRIPTS=$SKIP_SUPERUSER_SCRIPTS SKIP_EXTENSION_SCRIPTS=$SKIP_EXTENSION_SCRIPTS HAS_PG_STAT_STATEMENTS=$HAS_PG_STAT_STATEMENTS HAS_PG_BUFFERCACHE=$HAS_PG_BUFFERCACHE"
    fi
}

# Test execution framework
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    if [[ "$TEST_PATTERN" != "*" ]] && [[ ! "$test_name" == "$TEST_PATTERN" ]]; then
        return 0
    fi
    
    TESTS_RUN=$((TESTS_RUN + 1))

    if [[ "$VERBOSE" == "true" ]]; then
        log "Running test: $test_name"
    fi

    if $test_function; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        success "✓ $test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        error "✗ $test_name"
    fi
}

# Connection tests
test_database_connection() {
    psql -c "SELECT version();" > /dev/null 2>&1
}

test_database_permissions() {
    # Test basic read permissions
    psql -c "SELECT count(*) FROM pg_stat_activity;" > /dev/null 2>&1
}

test_extensions_available() {
    # Check if common extensions are available
    local extensions=("pg_stat_statements")
    
    for ext in "${extensions[@]}"; do
        if ! psql -t -c "SELECT 1 FROM pg_available_extensions WHERE name = '$ext';" | grep -q 1; then
            if [[ "$VERBOSE" == "true" ]]; then
                warn "Extension not available: $ext"
            fi
        fi
    done
    return 0  # Don't fail if extensions missing
}

# Directories that contribute .sql files to the syntax test corpus. Kept as an
# allowlist rather than a recursive find so we can intentionally exclude folders
# (e.g. timescaledb/, which only runs under a TimescaleDB-enabled cluster).
SQL_TEST_DIRS=(
    "$PGTOOLS_ROOT/administration"
    "$PGTOOLS_ROOT/backup"
    "$PGTOOLS_ROOT/configuration"
    "$PGTOOLS_ROOT/maintenance"
    "$PGTOOLS_ROOT/monitoring"
    "$PGTOOLS_ROOT/optimization"
    "$PGTOOLS_ROOT/performance"
    "$PGTOOLS_ROOT/security"
    "$PGTOOLS_ROOT/troubleshooting"
)

# Files that require a superuser connection. Skipped when SKIP_SUPERUSER_SCRIPTS
# is true so limited-role CI runs don't report false failures.
SQL_REQUIRES_SUPERUSER=(
    "security/permission_audit.sql"
    "maintenance/switch_pg_wal_file.sql"
)

# Files that require pg_stat_statements.
SQL_REQUIRES_PG_STAT_STATEMENTS=(
    "optimization/missing_indexes.sql"
    "performance/query_performance_profiler.sql"
    "troubleshooting/postgres_troubleshooting_queries.sql"
    "troubleshooting/postgres_troubleshooting_query_pack_01.sql"
    "troubleshooting/postgres_troubleshooting_query_pack_02.sql"
    "troubleshooting/postgres_troubleshooting_query_pack_03.sql"
)

# Files that require pg_buffercache.
SQL_REQUIRES_PG_BUFFERCACHE=(
    "__none__"
)

# TimescaleDB-only files. Always skipped by the syntax test; covered separately
# when the test runs against a TimescaleDB-enabled instance.
SQL_REQUIRES_TIMESCALEDB=(
    "administration/NonHypertables.sql"
)

_sql_list_contains() {
    # $1 = relative path (e.g. "security/permission_audit.sql")
    # $2..N = entries to check against
    local needle="$1"; shift
    local entry
    for entry in "$@"; do
        if [[ "$entry" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# Syntax validation tests — iterates every .sql file in SQL_TEST_DIRS and runs
# it with ON_ERROR_STOP=1 so any parse/bind error becomes a non-zero exit.
test_sql_syntax() {
    local failed=0
    local dir
    local sql_file
    local rel_path

    for dir in "${SQL_TEST_DIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
            warn "SQL directory not found: $dir"
            continue
        fi

        while IFS= read -r -d '' sql_file; do
            rel_path="${sql_file#"$PGTOOLS_ROOT"/}"

            if _sql_list_contains "$rel_path" "${SQL_REQUIRES_TIMESCALEDB[@]}"; then
                [[ "$VERBOSE" == "true" ]] && log "Skipping TimescaleDB-only script: $rel_path"
                continue
            fi

            if [[ "$SKIP_SUPERUSER_SCRIPTS" == "true" ]] \
                && _sql_list_contains "$rel_path" "${SQL_REQUIRES_SUPERUSER[@]}"; then
                [[ "$VERBOSE" == "true" ]] && log "Skipping superuser-only script (not superuser): $rel_path"
                continue
            fi

            if [[ "$HAS_PG_STAT_STATEMENTS" == "false" ]] \
                && _sql_list_contains "$rel_path" "${SQL_REQUIRES_PG_STAT_STATEMENTS[@]}"; then
                [[ "$VERBOSE" == "true" ]] && log "Skipping pg_stat_statements-dependent script: $rel_path"
                continue
            fi

            if [[ "$HAS_PG_BUFFERCACHE" == "false" ]] \
                && _sql_list_contains "$rel_path" "${SQL_REQUIRES_PG_BUFFERCACHE[@]}"; then
                [[ "$VERBOSE" == "true" ]] && log "Skipping pg_buffercache-dependent script: $rel_path"
                continue
            fi

            if ! psql -v ON_ERROR_STOP=1 -f "$sql_file" > /dev/null 2>&1; then
                error "SQL execution error in: $rel_path"
                failed=1
            elif [[ "$VERBOSE" == "true" ]]; then
                log "OK: $rel_path"
            fi
        done < <(find "$dir" -maxdepth 2 -type f -name '*.sql' -print0)
    done

    return "$failed"
}

test_automation_scripts() {
    local scripts=(
        "$SCRIPT_DIR/pgtools_health_check.sh"
        "$SCRIPT_DIR/pgtools_scheduler.sh"
        "$SCRIPT_DIR/run_security_audit.sh"
        "$SCRIPT_DIR/cleanup_reports.sh"
        "$SCRIPT_DIR/export_metrics.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            if ! bash -n "$script"; then
                error "Bash syntax error in: $script"
                return 1
            fi
        else
            warn "Script not found: $script"
        fi
    done
    return 0
}

test_configuration_files() {
    local config_files=(
        "$SCRIPT_DIR/pgtools.conf.example"
    )
    
    for config_file in "${config_files[@]}"; do
        if [[ -f "$config_file" ]]; then
            # Test if config file can be sourced
            if ! bash -c "source $config_file"; then
                error "Configuration file has errors: $config_file"
                return 1
            fi
        else
            warn "Config file not found: $config_file"
        fi
    done
    return 0
}

# Permission requirement tests
test_monitoring_permissions() {
    # Test if we can access monitoring views
    local required_views=(
        "pg_stat_activity"
        "pg_stat_database" 
        "pg_locks"
    )
    
    for view in "${required_views[@]}"; do
        if ! psql -c "SELECT 1 FROM $view LIMIT 1;" > /dev/null 2>&1; then
            error "Cannot access required view: $view"
            return 1
        fi
    done
    return 0
}

test_backup_permissions() {
    # Test backup-related permissions
    if ! psql -c "SELECT pg_is_in_recovery();" > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Integration tests (only run with --full)
test_health_check_integration() {
    if [[ "$RUN_FULL" != "true" ]]; then
        return 0
    fi
    
    local health_script="$SCRIPT_DIR/pgtools_health_check.sh"
    if [[ -x "$health_script" ]]; then
        if ! "$health_script" --dry-run --quick > /dev/null 2>&1; then
            return 1
        fi
    else
        return 1
    fi
    return 0
}

test_metrics_export_integration() {
    if [[ "$RUN_FULL" != "true" ]]; then
        return 0
    fi
    
    local metrics_script="$SCRIPT_DIR/export_metrics.sh"
    if [[ -x "$metrics_script" ]]; then
        local temp_output
        temp_output=$(mktemp)
        if "$metrics_script" --format json > "$temp_output" 2>&1; then
            # Validate JSON output
            if command -v python3 > /dev/null 2>&1; then
                if ! python3 -m json.tool < "$temp_output" > /dev/null 2>&1; then
                    rm -f "$temp_output"
                    return 1
                fi
            fi
            rm -f "$temp_output"
            return 0
        else
            rm -f "$temp_output"
            return 1
        fi
    fi
    return 1
}

# Report generation
generate_test_report() {
    echo
    echo "==============================================="
    echo "PostgreSQL Tools Test Report"
    echo "==============================================="
    echo "Tests run: $TESTS_RUN"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    if [[ "$TESTS_RUN" -gt 0 ]]; then
        echo "Success rate: $(( TESTS_PASSED * 100 / TESTS_RUN ))%"
    else
        echo "Success rate: n/a (no tests matched the current pattern/filters)"
    fi
    echo "==============================================="
    
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        error "Some tests failed"
        return 1
    else
        success "All tests passed"
        return 0
    fi
}

# Main test execution
main() {
    log "Starting pgtools test suite"
    
    if [[ "$RUN_FAST" == "true" ]]; then
        log "Running fast tests (connection and syntax validation)"
    fi
    
    if [[ "$RUN_FULL" == "true" ]]; then
        log "Running full test suite (including integration tests)"
    fi
    
    # Connection tests
    run_test "connection_basic" test_database_connection
    run_test "connection_permissions" test_database_permissions
    run_test "connection_extensions" test_extensions_available

    # Detect environment once; cheaper than doing it per-file, and the skip
    # flags need to be populated before the syntax sweep starts.
    detect_environment_capabilities
    
    # Syntax tests
    run_test "syntax_sql_files" test_sql_syntax
    run_test "syntax_automation_scripts" test_automation_scripts
    run_test "syntax_configuration" test_configuration_files
    
    # Permission tests
    run_test "permissions_monitoring" test_monitoring_permissions
    run_test "permissions_backup" test_backup_permissions
    
    # Integration tests (full mode only)
    if [[ "$RUN_FULL" == "true" ]]; then
        run_test "integration_health_check" test_health_check_integration
        run_test "integration_metrics_export" test_metrics_export_integration
    fi
    
    generate_test_report
}

main "$@"