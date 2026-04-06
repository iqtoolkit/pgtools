# pgtools — Implementation Plan (A+ Roadmap)

## Goal

Elevate pgtools from a well-documented script library to a production-grade, installable tool with a stable test suite, integration coverage, a proper CLI, and a repeatable release process.

---

## Phase 1 — Fix and Re-Enable the CI Test Suite

**Goal**: Green CI by repairing the existing commented-out steps. No new test framework yet.

### Root Causes to Fix

1. `psql --dry-run` does not exist. `test_sql_syntax()` in `automation/test_pgtools.sh` falls through to `psql -c "\\i $sql_file"`, which also fails — `\i` is a psql meta-command, not valid inside `-c`.
2. ShellCheck only covers `automation/*.sh`. The `integration/`, `configuration/`, and `maintenance/` shell scripts are unlinted.
3. Three CI steps are commented out with `# TODO: enable full test suite when stable`.
4. Division-by-zero bug in `test_pgtools.sh` line ~308: `$(( TESTS_PASSED * 100 / TESTS_RUN ))` when `TESTS_RUN=0`.

### Changes Required

**`automation/test_pgtools.sh`**
- Rewrite `test_sql_syntax()`: replace `--dry-run` + `\i` fallback with `psql -v ON_ERROR_STOP=1 -f "$sql_file" > /dev/null 2>&1`
- Add `SKIP_SUPERUSER_SCRIPTS` guard: check `SELECT current_setting('is_superuser')` before running `permission_audit.sql` and `switch_pg_wal_file.sql`
- Add `SKIP_EXTENSION_SCRIPTS` guard: check `pg_available_extensions` before running scripts that require `pg_stat_statements` or `pg_buffercache`
- Expand tested file list from 5 to full SQL corpus (32 files)
- Fix division-by-zero: guard with `[[ $TESTS_RUN -gt 0 ]]` before computing percentage

**`.github/workflows/ci.yml`**
- Uncomment the three disabled test steps
- Extend ShellCheck to cover all shell scripts: `shellcheck automation/*.sh integration/*.sh configuration/*.sh maintenance/*.sh`
- Add post-startup step to enable `pg_stat_statements`: `psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"`
- Add steps:
  ```yaml
  - name: Enable pg_stat_statements
    run: psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

  - name: ShellCheck all scripts
    run: shellcheck automation/*.sh integration/*.sh configuration/*.sh maintenance/*.sh

  - name: Fast automation test suite
    run: ./automation/test_pgtools.sh --fast

  - name: HOT checklist JSON validation
    run: ./automation/run_hot_update_report.sh --format json --database "$PGDATABASE" --stdout

  - name: HOT checklist text validation
    run: ./automation/run_hot_update_report.sh --format text --database "$PGDATABASE" --stdout
  ```

### Acceptance Criteria
- [ ] `ci.yml` has no commented-out steps
- [ ] All ShellCheck steps pass (zero warnings on all 12 `.sh` files)
- [ ] `./automation/test_pgtools.sh --fast` exits 0 in CI
- [ ] Both HOT report steps produce output and exit 0
- [ ] No `--dry-run` flag passed to psql anywhere in the codebase

---

## Phase 2 — BATS Integration Tests Against Live PostgreSQL

