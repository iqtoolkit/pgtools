#!/bin/bash
#
# Script: cleanup_reports.sh
# Purpose: Clean up old pgtools reports and logs
# Usage: ./automation/cleanup_reports.sh [OPTIONS]
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
KEEP_DAYS=30
DRY_RUN="false"
VERBOSE="false"
COMPRESS_OLD="true"

# Load configuration
CONFIG_FILE="$SCRIPT_DIR/pgtools.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1091
    # shellcheck source=pgtools.conf
    source "$CONFIG_FILE"
    KEEP_DAYS="${PGTOOLS_KEEP_REPORTS_DAYS:-$KEEP_DAYS}"
fi

usage() {
    cat << EOF
PostgreSQL Tools Report Cleanup

Usage: $0 [OPTIONS]

OPTIONS:
    -d, --days DAYS         Days to keep reports (default: $KEEP_DAYS)
    -n, --dry-run           Show what would be deleted without deleting
    -v, --verbose           Verbose output
    --no-compress           Don't compress old files before deletion
    -h, --help              Show this help

EXAMPLES:
    $0                      # Clean reports older than $KEEP_DAYS days
    $0 --days 7 --dry-run   # Show what would be deleted (7 days)
    $0 --verbose            # Detailed cleanup output

DIRECTORIES CLEANED:
    - $SCRIPT_DIR/reports/
    - $SCRIPT_DIR/logs/
    - /tmp/pgtools_*
    - $PGTOOLS_ROOT/*/reports/ (if they exist)

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--days)
            KEEP_DAYS="$2"
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
        --no-compress)
            COMPRESS_OLD="false"
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

# Validate days parameter
if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || [[ "$KEEP_DAYS" -lt 1 ]]; then
    error "Invalid days value: $KEEP_DAYS"
    exit 1
fi

# Create reports directory if it doesn't exist
ensure_directories() {
    local reports_dir="$SCRIPT_DIR/reports"
    local logs_dir="$SCRIPT_DIR/logs"
    
    if [[ ! -d "$reports_dir" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            mkdir -p "$reports_dir"
            log "Created reports directory: $reports_dir"
        fi
    fi
    
    if [[ ! -d "$logs_dir" ]]; then
        if [[ "$DRY_RUN" == "false" ]]; then
            mkdir -p "$logs_dir"
            log "Created logs directory: $logs_dir"
        fi
    fi
}

# Compress old files before deletion
compress_old_files() {
    local directory="$1"
    local days="$2"
    
    if [[ "$COMPRESS_OLD" != "true" ]] || [[ ! -d "$directory" ]]; then
        return 0
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        log "Compressing files older than $days days in $directory"
    fi
    
    # Find files older than KEEP_DAYS but newer than KEEP_DAYS+7 to compress first
    local compress_days=$((days + 7))
    
    while IFS= read -r -d '' file; do
        if [[ "$file" =~ \.(gz|bz2|xz)$ ]]; then
            continue  # Skip already compressed files
        fi
        
        local compressed_file="$file.gz"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "Would compress: $file -> $compressed_file"
        else
            if gzip "$file" 2>/dev/null; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log "Compressed: $(basename "$file")"
                fi
            else
                warn "Failed to compress: $file"
            fi
        fi
    done < <(find "$directory" -type f -mtime +"$days" -mtime -"$compress_days" -print0 2>/dev/null)
}

# Clean directory
clean_directory() {
    local directory="$1"
    local description="$2"
    
    if [[ ! -d "$directory" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            warn "$description directory not found: $directory"
        fi
        return 0
    fi
    
    log "Cleaning $description (keeping $KEEP_DAYS days): $directory"
    
    # Compress old files first
    compress_old_files "$directory" "$KEEP_DAYS"
    
    # Count files to be deleted
    local file_count=0
    local total_size=0
    
    while IFS= read -r -d '' file; do
        file_count=$((file_count + 1))
        if command -v stat > /dev/null 2>&1; then
            local size
            size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
            total_size=$((total_size + size))
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "Would delete: $file"
        else
            if rm -f "$file"; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log "Deleted: $(basename "$file")"
                fi
            else
                warn "Failed to delete: $file"
            fi
        fi
    done < <(find "$directory" -type f -mtime +"$KEEP_DAYS" -print0 2>/dev/null)
    
    if [[ "$file_count" -gt 0 ]]; then
        local size_mb=$((total_size / 1024 / 1024))
        if [[ "$DRY_RUN" == "true" ]]; then
            log "Would delete $file_count files (${size_mb}MB) from $description"
        else
            success "Deleted $file_count files (${size_mb}MB) from $description"
        fi
    else
        if [[ "$VERBOSE" == "true" ]]; then
            log "No old files found in $description"
        fi
    fi
}

# Clean temporary files
clean_temp_files() {
    log "Cleaning temporary pgtools files"
    
    local temp_pattern="/tmp/pgtools_*"
    local file_count=0
    
    for file in $temp_pattern; do
        if [[ -e "$file" ]] && [[ -f "$file" ]]; then
            # Check if file is older than 1 day
            if [[ $(find "$file" -mtime +1 2>/dev/null) ]]; then
                file_count=$((file_count + 1))
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo "Would delete temp file: $file"
                else
                    rm -f "$file"
                    if [[ "$VERBOSE" == "true" ]]; then
                        log "Deleted temp file: $(basename "$file")"
                    fi
                fi
            fi
        fi
    done
    
    if [[ "$file_count" -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log "Would delete $file_count temporary files"
        else
            success "Deleted $file_count temporary files"
        fi
    else
        if [[ "$VERBOSE" == "true" ]]; then
            log "No old temporary files found"
        fi
    fi
}

# Clean old cron logs
clean_cron_logs() {
    local cron_log="$SCRIPT_DIR/cron.log"
    
    if [[ ! -f "$cron_log" ]]; then
        return 0
    fi
    
    # Keep only last 1000 lines of cron log
    if [[ "$DRY_RUN" == "true" ]]; then
        local current_lines
        current_lines=$(wc -l < "$cron_log")
        if [[ "$current_lines" -gt 1000 ]]; then
            log "Would truncate cron.log (currently $current_lines lines)"
        fi
    else
        local temp_log
        temp_log=$(mktemp)
        tail -1000 "$cron_log" > "$temp_log" && mv "$temp_log" "$cron_log"
        if [[ "$VERBOSE" == "true" ]]; then
            log "Truncated cron.log to last 1000 lines"
        fi
    fi
}

# Main cleanup function
main() {
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN MODE - No files will be deleted"
    fi
    
    log "Starting pgtools cleanup (keeping $KEEP_DAYS days)"
    
    ensure_directories
    
    # Clean main directories
    clean_directory "$SCRIPT_DIR/reports" "reports"
    clean_directory "$SCRIPT_DIR/logs" "logs"
    
    # Clean subdirectory reports (if they exist)
    for subdir in backup monitoring security optimization administration; do
        local subdir_reports="$PGTOOLS_ROOT/$subdir/reports"
        if [[ -d "$subdir_reports" ]]; then
            clean_directory "$subdir_reports" "$subdir reports"
        fi
    done
    
    # Clean temporary files
    clean_temp_files
    
    # Clean cron logs
    clean_cron_logs
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry run completed - no files were deleted"
    else
        success "Cleanup completed successfully"
    fi
}

main "$@"