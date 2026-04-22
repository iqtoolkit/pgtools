#!/bin/bash
# precommit_checks.sh
# Local helper to mirror CI validation (shell lint + automation smoke tests)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME="${PGDATABASE:-postgres}"

declare -a CLEANUP_FILES=()

usage() {
    cat <<'EOF'
Usage: scripts/precommit_checks.sh [--database DB]

Runs:
  1. shellcheck automation/*.sh
  2. ./automation/test_pgtools.sh --fast
  3. ./automation/run_hot_update_report.sh --format json (temp file)
  4. ./automation/run_hot_update_report.sh --format text (temp file)

If --database is not supplied, PGDATABASE (or "postgres") is used.
Standard libpq environment variables (PGHOST, PGPORT, PGUSER, PGPASSWORD)
are honored so you can point at staging or local instances easily.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database)
            DB_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

info() { echo "[precommit] $*"; }
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT

cd "$REPO_ROOT"

info "Running shellcheck on all shell scripts (matches CI coverage)"
shellcheck \
    automation/*.sh \
    integration/*.sh \
    configuration/*.sh \
    maintenance/*.sh \
    scripts/*.sh

info "Running automation fast test suite"
./automation/test_pgtools.sh --fast

JSON_TMP="$(mktemp -t hot_json.XXXXXX)"
CLEANUP_FILES+=("$JSON_TMP")
info "Validating HOT checklist JSON path (database: $DB_NAME)"
./automation/run_hot_update_report.sh --format json --database "$DB_NAME" --output "$JSON_TMP" --quiet > /dev/null

TEXT_TMP="$(mktemp -t hot_text.XXXXXX)"
CLEANUP_FILES+=("$TEXT_TMP")
info "Validating HOT checklist text path (database: $DB_NAME)"
./automation/run_hot_update_report.sh --format text --database "$DB_NAME" --output "$TEXT_TMP" --quiet > /dev/null

info "All pre-commit checks passed"
