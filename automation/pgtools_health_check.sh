#!/bin/bash
#
# Script: pgtools_health_check.sh
# Purpose: Automated PostgreSQL health check runner
# Usage: ./automation/pgtools_health_check.sh [options]
#
# Requirements:
#   - PostgreSQL client (psql) installed
#   - Database connection parameters configured
#   - Appropriate database privileges
#
# Features:
#   - Runs essential health monitoring scripts
#   - Generates formatted reports
#   - Supports multiple output formats
#   - Email notifications for critical issues
#   - Configurable thresholds and alerts
#

set -euo pipefail

# Script directory and pgtools root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGTOOLS_ROOT="$(dirname "$SCRIPT_DIR")"

# Default configuration
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/pgtools.conf"
CONFIG_FILE="${PGTOOLS_CONFIG:-$DEFAULT_CONFIG_FILE}"
OUTPUT_DIR="${PGTOOLS_OUTPUT_DIR:-$SCRIPT_DIR/reports}"
LOG_FILE="${PGTOOLS_LOG_FILE:-$OUTPUT_DIR/pgtools.log}"

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${YELLOW}WARN${NC}] $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${RED}ERROR${NC}] $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${GREEN}SUCCESS${NC}] $*" | tee -a "$LOG_FILE"
}

info() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${BLUE}INFO${NC}] $*" | tee -a "$LOG_FILE"
}

# Usage information
usage() {
    cat << EOF
PostgreSQL Tools Health Check Runner

Usage: $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -c, --config FILE       Configuration file (default: $DEFAULT_CONFIG_FILE)
    -o, --output DIR        Output directory (default: $OUTPUT_DIR)
    -f, --format FORMAT     Output format: text, html, json (default: text)
    -q, --quick             Quick check (essential scripts only)
    -v, --verbose           Verbose output
    --no-email              Disable email notifications
    --dry-run               Show what would be executed without running

EXAMPLES:
    $0                                  # Run with default settings
    $0 -f html -o /var/log/pgtools     # Generate HTML report
    $0 --quick --no-email              # Quick check without notifications
    $0 --dry-run                       # Preview execution plan

CONFIGURATION:
    Create $DEFAULT_CONFIG_FILE with database connection parameters:
    
    PGHOST=localhost
    PGPORT=5432
    PGDATABASE=postgres
    PGUSER=monitoring_user
    PGPASSWORD=secure_password
    
    EMAIL_ALERTS=true
    EMAIL_RECIPIENTS="dba@company.com,ops@company.com"
    ALERT_THRESHOLDS_FILE="thresholds.conf"

EOF
}

# Default values
FORMAT="text"
QUICK_MODE=false
VERBOSE=false
EMAIL_ENABLED=true
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -f|--format)
            FORMAT="$2"
            shift 2
            ;;
        -q|--quick)
            QUICK_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --no-email)
            EMAIL_ENABLED=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Load configuration if available
if [[ -f "$CONFIG_FILE" ]]; then
    log "Loading configuration from $CONFIG_FILE"
    # shellcheck disable=SC1091
    # shellcheck source=pgtools.conf
    source "$CONFIG_FILE"
else
    warn "Configuration file not found: $CONFIG_FILE"
    warn "Using environment variables or psql defaults"
fi

# Verify PostgreSQL connection
check_connection() {
    log "Checking PostgreSQL connection..."
    
    if ! psql -c "SELECT 1;" >/dev/null 2>&1; then
        error "Cannot connect to PostgreSQL database"
        error "Please check connection parameters and ensure database is running"
        exit 1
    fi
    
    success "PostgreSQL connection established"
    
    # Get database version and basic info
    DB_VERSION=$(psql -t -c "SELECT version();" | head -1 | xargs)
    DB_NAME=$(psql -t -c "SELECT current_database();" | xargs)
    DB_USER=$(psql -t -c "SELECT current_user;" | xargs)
    
    info "Database: $DB_NAME"
    info "User: $DB_USER"
    info "Version: $DB_VERSION"
}

# Run a SQL script and capture output
run_script() {
    local script_path="$1"
    local script_name="$2"
    local output_file="$3"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would execute: $script_name"
        return 0
    fi
    
    log "Running $script_name..."
    
    if [[ "$VERBOSE" == "true" ]]; then
        info "Executing: $script_path"
    fi
    
    if psql -f "$script_path" > "$output_file" 2>&1; then
        success "Completed: $script_name"
        return 0
    else
        error "Failed: $script_name"
        return 1
    fi
}

