#!/bin/bash
#
# Script: parameter_tuner.sh
# Purpose: PostgreSQL configuration parameter tuning assistant
# Usage: ./configuration/parameter_tuner.sh [OPTIONS]
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

# Default values
MODE="analyze"
OUTPUT_FILE=""
SYSTEM_RAM=""
WORKLOAD_TYPE="mixed"
VERBOSE="false"
APPLY_CHANGES="false"

usage() {
    cat << EOF
PostgreSQL Parameter Tuning Assistant

Usage: $0 [OPTIONS]

OPTIONS:
    -m, --mode MODE         Mode: analyze, recommend, generate (default: analyze)
    -o, --output FILE       Output file for recommendations
    -r, --ram SIZE          System RAM size (e.g., 8GB, 16384MB)
    -w, --workload TYPE     Workload type: oltp, olap, mixed, web (default: mixed)
    -a, --apply             Apply recommended changes (use with caution!)
    -v, --verbose           Verbose output
    -h, --help              Show this help

MODES:
    analyze                 Analyze current configuration
    recommend               Generate tuning recommendations
    generate                Generate postgresql.conf snippet

WORKLOAD TYPES:
    oltp                    Online Transaction Processing (high concurrency, small queries)
    olap                    Online Analytical Processing (complex queries, reporting)
    mixed                   Mixed workload (balanced settings)
    web                     Web application (connection pooled, mixed queries)

EXAMPLES:
    $0 --mode analyze                           # Analyze current config
    $0 --mode recommend --ram 16GB --workload oltp  # OLTP recommendations
    $0 --mode generate --ram 32GB --workload olap -o tuned.conf
    $0 --mode recommend --verbose               # Verbose recommendations

SAFETY:
    - Always test configuration changes in non-production first
    - Backup postgresql.conf before applying changes
    - Monitor performance after changes
    - Use --apply flag only after careful review

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -r|--ram)
            SYSTEM_RAM="$2"
            shift 2
            ;;
        -w|--workload)
            WORKLOAD_TYPE="$2"
            shift 2
            ;;
        -a|--apply)
            APPLY_CHANGES="true"
            shift
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

# Validate parameters
case "$MODE" in
    analyze|recommend|generate) ;;
    *)
        error "Invalid mode: $MODE"
        exit 1
        ;;
esac

case "$WORKLOAD_TYPE" in
    oltp|olap|mixed|web) ;;
    *)
        error "Invalid workload type: $WORKLOAD_TYPE"
        exit 1
        ;;
esac

# Convert RAM size to bytes
parse_ram_size() {
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

# Detect system RAM if not provided
detect_system_ram() {
    if [[ -n "$SYSTEM_RAM" ]]; then
        parse_ram_size "$SYSTEM_RAM"
        return
    fi
    
    # Try to detect RAM on macOS and Linux
    if command -v sysctl > /dev/null 2>&1; then
        # macOS
        local ram_bytes
        ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
        echo "$ram_bytes"
    elif [[ -f /proc/meminfo ]]; then
        # Linux
        local ram_kb
        ram_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
        echo $((ram_kb * 1024))
    else
        echo "0"
    fi
}

# Get current database parameters
get_current_parameters() {
    local temp_file
    temp_file=$(mktemp)
    
    psql -t -c "
    SELECT 
        name,
        setting,
        unit,
        source
    FROM pg_settings 
    WHERE name IN (
        'shared_buffers',
        'work_mem', 
        'maintenance_work_mem',
        'effective_cache_size',
        'wal_buffers',
        'max_connections',
        'checkpoint_completion_target',
        'max_wal_size',
        'random_page_cost',
        'effective_io_concurrency',
        'default_statistics_target'
    )
    ORDER BY name;
    " > "$temp_file" 2>/dev/null || {
        error "Failed to connect to database"
        rm -f "$temp_file"
        return 1
    }
    
    echo "$temp_file"
}

