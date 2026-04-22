#!/bin/bash
#
# Script: auto_maintenance.sh
# Purpose: Automated PostgreSQL maintenance operations (VACUUM, ANALYZE, REINDEX)
#
# ANNOTATED EXAMPLES:
#
#   Basic Usage:
#   # Run automatic maintenance (combines ANALYZE + selective VACUUM)
#   ./maintenance/auto_maintenance.sh --operation auto --verbose
#
#   # Dry run to preview what would be done
#   ./maintenance/auto_maintenance.sh --operation auto --dry-run
#
#   VACUUM Operations:
#   # VACUUM tables with >15% dead tuples
#   ./maintenance/auto_maintenance.sh --operation vacuum --dead-threshold 15
#
#   # VACUUM specific tables
#   ./maintenance/auto_maintenance.sh --operation vacuum --tables "orders,users,sessions"
#
#   # VACUUM tables matching pattern
#   ./maintenance/auto_maintenance.sh --operation vacuum --tables "user_*,order_*"
#
#   ANALYZE Operations:
#   # ANALYZE all tables with stale statistics
#   ./maintenance/auto_maintenance.sh --operation analyze --verbose
#
#   # ANALYZE specific schema with 4 parallel jobs
#   ./maintenance/auto_maintenance.sh --operation analyze --schema public --parallel 4
#
#   Production Deployment:
#   # Safe maintenance during low-traffic period
#   ./maintenance/auto_maintenance.sh --operation auto --skip-large --large-size 5GB --parallel 2
#
#   # Weekly comprehensive maintenance
#   ./maintenance/auto_maintenance.sh --operation analyze --parallel 4 --output weekly_maintenance.log
#
#   Emergency Scenarios:
#   # Emergency VACUUM for bloated tables
#   ./maintenance/auto_maintenance.sh --operation vacuum --dead-threshold 10 --verbose
#
#   # Target specific problem tables
#   ./maintenance/auto_maintenance.sh --operation vacuum --tables "problem_table" --verbose
#
#   Automation Integration:
#   # Daily cron job (2 AM)
#   0 2 * * * /path/to/pgtools/maintenance/auto_maintenance.sh --operation auto --output /var/log/postgresql/daily_maintenance.log
#
#   # Weekly comprehensive analysis (Sunday 1 AM)
#   0 1 * * 0 /path/to/pgtools/maintenance/auto_maintenance.sh --operation analyze --parallel 4 --verbose
#
# Usage: ./maintenance/auto_maintenance.sh [OPTIONS]
#

set -euo pipefail


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

# Default values
OPERATION="analyze"
TARGET_TABLES=""
SCHEMA_PATTERN=""
DRY_RUN="false"
VERBOSE="false"
DEAD_TUPLE_THRESHOLD=20  # Percentage
BLOAT_THRESHOLD=30       # Percentage
PARALLEL_JOBS=1
OUTPUT_FILE=""
SKIP_LARGE_TABLES="false"
LARGE_TABLE_SIZE="10GB"

usage() {
    cat << EOF
PostgreSQL Automated Maintenance Tool

Usage: $0 [OPTIONS]

OPTIONS:
    -o, --operation OP      Operation: vacuum, analyze, reindex, auto (default: analyze)
    -t, --tables PATTERN    Table pattern (comma-separated, supports wildcards)
    -s, --schema PATTERN    Schema pattern (default: all user schemas)
    -n, --dry-run           Show what would be done without executing
    -v, --verbose           Verbose output with detailed statistics
    -j, --parallel JOBS     Number of parallel maintenance jobs (default: 1)
    --dead-threshold PCT    Dead tuple percentage threshold for vacuum (default: 20)
    --bloat-threshold PCT   Bloat percentage threshold for reindex (default: 30)
    --skip-large          Skip tables larger than threshold
    --large-size SIZE     Large table size threshold (default: 10GB)
    --output FILE         Output maintenance report to file
    -h, --help              Show this help

OPERATIONS:
    vacuum                  VACUUM tables with high dead tuple ratio
    analyze                 ANALYZE tables with outdated statistics
    reindex                 REINDEX tables/indexes with high bloat
    auto                    Automatic maintenance based on thresholds
    full-vacuum             VACUUM FULL for severely bloated tables (use with caution!)

EXAMPLES:
    $0 --operation auto --verbose                    # Auto maintenance with details
    $0 --operation vacuum --dead-threshold 15       # Vacuum tables >15% dead tuples
    $0 --operation analyze --schema public          # Analyze all tables in public schema
    $0 --tables "user_*,order_*" --operation vacuum # Vacuum specific table patterns
    $0 --dry-run --operation auto                   # Preview maintenance actions
    $0 --parallel 4 --operation analyze             # Parallel analyze operations

SAFETY FEATURES:
    - Dry-run mode for safe testing
    - Configurable thresholds to avoid unnecessary operations
    - Large table detection and optional skipping
    - Detailed logging and progress reporting
    - Automatic detection of maintenance needs

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--operation)
            OPERATION="$2"
            shift 2
            ;;
        -t|--tables)
            TARGET_TABLES="$2"
            shift 2
            ;;
        -s|--schema)
            SCHEMA_PATTERN="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -j|--parallel)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        --dead-threshold)
            DEAD_TUPLE_THRESHOLD="$2"
            shift 2
            ;;
        --bloat-threshold)
            BLOAT_THRESHOLD="$2"
            shift 2
            ;;
        --skip-large)
            SKIP_LARGE_TABLES="true"
            shift
            ;;
        --large-size)
            LARGE_TABLE_SIZE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
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

