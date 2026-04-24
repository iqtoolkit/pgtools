#!/bin/bash
#
# Script: pgtools.sh
# Purpose: Master CLI for the pgtools "First Responder" Support Toolbelt.
#          Provides a safe, read-only interface for diagnosing customer
#          PostgreSQL and TimescaleDB instances.
#
# Author: Giovanni Martinez <gmartinez@tigerdata.com>
# Version: 2.0
#

set -euo pipefail

# --- Configuration ---

# Safety timeouts applied to every SQL execution.
STATEMENT_TIMEOUT="5s"
LOCK_TIMEOUT="3s"

# Base directory where SQL scripts are located.
# Assumes a structure like:
# ./
# ├── pgtools.sh
# └── sql/
#     ├── diagnostics/
#     └── timescale/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"

# psql display options for clean, ticket-ready output.
PSQL_OPTS=(
    -X # Do not read psqlrc
    -P "border=2"
    -P "linestyle=unicode"
    -P "footer=off"
    --quiet
)

# Color codes for output
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}INFO:${NC} $*"; }
error() { echo -e "${RED}ERROR:${NC} $*" >&2; }

# --- Helper Functions ---

usage() {
    cat <<EOF
pgtools: "First Responder" Support Toolbelt for PostgreSQL & TimescaleDB

Usage:
  ./pgtools.sh <command> [connection_string]

Description:
  A collection of safe, read-only diagnostic scripts for support engineers
  to quickly assess PostgreSQL and TimescaleDB instances.
  All queries run with a ${STATEMENT_TIMEOUT} statement timeout and ${LOCK_TIMEOUT} lock timeout
  to ensure minimal impact on customer systems.

Commands:
  # General Diagnostics
  locks             Show current lock contention and blocking queries. (sql/diagnostics/locks.sql)
  activity          Display current query activity from pg_stat_activity. (sql/diagnostics/activity.sql)
  top-queries       Show most time-consuming queries (requires pg_stat_statements). (sql/diagnostics/top-queries.sql)
  bloat             Identify table and index bloat. (sql/diagnostics/bloat.sql)
  replication       Monitor replication lag and status. (sql/diagnostics/replication.sql)
  disk-usage        Show disk usage by table and index. (sql/diagnostics/disk-usage.sql)
  cache-hit         Show table and index cache hit rates. (sql/diagnostics/cache-hit.sql)

  # TimescaleDB Diagnostics
  chunk-stats       Show chunk count and size per hypertable. (sql/timescale/chunk-stats.sql)
  compression-stats Show compression ratio and job status per hypertable. (sql/timescale/compression-stats.sql)
  cagg-stats        Show continuous aggregate health and refresh policy status. (sql/timescale/cagg-stats.sql)
  job-errors        Show recent errors from background jobs. (sql/timescale/job-errors.sql)
  uncompressed-chunks Show chunks that are old but not compressed. (sql/timescale/uncompressed-chunks.sql)

  # Administration
  permissions       Audit user and role permissions. (sql/admin/permissions.sql)
  ownership         Display table and object ownership. (sql/admin/ownership.sql)

Example:
  ./pgtools.sh locks "postgresql://user:pass@host:port/dbname"
  ./pgtools.sh chunk-stats "service=my_customer_db"

EOF
    exit 1
}

run_sql() {
    local command_name="$1"
    local conn_string="$2"
    local sql_file_path

    # This logic can be expanded to find files in different subdirectories.
    if [[ -f "${SQL_DIR}/timescale/${command_name}.sql" ]]; then
        sql_file_path="${SQL_DIR}/timescale/${command_name}.sql"
    elif [[ -f "${SQL_DIR}/diagnostics/${command_name}.sql" ]]; then
        sql_file_path="${SQL_DIR}/diagnostics/${command_name}.sql"
    elif [[ -f "${SQL_DIR}/admin/${command_name}.sql" ]]; then
        sql_file_path="${SQL_DIR}/admin/${command_name}.sql"
    else
        error "Unknown command or SQL file not found for: ${command_name}"
        exit 1
    fi

    log "Running: ${command_name} on target database..."
    log "SQL file: ${sql_file_path}"

    # Prepend safety timeouts to the SQL script for execution.
    psql "${PSQL_OPTS[@]}" -d "${conn_string}" \
        -c "SET statement_timeout = '${STATEMENT_TIMEOUT}';" \
        -c "SET lock_timeout = '${LOCK_TIMEOUT}';" \
        -f "${sql_file_path}"
}

# --- Main Execution ---

main() {
    if [[ $# -lt 2 ]]; then
        usage
    fi

    local command="$1"
    local connection_string="$2"

    case "${command}" in
        locks|activity|top-queries|bloat|replication|disk-usage|cache-hit|chunk-stats|compression-stats|cagg-stats|job-errors|uncompressed-chunks|permissions|ownership)
            run_sql "${command}" "${connection_string}"
            ;;
        *)
            error "Unknown command: ${command}"
            usage
            ;;
    esac
}

main "$@"
