#!/bin/bash
#
# Script: prometheus_exporter.sh
# Purpose: Custom PostgreSQL metrics exporter for Prometheus
# Usage: ./integration/prometheus_exporter.sh [OPTIONS]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
PORT="9187"
BIND_ADDRESS="0.0.0.0"
METRICS_PATH="/metrics"
CONFIG_FILE="$SCRIPT_DIR/prometheus_config.yml"
DAEMON_MODE="false"
PID_FILE="/tmp/pgtools_prometheus_exporter.pid"

usage() {
    cat << EOF
PostgreSQL Prometheus Metrics Exporter

Usage: $0 [OPTIONS]

OPTIONS:
    -p, --port PORT         Port to bind to (default: 9187)
    -b, --bind ADDRESS      Address to bind to (default: 0.0.0.0)
    -m, --path PATH         Metrics endpoint path (default: /metrics)
    -c, --config FILE       Configuration file (default: prometheus_config.yml)
    -d, --daemon            Run as daemon
    --stop                  Stop daemon if running
    --status                Show daemon status
    -h, --help              Show this help

EXAMPLES:
    $0                                  # Start on default port 9187
    $0 --port 9188 --bind 127.0.0.1   # Custom port and bind address
    $0 --daemon                        # Run as background daemon
    $0 --stop                          # Stop running daemon
    $0 --status                        # Check daemon status

METRICS ENDPOINT:
    Once running, metrics will be available at:
    http://\$BIND_ADDRESS:\$PORT\$METRICS_PATH

CONFIGURATION:
    Create prometheus_config.yml to customize database connection and metrics.

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -b|--bind)
            BIND_ADDRESS="$2"
            shift 2
            ;;
        -m|--path)
            METRICS_PATH="$2"
            shift 2
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -d|--daemon)
            DAEMON_MODE="true"
            shift
            ;;
        --stop)
            stop_daemon
            exit 0
            ;;
        --status)
            show_status
            exit 0
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

# Stop daemon function
stop_daemon() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PID_FILE"
            success "Stopped PostgreSQL Prometheus exporter (PID: $pid)"
        else
            warn "PID file exists but process not running"
            rm -f "$PID_FILE"
        fi
    else
        warn "No PID file found - exporter may not be running"
    fi
}

# Show daemon status
show_status() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            success "PostgreSQL Prometheus exporter is running (PID: $pid, Port: $PORT)"
        else
            error "PID file exists but process not running"
        fi
    else
        warn "PostgreSQL Prometheus exporter is not running"
    fi
}