# Validate operation
case "$OPERATION" in
    vacuum|analyze|reindex|auto|full-vacuum) ;;
    *)
        error "Invalid operation: $OPERATION"
        exit 1
        ;;
esac

# Validate parallel jobs
if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_JOBS" -lt 1 ]]; then
    error "Invalid parallel jobs value: $PARALLEL_JOBS"
    exit 1
fi

# Convert size to bytes
parse_size() {
    local size="$1"
    if [[ "$size" =~ ^([0-9]+)([KMGT]?B?)$ ]]; then
        local number="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        
        case "$unit" in
            ""|"B") echo "$number" ;;
            "KB") echo $((number * 1024)) ;;
            "MB") echo $((number * 1024 * 1024)) ;;
            "GB") echo $((number * 1024 * 1024 * 1024)) ;;
            "TB") echo $((number * 1024 * 1024 * 1024 * 1024)) ;;
            *) echo "0" ;;
        esac
    else
        echo "0"
    fi
}

# Test database connection
test_connection() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "Testing database connection..."
    fi
    
    if ! psql -c "SELECT version();" > /dev/null 2>&1; then
        error "Cannot connect to PostgreSQL database"
        return 1
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        success "Database connection successful"
    fi
}

# Get tables needing vacuum
get_vacuum_candidates() {
    local temp_file
    temp_file=$(mktemp)
    
    local schema_filter=""
    if [[ -n "$SCHEMA_PATTERN" ]]; then
        schema_filter="AND schemaname = '$SCHEMA_PATTERN'"
    else
        schema_filter="AND schemaname NOT IN ('information_schema', 'pg_catalog')"
    fi
    
    local table_filter=""
    if [[ -n "$TARGET_TABLES" ]]; then
        # Convert comma-separated patterns to SQL LIKE conditions
        # shellcheck disable=SC2206  # intentional word-split of comma-separated list
        local patterns=(${TARGET_TABLES//,/ })
        local conditions=()
        for pattern in "${patterns[@]}"; do
            conditions+=("tablename LIKE '${pattern}'")
        done
        # shellcheck disable=SC2124  # join-with-IFS idiom uses [*] by design
        table_filter="AND ($(IFS=' OR '; echo "${conditions[*]}"))"
    fi
    
    psql -t -c "
    SELECT 
        schemaname,
        tablename,
        n_dead_tup,
        n_live_tup,
        ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_ratio,
        pg_total_relation_size(schemaname||'.'||tablename) as table_size,
        last_vacuum,
        last_autovacuum
    FROM pg_stat_user_tables
    WHERE n_live_tup + n_dead_tup > 0
        AND ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) >= $DEAD_TUPLE_THRESHOLD
        $schema_filter
        $table_filter
    ORDER BY dead_ratio DESC, table_size DESC
    " > "$temp_file" 2>/dev/null || {
        error "Failed to query vacuum candidates"
        rm -f "$temp_file"
        return 1
    }
    
    echo "$temp_file"
}