**Goal**: A proper test suite that verifies each SQL script category executes correctly against a real database. Uses [BATS](https://github.com/bats-core/bats-core) for standard TAP output and native GitHub Actions summary support.

### New Files to Create

**`tests/helpers/pg_helpers.bash`** — shared setup loaded by all test files via BATS `load`:
- `setup_pg_test_schema()` — creates test schema with known data (tables, dead tuples for bloat, foreign keys, dummy roles, sample statistics)
- `teardown_pg_test_schema()` — cleans up

**`tests/sql/test_monitoring.bats`** — one `@test` per monitoring SQL file (all 7 scripts):
```bash
@test "locks.sql executes without error" {
    run psql -v ON_ERROR_STOP=1 -f "$PGTOOLS_ROOT/monitoring/locks.sql"
    [ "$status" -eq 0 ]
}
```

**`tests/sql/test_administration.bats`** — covers `administration/*.sql` (5 scripts). TimescaleDB-specific script gets: `skip "TimescaleDB not available"`.

**`tests/sql/test_optimization.bats`** — covers `optimization/` (3 scripts including HOT JSON variant).

**`tests/sql/test_performance.bats`** — covers `performance/*.sql`. Each test guards on `pg_stat_statements`:
```bash
if ! psql -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements'" | grep -q 1; then
  skip "pg_stat_statements not installed"
fi
```

**`tests/sql/test_security.bats`** — `permission_audit.sql` runs as the `postgres` superuser in CI.

**`tests/sql/test_maintenance.bats`** — covers `maintenance/*.sql`; `switch_pg_wal_file.sql` skipped in CI.

**`tests/sql/test_backup.bats`** — covers `backup/backup_validation.sql`.

**`tests/sql/test_configuration.bats`** — covers `configuration/configuration_analysis.sql` and `export_all_settings.sql`.

**`tests/sql/test_troubleshooting.bats`** — covers all 4 diagnostic query packs.

**`tests/shell/test_automation.bats`** — tests shell scripts:
```bash
@test "run_hot_update_report.sh --format json succeeds" {
    run ./automation/run_hot_update_report.sh --format json --database "$PGDATABASE" --stdout
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
}
@test "pgtools_health_check.sh --dry-run --quick succeeds" { ... }
```

**`tests/README.md`** — how to run tests locally and what each file covers.

### Changes to Existing Files

**`.github/workflows/ci.yml`** — add after existing fast suite:
```yaml
- name: Install BATS
  run: |
    git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
    sudo /tmp/bats-core/install.sh /usr/local

- name: Run BATS integration tests
  run: bats --tap tests/sql/ tests/shell/
```

**`scripts/precommit_checks.sh`** — add BATS block at the end:
```bash
if command -v bats >/dev/null 2>&1; then
    info "Running BATS tests"
    bats tests/sql/ tests/shell/
else
    warn "bats not installed; skipping integration tests (install: brew install bats-core)"
fi
```

### Coverage Matrix

| Category       | SQL files | Tested | Notes                              |
|----------------|-----------|--------|------------------------------------|
| monitoring     | 7         | 7      | All safe for any PG user           |
| administration | 5         | 4      | NonHypertables skipped (TimescaleDB)|
| optimization   | 3         | 3      | Including HOT JSON variant         |
| performance    | 3         | 3      | Skipped if pg_stat_statements absent|
| security       | 1         | 1      | Superuser in CI                    |
| maintenance    | 5         | 4      | switch_pg_wal_file skipped in CI   |
| backup         | 1         | 1      | Safe read-only queries             |
| configuration  | 2         | 2      | export_all_settings + analysis     |
| troubleshooting| 4         | 4      | All diagnostic query packs         |

### Acceptance Criteria
- [ ] `bats tests/` exits 0 in CI
- [ ] Individual test names appear in GitHub Actions run summary
- [ ] Each skip is documented with its reason
- [ ] Local contributors can `brew install bats-core && bats tests/` and get a pass on stock PG 15

---

## Phase 3 — CLI Entrypoint (`pgtools` dispatcher)

**Goal**: A single `pgtools <command>` interface so users don't need to know directory layout or file names.

### Design Decisions
- Single Bash dispatcher script — no compiled binary, no Python, no Node
- Finds SQL files relative to its own location using `SCRIPT_DIR` pattern already used across automation scripts
- Install via `curl | bash` (90% case for this audience) plus a Homebrew formula for macOS

### New Files to Create

**`bin/pgtools`** — the main dispatcher:
```bash
#!/bin/bash
set -euo pipefail

PGTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$PGTOOLS_ROOT/VERSION" 2>/dev/null || echo "dev")"

run_sql() {
    local sql_file="$1"; shift
    if [[ ! -f "$sql_file" ]]; then
        echo "pgtools: SQL file not found: $sql_file" >&2; exit 2
    fi
    exec psql -f "$sql_file" "$@"
}

CMD="${1:-help}"; shift || true

case "$CMD" in
    check-locks)       run_sql "$PGTOOLS_ROOT/monitoring/locks.sql" "$@" ;;
    check-bloat)       run_sql "$PGTOOLS_ROOT/monitoring/bloating.sql" "$@" ;;
    check-buffers)     run_sql "$PGTOOLS_ROOT/monitoring/buffer_troubleshoot.sql" "$@" ;;
    check-locking)     run_sql "$PGTOOLS_ROOT/monitoring/postgres_locking_blocking.sql" "$@" ;;
    check-replication) run_sql "$PGTOOLS_ROOT/monitoring/replication.sql" "$@" ;;
    check-txid)        run_sql "$PGTOOLS_ROOT/monitoring/txid.sql" "$@" ;;
    check-connections) run_sql "$PGTOOLS_ROOT/monitoring/connection_pools.sql" "$@" ;;
    hot-report)        run_sql "$PGTOOLS_ROOT/optimization/hot_update_optimization_checklist.sql" "$@" ;;
    hot-report-json)   run_sql "$PGTOOLS_ROOT/optimization/hot_update_optimization_checklist_json.sql" "$@" ;;
    missing-indexes)   run_sql "$PGTOOLS_ROOT/optimization/missing_indexes.sql" "$@" ;;
    list-extensions)   run_sql "$PGTOOLS_ROOT/administration/extensions.sql" "$@" ;;
    list-ownership)    run_sql "$PGTOOLS_ROOT/administration/table_ownership.sql" "$@" ;;
    list-foreign-keys) run_sql "$PGTOOLS_ROOT/administration/ForeignConst.sql" "$@" ;;
    partition-report)  run_sql "$PGTOOLS_ROOT/administration/partition_management.sql" "$@" ;;
    profile-queries)   run_sql "$PGTOOLS_ROOT/performance/query_performance_profiler.sql" "$@" ;;
    analyze-waits)     run_sql "$PGTOOLS_ROOT/performance/wait_event_analysis.sql" "$@" ;;
    check-resources)   run_sql "$PGTOOLS_ROOT/performance/resource_monitoring.sql" "$@" ;;
    permission-audit)  run_sql "$PGTOOLS_ROOT/security/permission_audit.sql" "$@" ;;
    schedule-report)   run_sql "$PGTOOLS_ROOT/maintenance/maintenance_scheduler.sql" "$@" ;;
    collect-stats)     run_sql "$PGTOOLS_ROOT/maintenance/statistics_collector.sql" "$@" ;;
    validate-backup)   run_sql "$PGTOOLS_ROOT/backup/backup_validation.sql" "$@" ;;
    analyze-config)    run_sql "$PGTOOLS_ROOT/configuration/configuration_analysis.sql" "$@" ;;
    version)           echo "pgtools $VERSION" ;;
    help|-h|--help)    usage ;;
    *)
        echo "pgtools: unknown command '$CMD'" >&2
        echo "Run 'pgtools help' for available commands." >&2
        exit 1
        ;;
esac
```

**`install.sh`** — install script:
```bash
#!/bin/bash
set -euo pipefail
PREFIX="${PREFIX:-/usr/local}"
REPO="https://github.com/thepostgresguy/pgtools"

if [[ -d "$PREFIX/share/pgtools" ]]; then
    git -C "$PREFIX/share/pgtools" pull --ff-only
else
    git clone --depth 1 "$REPO" "$PREFIX/share/pgtools"
fi

ln -sf "$PREFIX/share/pgtools/bin/pgtools" "$PREFIX/bin/pgtools"
chmod +x "$PREFIX/share/pgtools/bin/pgtools"
echo "pgtools installed. Run 'pgtools help' to get started."
```

**`Formula/pgtools.rb`** — Homebrew formula:
```ruby
class Pgtools < Formula
  desc "PostgreSQL administration toolkit"
  homepage "https://github.com/thepostgresguy/pgtools"
  url "https://github.com/thepostgresguy/pgtools/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "FILL_IN_ON_EACH_RELEASE"
  license "Apache-2.0"
  depends_on "libpq"

  def install
    prefix.install Dir["*"]
    bin.install "bin/pgtools"
  end

  test do
    system "#{bin}/pgtools", "version"
  end
end
```

**`VERSION`** — plain text file at repo root containing `1.1.0`.

### Changes to Existing Files

**`README.md`** — add Quick Install section near the top:
```bash
# Install via script
curl -fsSL https://raw.githubusercontent.com/thepostgresguy/pgtools/main/install.sh | bash

# Or Homebrew
brew install thepostgresguy/tap/pgtools

# Usage
pgtools check-locks -d mydb
pgtools check-bloat -d mydb -U admin
```

**`.github/workflows/ci.yml`** — add CLI smoke test:
```yaml
- name: CLI smoke test
  run: |
    export PATH="$PWD/bin:$PATH"
    pgtools version
    pgtools check-locks
    pgtools list-extensions
```

### Acceptance Criteria
- [ ] `pgtools help` lists all commands with categories
- [ ] `pgtools check-locks` runs correct SQL against `$PGDATABASE`
- [ ] Unknown commands exit 1 with a clear error message
- [ ] `pgtools version` prints version from `VERSION` file
- [ ] `install.sh` works on fresh Ubuntu and macOS
- [ ] All psql args pass through: `pgtools check-locks -d otherdb -U otherrole` works
- [ ] CLI smoke test passes in CI

---

## Phase 4 — Release Management

**Goal**: Versioned GitHub releases with artifacts, automated changelog handling, and a repeatable release process.

### Versioning Strategy
- Semantic versioning, single source of truth is `VERSION` file at repo root
- No version strings embedded inside scripts — they all read from `VERSION`
- First release under this plan: `1.1.0`

### New Files to Create

**`.github/workflows/release.yml`** — triggered by pushing a tag matching `v*`:
```yaml
name: Release
on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Validate tag matches VERSION
        run: |
          TAG="${GITHUB_REF_NAME#v}"
          VERSION="$(cat VERSION)"
          if [[ "$TAG" != "$VERSION" ]]; then
            echo "Tag $GITHUB_REF_NAME does not match VERSION ($VERSION)" >&2
            exit 1
          fi

      - name: Build artifacts
        run: |
          VERSION="$(cat VERSION)"
          git archive --format=tar.gz --prefix="pgtools-$VERSION/" HEAD > "pgtools-$VERSION.tar.gz"
          git archive --format=zip --prefix="pgtools-$VERSION/" HEAD > "pgtools-$VERSION.zip"
          sha256sum pgtools-*.tar.gz pgtools-*.zip > checksums.txt

      - name: Extract release notes
        run: |
          VERSION="$(cat VERSION)"
          awk "/^## \[$VERSION\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md > release_notes.md

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          body_path: release_notes.md
          files: |
            pgtools-*.tar.gz
            pgtools-*.zip
            checksums.txt
```

**`.github/workflows/changelog.yml`** — PR check that warns when SQL/shell files change but `CHANGELOG.md` is not updated:
```yaml
name: Changelog check
on:
  pull_request:
    paths: ["**/*.sql", "**/*.sh", "bin/pgtools"]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Check CHANGELOG updated
        run: |
          if ! git diff --name-only origin/main...HEAD | grep -q "CHANGELOG.md"; then
            echo "::warning::CHANGELOG.md was not updated. Add an entry under [Unreleased]."
          fi
```

**`scripts/release.sh`** — local release helper:
```bash
#!/bin/bash
# Usage: ./scripts/release.sh 1.1.0
set -euo pipefail
NEW_VERSION="$1"
TODAY=$(date +%Y-%m-%d)

echo "$NEW_VERSION" > VERSION
sed -i.bak "s/## \[Unreleased\]/## [Unreleased]\n\n## [$NEW_VERSION] - $TODAY/" CHANGELOG.md
rm -f CHANGELOG.md.bak

echo "Updated VERSION to $NEW_VERSION and CHANGELOG.md"
echo ""
echo "Review changes, then run:"
echo "  git add VERSION CHANGELOG.md"
echo "  git commit -m 'chore: release v$NEW_VERSION'"
echo "  git tag v$NEW_VERSION"
echo "  git push origin main v$NEW_VERSION"
```

### Changes to Existing Files

**`CHANGELOG.md`** — add version link footer (Keep a Changelog standard):
```
[Unreleased]: https://github.com/thepostgresguy/pgtools/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/thepostgresguy/pgtools/releases/tag/v1.0.0
```

**`README.md`** — add version badge:
```markdown
[![Latest Release](https://img.shields.io/github/v/release/thepostgresguy/pgtools)](https://github.com/thepostgresguy/pgtools/releases)
```

### Acceptance Criteria
- [ ] Pushing tag `v1.1.0` when `VERSION` contains `1.1.0` triggers release workflow
- [ ] GitHub Release is created with notes from the `[1.1.0]` CHANGELOG section
- [ ] Release page contains `.tar.gz`, `.zip`, and `checksums.txt`
- [ ] Tag/VERSION mismatch fails the workflow early with a clear error
- [ ] `scripts/release.sh 1.2.0` automates the manual steps correctly

---

## Phase Sequencing

```
Phase 1 (fix CI)  →  Phase 2 (BATS tests)
       ↓
Phase 3 (CLI)     — can develop in parallel with Phase 2
       ↓
Phase 4 (releases) — requires Phase 3 artifacts (bin/pgtools, VERSION)
```

Phase 1 is a hard prerequisite. Phases 2 and 3 can be developed in parallel branches. Phase 4 is last because it packages the output of everything before it. Do not cut a release until all four phases are merged and CI is fully green.

---

## Known Bugs (Fix in Phase 1)

| File | Line | Bug |
|------|------|-----|
| `automation/test_pgtools.sh` | ~174 | `psql --dry-run` is not a valid flag |
| `automation/test_pgtools.sh` | ~176 | `psql -c "\\i $file"` — `\i` is a meta-command, invalid in `-c` |
| `automation/test_pgtools.sh` | ~308 | Division by zero when `TESTS_RUN=0` |
| `.github/workflows/ci.yml` | multiple | Three test steps commented out |
| `.github/workflows/ci.yml` | shellcheck step | Only lints `automation/*.sh`, misses other shell scripts |