# Generate timestamp for report files
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
REPORT_PREFIX="pgtools_health_check_${TIMESTAMP}"

# Define monitoring scripts to run
# shellcheck disable=SC2034 # referenced via nameref when selecting script set
declare -A ESSENTIAL_SCRIPTS=(
    ["Connection Analysis"]="monitoring/connection_pools.sql"
    ["Lock Analysis"]="monitoring/locks.sql"
    ["Replication Status"]="monitoring/replication.sql"
    ["Transaction Wraparound"]="monitoring/txid.sql"
    ["Backup Validation"]="backup/backup_validation.sql"
)

# shellcheck disable=SC2034 # referenced via nameref when selecting script set
declare -A FULL_SCRIPTS=(
    ["Table Bloating"]="monitoring/bloating.sql"
    ["Buffer Performance"]="monitoring/buffer_troubleshoot.sql"
    ["Index Analysis"]="optimization/missing_indexes.sql"
    ["HOT Updates"]="optimization/hot_update_optimization_checklist.sql"
    ["Partition Management"]="administration/partition_management.sql"
    ["Security Audit"]="security/permission_audit.sql"
    ["Extensions Audit"]="administration/extensions.sql"
    ["Table Ownership"]="administration/table_ownership.sql"
    ["Foreign Constraints"]="administration/ForeignConst.sql"
)

# Function to run health checks
run_health_checks() {
    local scripts_to_run
    
    if [[ "$QUICK_MODE" == "true" ]]; then
        log "Running quick health check (essential scripts only)"
        scripts_to_run="ESSENTIAL_SCRIPTS"
    else
        log "Running full health check"
        # shellcheck disable=SC2034 # referenced through nameref
        local -A combined_scripts=()
        local key

        for key in "${!FULL_SCRIPTS[@]}"; do
            # shellcheck disable=SC2034
            combined_scripts["$key"]="${FULL_SCRIPTS[$key]}"
        done
        # shellcheck disable=SC2034
        for key in "${!ESSENTIAL_SCRIPTS[@]}"; do
            combined_scripts["$key"]="${ESSENTIAL_SCRIPTS[$key]}"
        done
        scripts_to_run="combined_scripts"
    fi
    
    local -n scripts_ref=$scripts_to_run
    local total_scripts=${#scripts_ref[@]}
    local completed_scripts=0
    local failed_scripts=0
    
    log "Total scripts to execute: $total_scripts"
    
    # Create individual output files
    for script_name in "${!scripts_ref[@]}"; do
        local script_path="${PGTOOLS_ROOT}/${scripts_ref[$script_name]}"
        local output_file
        output_file="${OUTPUT_DIR}/${REPORT_PREFIX}_$(echo "$script_name" | tr ' ' '_' | tr '[:upper:]' '[:lower:]').txt"
        
        if [[ -f "$script_path" ]]; then
            if run_script "$script_path" "$script_name" "$output_file"; then
                completed_scripts=$((completed_scripts + 1))
            else
                failed_scripts=$((failed_scripts + 1))
            fi
        else
            error "Script not found: $script_path"
            failed_scripts=$((failed_scripts + 1))
        fi
    done
    
    log "Health check completed: $completed_scripts successful, $failed_scripts failed"
    return $failed_scripts
}

# Function to generate consolidated report
generate_report() {
    local report_file="${OUTPUT_DIR}/${REPORT_PREFIX}_consolidated_report.${FORMAT}"
    
    log "Generating consolidated report: $report_file"
    
    case "$FORMAT" in
        "text")
            generate_text_report "$report_file"
            ;;
        "html")
            generate_html_report "$report_file"
            ;;
        "json")
            generate_json_report "$report_file"
            ;;
        *)
            error "Unsupported format: $FORMAT"
            return 1
            ;;
    esac
    
    success "Report generated: $report_file"
}

generate_text_report() {
    local report_file="$1"
    
    cat > "$report_file" << EOF
PostgreSQL Tools Health Check Report
Generated: $(date)
Database: $DB_NAME
User: $DB_USER
Version: $DB_VERSION

=============================================================================

EOF
    
    # Append individual script outputs
    for output_file in "${OUTPUT_DIR}/${REPORT_PREFIX}"_*.txt; do
        if [[ -f "$output_file" ]]; then
            {
                echo "--- $(basename "$output_file" .txt | sed 's/^.*_//; s/_/ /g') ---"
                echo
                cat "$output_file"
                echo
                echo "============================================================================="
                echo
            } >> "$report_file"
        fi
    done
}