# Generate Prometheus metrics
generate_metrics() {
    cat << 'EOF'
# HELP pg_up Whether the PostgreSQL server is up
# TYPE pg_up gauge
EOF
    
    # Test database connection
    if psql -c "SELECT 1" > /dev/null 2>&1; then
        echo "pg_up 1"
    else
        echo "pg_up 0"
        return
    fi
    
    # Database statistics
    cat << 'EOF'
# HELP pg_stat_database_numbackends Number of backends currently connected to this database
# TYPE pg_stat_database_numbackends gauge
# HELP pg_stat_database_xact_commit Number of transactions in this database that have been committed
# TYPE pg_stat_database_xact_commit counter
# HELP pg_stat_database_xact_rollback Number of transactions in this database that have been rolled back
# TYPE pg_stat_database_xact_rollback counter
# HELP pg_stat_database_blks_read Number of disk blocks read in this database
# TYPE pg_stat_database_blks_read counter
# HELP pg_stat_database_blks_hit Number of times disk blocks were found already in the buffer cache
# TYPE pg_stat_database_blks_hit counter
# HELP pg_stat_database_tup_returned Number of rows returned by queries in this database
# TYPE pg_stat_database_tup_returned counter
# HELP pg_stat_database_tup_fetched Number of rows fetched by queries in this database
# TYPE pg_stat_database_tup_fetched counter
# HELP pg_stat_database_tup_inserted Number of rows inserted by queries in this database
# TYPE pg_stat_database_tup_inserted counter
# HELP pg_stat_database_tup_updated Number of rows updated by queries in this database
# TYPE pg_stat_database_tup_updated counter
# HELP pg_stat_database_tup_deleted Number of rows deleted by queries in this database
# TYPE pg_stat_database_tup_deleted counter
EOF
    
    psql -t -c "
    SELECT 
        'pg_stat_database_numbackends{datname=\"' || datname || '\"} ' || numbackends,
        'pg_stat_database_xact_commit{datname=\"' || datname || '\"} ' || xact_commit,
        'pg_stat_database_xact_rollback{datname=\"' || datname || '\"} ' || xact_rollback,
        'pg_stat_database_blks_read{datname=\"' || datname || '\"} ' || blks_read,
        'pg_stat_database_blks_hit{datname=\"' || datname || '\"} ' || blks_hit,
        'pg_stat_database_tup_returned{datname=\"' || datname || '\"} ' || tup_returned,
        'pg_stat_database_tup_fetched{datname=\"' || datname || '\"} ' || tup_fetched,
        'pg_stat_database_tup_inserted{datname=\"' || datname || '\"} ' || tup_inserted,
        'pg_stat_database_tup_updated{datname=\"' || datname || '\"} ' || tup_updated,
        'pg_stat_database_tup_deleted{datname=\"' || datname || '\"} ' || tup_deleted
    FROM pg_stat_database
    WHERE datname IS NOT NULL
    " | tr '|' '\n' | grep -v '^[[:space:]]*$'
    
    # Connection statistics
    cat << 'EOF'
# HELP pg_stat_activity_connections Number of connections by state
# TYPE pg_stat_activity_connections gauge
EOF
    
    psql -t -c "
    SELECT 'pg_stat_activity_connections{state=\"' || COALESCE(state, 'unknown') || '\"} ' || count(*)
    FROM pg_stat_activity
    GROUP BY state
    " | grep -v '^[[:space:]]*$'
    
    # Background writer statistics
    cat << 'EOF'
# HELP pg_stat_bgwriter_checkpoints_timed Number of scheduled checkpoints that have been performed
# TYPE pg_stat_bgwriter_checkpoints_timed counter
# HELP pg_stat_bgwriter_checkpoints_req Number of requested checkpoints that have been performed
# TYPE pg_stat_bgwriter_checkpoints_req counter
# HELP pg_stat_bgwriter_checkpoint_write_time Total amount of time spent in the portion of checkpoint processing where files are written to disk
# TYPE pg_stat_bgwriter_checkpoint_write_time counter
# HELP pg_stat_bgwriter_checkpoint_sync_time Total amount of time spent in the portion of checkpoint processing where files are synchronized to disk
# TYPE pg_stat_bgwriter_checkpoint_sync_time counter
# HELP pg_stat_bgwriter_buffers_checkpoint Number of buffers written during checkpoints
# TYPE pg_stat_bgwriter_buffers_checkpoint counter
# HELP pg_stat_bgwriter_buffers_clean Number of buffers written by the background writer
# TYPE pg_stat_bgwriter_buffers_clean counter
# HELP pg_stat_bgwriter_buffers_backend Number of buffers written directly by a backend
# TYPE pg_stat_bgwriter_buffers_backend counter
EOF
    
    psql -t -c "
    SELECT 
        'pg_stat_bgwriter_checkpoints_timed ' || checkpoints_timed,
        'pg_stat_bgwriter_checkpoints_req ' || checkpoints_req,
        'pg_stat_bgwriter_checkpoint_write_time ' || checkpoint_write_time,
        'pg_stat_bgwriter_checkpoint_sync_time ' || checkpoint_sync_time,
        'pg_stat_bgwriter_buffers_checkpoint ' || buffers_checkpoint,
        'pg_stat_bgwriter_buffers_clean ' || buffers_clean,
        'pg_stat_bgwriter_buffers_backend ' || buffers_backend
    FROM pg_stat_bgwriter
    " | tr '|' '\n' | grep -v '^[[:space:]]*$'
    
    # Lock statistics
    cat << 'EOF'
# HELP pg_locks_count Number of locks by mode
# TYPE pg_locks_count gauge
EOF
    
    psql -t -c "
    SELECT 'pg_locks_count{mode=\"' || mode || '\"} ' || count(*)
    FROM pg_locks
    GROUP BY mode
    " | grep -v '^[[:space:]]*$'
    
    # Table size metrics (top 20 tables)
    cat << 'EOF'
# HELP pg_table_size_bytes Size of table in bytes
# TYPE pg_table_size_bytes gauge
EOF
    
    psql -t -c "
    SELECT 'pg_table_size_bytes{schema=\"' || schemaname || '\",table=\"' || tablename || '\"} ' || 
           pg_total_relation_size(schemaname||'.'||tablename)
    FROM pg_tables 
    WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
    LIMIT 20
    " | grep -v '^[[:space:]]*$'
    
    # Replication lag (if applicable)
    cat << 'EOF'
# HELP pg_replication_lag_seconds Replication lag in seconds
# TYPE pg_replication_lag_seconds gauge
EOF
    
    psql -t -c "
    SELECT 'pg_replication_lag_seconds{client_addr=\"' || client_addr || '\",application_name=\"' || application_name || '\"} ' || 
           EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))
    FROM pg_stat_replication
    WHERE pg_is_in_recovery() = false
    " 2>/dev/null | grep -v '^[[:space:]]*$' || true
    
    # Query statistics (if pg_stat_statements available)
    if psql -c "SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'" > /dev/null 2>&1; then
        cat << 'EOF'