# Get tables needing analyze
get_analyze_candidates() {
    local temp_file
    temp_file=$(mktemp)
    
    local schema_filter=""
    if [[ -n "$SCHEMA_PATTERN" ]]; then
        schema_filter="AND schemaname = '$SCHEMA_PATTERN'"
    else
        schema_filter="AND schemaname NOT IN ('information_schema', 'pg_catalog')"
    fi
    
    local table_filter=""
    if [[ -n "$TARGET_TABLES" ]]; then
        # shellcheck disable=SC2206  # intentional word-split of comma-separated list
        local patterns=(${TARGET_TABLES//,/ })
        local conditions=()
        for pattern in "${patterns[@]}"; do
            conditions+=("tablename LIKE '${pattern}'")
        done
        # shellcheck disable=SC2124  # join-with-IFS idiom uses [*] by design
        table_filter="AND ($(IFS=' OR '; echo "${conditions[*]}"))"
    fi

    psql -t -c "
    SELECT
        schemaname,
        tablename,
        n_tup_ins + n_tup_upd + n_tup_del as total_changes,
        pg_total_relation_size(schemaname||'.'||tablename) as table_size,
        last_analyze,
        last_autoanalyze,
        CASE 
            WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 'NEVER'
            WHEN GREATEST(last_analyze, last_autoanalyze) < NOW() - INTERVAL '7 days' 
                 AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000 THEN 'OUTDATED'
            WHEN (n_tup_ins + n_tup_upd + n_tup_del) > n_live_tup * 0.1 THEN 'HIGH_CHANGES'
            ELSE 'OK'
        END as analyze_priority
    FROM pg_stat_user_tables
    WHERE (last_analyze IS NULL AND last_autoanalyze IS NULL)
        OR (GREATEST(COALESCE(last_analyze, '1900-01-01'), COALESCE(last_autoanalyze, '1900-01-01')) < NOW() - INTERVAL '7 days' 
            AND (n_tup_ins + n_tup_upd + n_tup_del) > 1000)
        OR ((n_tup_ins + n_tup_upd + n_tup_del) > n_live_tup * 0.1)
        $schema_filter
        $table_filter
    ORDER BY 
        CASE analyze_priority
            WHEN 'NEVER' THEN 1
            WHEN 'OUTDATED' THEN 2  
            WHEN 'HIGH_CHANGES' THEN 3
            ELSE 4
        END,
        total_changes DESC
    " > "$temp_file" 2>/dev/null || {
        error "Failed to query analyze candidates"
        rm -f "$temp_file"
        return 1
    }
    
    echo "$temp_file"
}

# Execute maintenance operation
execute_maintenance() {
    local operation="$1"
    local schema="$2"
    local table="$3"
    local reason="$4"
    
    local full_table_name="${schema}.${table}"
    
    # Check if table is too large and should be skipped
    if [[ "$SKIP_LARGE_TABLES" == "true" ]]; then
        local table_size_bytes
        local size_threshold
        table_size_bytes=$(psql -t -c "SELECT pg_total_relation_size('$full_table_name');" 2>/dev/null | xargs)
        size_threshold=$(parse_size "$LARGE_TABLE_SIZE")

        if [[ "$table_size_bytes" -gt "$size_threshold" ]]; then
            warn "Skipping large table: $full_table_name ($(pg_size_pretty "$table_size_bytes"))"
            return 0
        fi
    fi

    local start_time
    start_time=$(date +%s)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would execute $operation on $full_table_name ($reason)"
        return 0
    fi
    
    log "Starting $operation on $full_table_name ($reason)"
    
    case "$operation" in
        "VACUUM")
            if psql -c "VACUUM (VERBOSE) $full_table_name;" 2>/dev/null; then
                local end_time duration
                end_time=$(date +%s)
                duration=$((end_time - start_time))
                success "VACUUM completed on $full_table_name (${duration}s)"
            else
                error "VACUUM failed on $full_table_name"
                return 1
            fi
            ;;
        "ANALYZE")
            if psql -c "ANALYZE (VERBOSE) $full_table_name;" 2>/dev/null; then
                local end_time duration
                end_time=$(date +%s)
                duration=$((end_time - start_time))
                success "ANALYZE completed on $full_table_name (${duration}s)"
            else
                error "ANALYZE failed on $full_table_name"
                return 1
            fi
            ;;
        "VACUUM FULL")
            warn "Executing VACUUM FULL on $full_table_name - this will lock the table!"
            if psql -c "VACUUM (FULL, VERBOSE) $full_table_name;" 2>/dev/null; then
                local end_time duration
                end_time=$(date +%s)
                duration=$((end_time - start_time))
                success "VACUUM FULL completed on $full_table_name (${duration}s)"
            else
                error "VACUUM FULL failed on $full_table_name"
                return 1
            fi
            ;;
        "REINDEX")
            if psql -c "REINDEX (VERBOSE) TABLE $full_table_name;" 2>/dev/null; then
                local end_time duration
                end_time=$(date +%s)
                duration=$((end_time - start_time))
                success "REINDEX completed on $full_table_name (${duration}s)"
            else
                error "REINDEX failed on $full_table_name"
                return 1
            fi
            ;;
    esac
}