# Generate memory recommendations
calculate_memory_settings() {
    local ram_bytes="$1"
    local workload="$2"
    
    if [[ "$ram_bytes" -eq 0 ]]; then
        warn "Cannot detect system RAM - using conservative defaults"
        ram_bytes=$((8 * 1024 * 1024 * 1024))  # 8GB default
    fi
    
    local ram_gb=$((ram_bytes / 1024 / 1024 / 1024))
    
    # Calculate shared_buffers (15-25% of RAM depending on workload)
    local shared_buffers_percent
    case "$workload" in
        oltp) shared_buffers_percent=20 ;;
        olap) shared_buffers_percent=25 ;;
        web) shared_buffers_percent=15 ;;
        *) shared_buffers_percent=20 ;;
    esac
    
    local shared_buffers_mb=$((ram_gb * 1024 * shared_buffers_percent / 100))
    
    # Calculate work_mem (RAM / max_connections / 2-4)
    local max_connections
    case "$workload" in
        oltp) max_connections=200 ;;
        olap) max_connections=50 ;;
        web) max_connections=100 ;;
        *) max_connections=100 ;;
    esac
    
    local work_mem_mb=$(((ram_gb * 1024) / max_connections / 4))
    [[ "$work_mem_mb" -lt 4 ]] && work_mem_mb=4
    [[ "$work_mem_mb" -gt 512 ]] && work_mem_mb=512
    
    # Calculate maintenance_work_mem (5-10% of RAM)
    local maint_work_mem_mb=$((ram_gb * 1024 * 8 / 100))
    [[ "$maint_work_mem_mb" -gt 2048 ]] && maint_work_mem_mb=2048
    [[ "$maint_work_mem_mb" -lt 64 ]] && maint_work_mem_mb=64
    
    # Calculate effective_cache_size (50-75% of RAM)
    local effective_cache_percent
    case "$workload" in
        olap) effective_cache_percent=75 ;;
        *) effective_cache_percent=60 ;;
    esac
    local effective_cache_mb=$((ram_gb * 1024 * effective_cache_percent / 100))
    
    cat << EOF
shared_buffers=${shared_buffers_mb}MB
work_mem=${work_mem_mb}MB
maintenance_work_mem=${maint_work_mem_mb}MB
effective_cache_size=${effective_cache_mb}MB
max_connections=${max_connections}
EOF
}

# Generate performance recommendations
calculate_performance_settings() {
    local workload="$1"
    
    case "$workload" in
        oltp)
            cat << EOF
# OLTP Workload Optimizations
checkpoint_completion_target=0.9
max_wal_size=4GB
random_page_cost=1.1
effective_io_concurrency=200
default_statistics_target=100
EOF
            ;;
        olap)
            cat << EOF
# OLAP Workload Optimizations  
checkpoint_completion_target=0.9
max_wal_size=8GB
random_page_cost=1.1
effective_io_concurrency=200
default_statistics_target=500
max_parallel_workers_per_gather=4
max_parallel_workers=8
EOF
            ;;
        web)
            cat << EOF
# Web Application Optimizations
checkpoint_completion_target=0.9
max_wal_size=2GB
random_page_cost=1.1
effective_io_concurrency=100
default_statistics_target=200
EOF
            ;;
        *)
            cat << EOF
# Mixed Workload Optimizations
checkpoint_completion_target=0.9
max_wal_size=4GB
random_page_cost=1.1
effective_io_concurrency=200
default_statistics_target=200
EOF
            ;;
    esac
}

# Analyze current configuration
analyze_configuration() {
    log "Analyzing current PostgreSQL configuration..."
    
    local params_file
    params_file=$(get_current_parameters) || return 1
    
    echo "Current Configuration Analysis:"
    echo "==============================="
    
    # Parse current settings
    while IFS=$'\t' read -r name setting unit source; do
        [[ -z "$name" ]] && continue
        
        local formatted_value="$setting"
        [[ -n "$unit" ]] && formatted_value="$setting$unit"
        
        printf "%-30s: %-15s (source: %s)\n" "$name" "$formatted_value" "$source"
        
        # Add recommendations for key parameters
        case "$name" in
            "shared_buffers")
                if [[ "$unit" == "8kB" ]]; then
                    local mb_value=$((setting * 8 / 1024))
                    if [[ "$mb_value" -lt 128 ]]; then
                        echo "  → RECOMMENDATION: Increase to ~25% of RAM"
                    fi
                fi
                ;;
            "work_mem")
                if [[ "$unit" == "kB" && "$setting" -lt 4096 ]]; then
                    echo "  → RECOMMENDATION: Consider increasing for complex queries"
                fi
                ;;
            "max_connections")
                if [[ "$setting" -gt 200 ]]; then
                    echo "  → RECOMMENDATION: Consider connection pooling"
                fi
                ;;
        esac
    done < "$params_file"
    
    rm -f "$params_file"
}