# HELP pg_stat_statements_calls_total Number of times executed
# TYPE pg_stat_statements_calls_total counter
# HELP pg_stat_statements_total_time_seconds Total time spent in the statement
# TYPE pg_stat_statements_total_time_seconds counter
# HELP pg_stat_statements_mean_time_seconds Mean time spent in the statement
# TYPE pg_stat_statements_mean_time_seconds gauge
EOF
        
        psql -t -c "
        SELECT 
            'pg_stat_statements_calls_total{queryid=\"' || queryid || '\"} ' || calls,
            'pg_stat_statements_total_time_seconds{queryid=\"' || queryid || '\"} ' || total_exec_time/1000,
            'pg_stat_statements_mean_time_seconds{queryid=\"' || queryid || '\"} ' || mean_exec_time/1000
        FROM pg_stat_statements
        WHERE calls > 100  -- Only include frequently executed queries
        ORDER BY total_exec_time DESC
        LIMIT 50
        " 2>/dev/null | tr '|' '\n' | grep -v '^[[:space:]]*$' || true
    fi
}

# HTTP server implementation
run_http_server() {
    log "Starting PostgreSQL Prometheus exporter on $BIND_ADDRESS:$PORT"
    log "Metrics endpoint: http://$BIND_ADDRESS:$PORT$METRICS_PATH"
    
    # Simple HTTP server using netcat or socat
    if command -v socat > /dev/null 2>&1; then
        run_socat_server
    elif command -v nc > /dev/null 2>&1; then
        run_netcat_server
    else
        error "Neither socat nor netcat available - cannot start HTTP server"
        return 1
    fi
}

# HTTP server using socat
run_socat_server() {
    while true; do
        {
            echo "HTTP/1.1 200 OK"
            echo "Content-Type: text/plain; version=0.0.4; charset=utf-8"
            echo "Connection: close"
            echo ""
            generate_metrics
        } | socat TCP-LISTEN:"$PORT",bind="$BIND_ADDRESS",reuseaddr,fork STDIO
    done
}

# HTTP server using netcat (basic implementation)
run_netcat_server() {
    local temp_response
    temp_response=$(mktemp)
    
    while true; do
        {
            echo "HTTP/1.1 200 OK"
            echo "Content-Type: text/plain; version=0.0.4; charset=utf-8"
            echo "Connection: close"
            echo ""
            generate_metrics
        } > "$temp_response"
        
        nc -l -p "$PORT" < "$temp_response" > /dev/null 2>&1 || {
            sleep 1
            continue
        }
    done
    
    rm -f "$temp_response"
}

# Test database connection
test_connection() {
    log "Testing database connection..."
    
    if psql -c "SELECT version();" > /dev/null 2>&1; then
        success "Database connection successful"
        local version
        version=$(psql -t -c "SELECT version();" | xargs)
        log "PostgreSQL version: $version"
    else
        error "Cannot connect to PostgreSQL database"
        error "Check connection parameters: PGHOST, PGPORT, PGDATABASE, PGUSER"
        return 1
    fi
}

# Create configuration file template
create_config_template() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << 'EOF'
# PostgreSQL Prometheus Exporter Configuration
# This file is currently not used but reserved for future enhancements

database:
  host: localhost
  port: 5432
  user: postgres
  database: postgres
  # password: # Use .pgpass or PGPASSWORD environment variable

metrics:
  # Custom metrics queries can be added here in future versions
  custom_queries: []

server:
  bind_address: 0.0.0.0
  port: 9187
  metrics_path: /metrics

EOF
        log "Created configuration template: $CONFIG_FILE"
    fi
}

# Main execution
main() {
    # Create config template if it doesn't exist
    create_config_template
    
    # Test database connection
    test_connection || exit 1
    
    if [[ "$DAEMON_MODE" == "true" ]]; then
        if [[ -f "$PID_FILE" ]]; then
            local existing_pid
            existing_pid=$(cat "$PID_FILE")
            if kill -0 "$existing_pid" 2>/dev/null; then
                error "Exporter already running with PID: $existing_pid"
                exit 1
            else
                rm -f "$PID_FILE"
            fi
        fi
        
        # Start as daemon
        nohup "$0" -p "$PORT" -b "$BIND_ADDRESS" -m "$METRICS_PATH" > /dev/null 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        success "Started PostgreSQL Prometheus exporter as daemon (PID: $pid)"
        log "Metrics available at: http://$BIND_ADDRESS:$PORT$METRICS_PATH"
        log "Use '$0 --stop' to stop the daemon"
    else
        # Check if we're being run as the daemon process
        if [[ -f "$PID_FILE" ]] && [[ "$$" == "$(cat "$PID_FILE")" ]]; then
            trap 'rm -f "$PID_FILE"; exit' INT TERM
        fi
        
        run_http_server
    fi
}

main "$@"