generate_html_report() {
    local report_file="$1"
    
    cat > "$report_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>PostgreSQL Health Check Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 10px; border-radius: 5px; }
        .section { margin: 20px 0; border: 1px solid #ddd; border-radius: 5px; }
        .section-title { background-color: #e0e0e0; padding: 10px; font-weight: bold; }
        .content { padding: 10px; white-space: pre-wrap; font-family: monospace; }
        .critical { color: #d32f2f; }
        .warning { color: #f57c00; }
        .success { color: #388e3c; }
    </style>
</head>
<body>
    <div class="header">
        <h1>PostgreSQL Tools Health Check Report</h1>
        <p><strong>Generated:</strong> $(date)</p>
        <p><strong>Database:</strong> $DB_NAME</p>
        <p><strong>User:</strong> $DB_USER</p>
        <p><strong>Version:</strong> $DB_VERSION</p>
    </div>
EOF
    
    # Process individual script outputs
    for output_file in "${OUTPUT_DIR}/${REPORT_PREFIX}"_*.txt; do
        if [[ -f "$output_file" ]]; then
            local section_name
            section_name=$(basename "$output_file" .txt | sed 's/^.*_//; s/_/ /g')
            cat >> "$report_file" << EOF
    <div class="section">
        <div class="section-title">$section_name</div>
        <div class="content">$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$output_file")</div>
    </div>
EOF
        fi
    done
    
    echo "</body></html>" >> "$report_file"
}

generate_json_report() {
    local report_file="$1"
    
    cat > "$report_file" << EOF
{
    "report_metadata": {
        "generated": "$(date -Iseconds)",
        "database": "$DB_NAME",
        "user": "$DB_USER",
        "version": "$DB_VERSION",
        "format_version": "1.0"
    },
    "sections": [
EOF
    
    local first_section=true
    for output_file in "${OUTPUT_DIR}/${REPORT_PREFIX}"_*.txt; do
        if [[ -f "$output_file" ]]; then
            if [[ "$first_section" == "false" ]]; then
                echo "        ," >> "$report_file"
            fi
            first_section=false
            
            local section_name
            section_name=$(basename "$output_file" .txt | sed 's/^.*_//; s/_/ /g')
            local content
            content=$(sed 's/\\/\\\\/g; s/"/\\"/g' "$output_file" | sed ':a;N;$!ba;s/\n/\\n/g')
            
            cat >> "$report_file" << EOF
        {
            "name": "$section_name",
            "content": "$content"
        }
EOF
        fi
    done
    
    echo -e "\n    ]\n}" >> "$report_file"
}

# Function to send email notifications (if configured)
send_notifications() {
    if [[ "$EMAIL_ENABLED" != "true" ]] || [[ -z "${EMAIL_RECIPIENTS:-}" ]]; then
        log "Email notifications disabled or no recipients configured"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would send email notifications to: $EMAIL_RECIPIENTS"
        return 0
    fi
    
    local report_file="${OUTPUT_DIR}/${REPORT_PREFIX}_consolidated_report.${FORMAT}"
    local subject
    subject="PostgreSQL Health Check Report - $DB_NAME - $(date '+%Y-%m-%d %H:%M')"
    
    log "Sending email notifications to: $EMAIL_RECIPIENTS"
    
    if command -v mail >/dev/null 2>&1; then
        echo "PostgreSQL Health Check Report attached" | mail -s "$subject" -A "$report_file" "$EMAIL_RECIPIENTS"
        success "Email notification sent"
    elif command -v mutt >/dev/null 2>&1; then
        echo "PostgreSQL Health Check Report attached" | mutt -s "$subject" -a "$report_file" -- "$EMAIL_RECIPIENTS"
        success "Email notification sent"
    else
        warn "No mail command available (mail or mutt). Email notification skipped."
    fi
}

# Main execution
main() {
    log "Starting PostgreSQL Tools Health Check"
    log "Configuration: $CONFIG_FILE"
    log "Output directory: $OUTPUT_DIR"
    log "Output format: $FORMAT"
    
    # Check connection first
    check_connection
    
    # Run health checks
    if run_health_checks; then
        success "All health checks completed successfully"
    else
        warn "Some health checks failed. Check individual script outputs."
    fi
    
    # Generate consolidated report
    generate_report
    
    # Send notifications if configured
    send_notifications
    
    log "Health check process completed"
    log "Reports available in: $OUTPUT_DIR"
}

# Run main function
main "$@"