# Generate recommendations
generate_recommendations() {
    log "Generating tuning recommendations..."
    
    local ram_bytes
    ram_bytes=$(detect_system_ram)
    
    if [[ "$ram_bytes" -gt 0 ]]; then
        local ram_gb=$((ram_bytes / 1024 / 1024 / 1024))
        log "Detected system RAM: ${ram_gb}GB"
    else
        warn "Could not detect system RAM - using provided value or defaults"
        [[ -n "$SYSTEM_RAM" ]] && ram_bytes=$(parse_ram_size "$SYSTEM_RAM")
    fi
    
    echo ""
    echo "PostgreSQL Tuning Recommendations"
    echo "================================="
    echo "Workload Type: $WORKLOAD_TYPE"
    echo "System RAM: $(( ram_bytes / 1024 / 1024 / 1024 ))GB (detected/provided)"
    echo ""
    
    echo "# Memory Settings"
    calculate_memory_settings "$ram_bytes" "$WORKLOAD_TYPE"
    echo ""
    
    echo "# Performance Settings"
    calculate_performance_settings "$WORKLOAD_TYPE"
    echo ""
    
    echo "# Additional Recommendations for $WORKLOAD_TYPE workload:"
    case "$WORKLOAD_TYPE" in
        oltp)
            echo "# - Enable connection pooling (PgBouncer recommended)"
            echo "# - Monitor for lock contention"
            echo "# - Consider smaller checkpoint intervals"
            echo "# - Tune autovacuum for high update frequency"
            ;;
        olap)
            echo "# - Enable parallel query execution"
            echo "# - Increase statistics targets for better plans"
            echo "# - Consider larger work_mem for complex queries"
            echo "# - Monitor temp file usage"
            ;;
        web)
            echo "# - Implement robust connection pooling"
            echo "# - Monitor connection usage patterns"
            echo "# - Optimize frequently executed queries"
            echo "# - Consider read replicas for scaling"
            ;;
    esac
    
    echo ""
    echo "# IMPORTANT NOTES:"
    echo "# - Always test changes in non-production first"
    echo "# - Monitor performance after applying changes"
    echo "# - Adjust based on actual workload patterns"
    echo "# - Consider hardware characteristics (SSD vs HDD)"
}

# Generate configuration file
generate_config_file() {
    local output_file="$1"
    
    log "Generating PostgreSQL configuration snippet..."
    
    local ram_bytes
    ram_bytes=$(detect_system_ram)
    [[ -n "$SYSTEM_RAM" ]] && ram_bytes=$(parse_ram_size "$SYSTEM_RAM")
    
    {
        echo "# PostgreSQL Configuration Snippet"
        echo "# Generated by pgtools parameter_tuner.sh"
        echo "# Date: $(date)"
        echo "# Workload: $WORKLOAD_TYPE"
        echo "# RAM: $(( ram_bytes / 1024 / 1024 / 1024 ))GB"
        echo ""
        echo "# Memory Settings"
        calculate_memory_settings "$ram_bytes" "$WORKLOAD_TYPE"
        echo ""
        echo "# Performance Settings"
        calculate_performance_settings "$WORKLOAD_TYPE"
        echo ""
        echo "# Logging (recommended for monitoring)"
        echo "log_min_duration_statement = 1000  # Log queries slower than 1 second"
        echo "log_checkpoints = on"
        echo "log_lock_waits = on"
        echo "log_temp_files = 10MB"
        echo ""
        echo "# Monitoring (if extensions available)"
        echo "shared_preload_libraries = 'pg_stat_statements'"
        echo "pg_stat_statements.track = all"
    } > "$output_file"
    
    success "Configuration snippet written to: $output_file"
}

# Apply configuration changes (dangerous!)
apply_configuration() {
    if [[ "$APPLY_CHANGES" != "true" ]]; then
        return 0
    fi
    
    error "APPLY MODE IS NOT IMPLEMENTED FOR SAFETY"
    error "To apply changes:"
    error "1. Generate config with --mode generate"
    error "2. Review the generated configuration carefully"  
    error "3. Manually add settings to postgresql.conf"
    error "4. Restart PostgreSQL"
    error "5. Monitor performance"
    
    return 1
}

# Main execution
main() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "PostgreSQL Parameter Tuner"
        log "Mode: $MODE"
        log "Workload: $WORKLOAD_TYPE"
        [[ -n "$SYSTEM_RAM" ]] && log "RAM: $SYSTEM_RAM"
    fi
    
    case "$MODE" in
        "analyze")
            analyze_configuration
            ;;
        "recommend")
            if [[ -n "$OUTPUT_FILE" ]]; then
                generate_recommendations > "$OUTPUT_FILE"
                success "Recommendations written to: $OUTPUT_FILE"
            else
                generate_recommendations
            fi
            ;;
        "generate")
            if [[ -z "$OUTPUT_FILE" ]]; then
                OUTPUT_FILE="postgresql_tuned.conf"
            fi
            generate_config_file "$OUTPUT_FILE"
            ;;
    esac
    
    apply_configuration
}

main "$@"