# Process vacuum operations
process_vacuum() {
    log "Analyzing tables for VACUUM operations (dead tuple threshold: ${DEAD_TUPLE_THRESHOLD}%)"
    
    local candidates_file
    candidates_file=$(get_vacuum_candidates) || return 1
    
    local count=0
    while IFS=$'\t' read -r schema table dead_tuples live_tuples dead_ratio size _last_vacuum _last_autovacuum; do
        [[ -z "$schema" ]] && continue
        ((count++))
        
        local reason="Dead tuples: ${dead_ratio}%"
        if [[ "$VERBOSE" == "true" ]]; then
            reason="$reason (${dead_tuples} dead, ${live_tuples} live)"
        fi
        
        execute_maintenance "VACUUM" "$schema" "$table" "$reason"
        
        # Respect parallel job limit
        if [[ $((count % PARALLEL_JOBS)) -eq 0 ]]; then
            sleep 1  # Brief pause between parallel batches
        fi
    done < "$candidates_file"
    
    rm -f "$candidates_file"
    
    if [[ "$count" -eq 0 ]]; then
        success "No tables require VACUUM (threshold: ${DEAD_TUPLE_THRESHOLD}%)"
    else
        success "VACUUM operations completed on $count tables"
    fi
}

# Process analyze operations
process_analyze() {
    log "Analyzing tables for ANALYZE operations"
    
    local candidates_file
    candidates_file=$(get_analyze_candidates) || return 1
    
    local count=0
    while IFS=$'\t' read -r schema table total_changes size _last_analyze _last_autoanalyze priority; do
        [[ -z "$schema" ]] && continue
        ((count++))
        
        local reason="Priority: $priority"
        if [[ "$VERBOSE" == "true" ]]; then
            reason="$reason (${total_changes} changes since last analyze)"
        fi
        
        execute_maintenance "ANALYZE" "$schema" "$table" "$reason"
        
        # Respect parallel job limit
        if [[ $((count % PARALLEL_JOBS)) -eq 0 ]]; then
            sleep 1
        fi
    done < "$candidates_file"
    
    rm -f "$candidates_file"
    
    if [[ "$count" -eq 0 ]]; then
        success "No tables require ANALYZE"
    else
        success "ANALYZE operations completed on $count tables"
    fi
}

# Auto maintenance mode
process_auto() {
    log "Starting automatic maintenance analysis..."
    
    # First run ANALYZE for tables with outdated statistics
    log "Phase 1: Updating table statistics"
    process_analyze
    
    # Then run VACUUM for tables with high dead tuple ratio
    log "Phase 2: Cleaning up dead tuples"
    process_vacuum
    
    success "Automatic maintenance completed"
}

# Generate maintenance report
generate_report() {
    local report_content
    report_content=$(cat << EOF
PostgreSQL Maintenance Report
Generated: $(date)
Database: ${PGDATABASE:-default}
Host: ${PGHOST:-localhost}:${PGPORT:-5432}

Operation: $OPERATION
Dry Run: $DRY_RUN
Parallel Jobs: $PARALLEL_JOBS
Dead Tuple Threshold: ${DEAD_TUPLE_THRESHOLD}%
Bloat Threshold: ${BLOAT_THRESHOLD}%

Tables Processed:
EOF
)
    
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$report_content" > "$OUTPUT_FILE"
        log "Maintenance report written to: $OUTPUT_FILE"
    fi
}

# Main execution
main() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "PostgreSQL Automated Maintenance Tool"
        log "Operation: $OPERATION"
        log "Target tables: ${TARGET_TABLES:-all}"
        log "Schema pattern: ${SCHEMA_PATTERN:-all user schemas}"
        log "Dry run: $DRY_RUN"
        log "Parallel jobs: $PARALLEL_JOBS"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN MODE - No actual maintenance will be performed"
    fi
    
    test_connection || exit 1
    
    case "$OPERATION" in
        "vacuum")
            process_vacuum
            ;;
        "analyze")
            process_analyze
            ;;
        "auto")
            process_auto
            ;;
        "reindex")
            warn "REINDEX operation not yet implemented - use manual REINDEX commands"
            ;;
        "full-vacuum")
            warn "VACUUM FULL is a blocking operation that requires exclusive table locks"
            if [[ "$DRY_RUN" != "true" ]]; then
                read -rp "Are you sure you want to continue? (yes/no): " confirm
                if [[ "$confirm" != "yes" ]]; then
                    log "Operation cancelled"
                    exit 0
                fi
            fi
            process_vacuum
            ;;
    esac
    
    generate_report
    
    if [[ "$VERBOSE" == "true" ]]; then
        success "Maintenance operations completed successfully"
    fi
}

main "$@"