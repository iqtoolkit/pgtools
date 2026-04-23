# pgtools — Implementation Plan (A+ Roadmap)

## IQToolkit Analyzer Integration

pgtools is designed to be consumed by [iqtoolkit-analyzer](../iqtoolkit-analyzer) via its `scripts` subsystem (`iqtoolkit_analyzer/scripts/`). The subsystem already handles sync, discovery, and execution — pgtools just needs to be declared as a library in the user's `.iqtoolkit-analyzer.yml`.

### Step 1 — Declare pgtools as a script library

Add to `.iqtoolkit-analyzer.yml`:

```yaml
script_libraries:
  postgresql:
    repo: https://github.com/thepostgresguy/pgtools
    branch: main
    executor: psql
```

### Step 2 — Sync and run

```bash
# Pull the repo into ~/.iqtoolkit/script_libraries/postgresql/
iqtoolkit-analyzer scripts sync --library postgresql

# See every available script grouped by category
iqtoolkit-analyzer scripts list --library postgresql

# Run a script against a live database
iqtoolkit-analyzer scripts run postgresql monitoring/bloating \
    -c "postgresql://user:pass@localhost/mydb"

# Run the HOT update checklist
iqtoolkit-analyzer scripts run postgresql optimization/hot_update_optimization_checklist \
    -c "postgresql://user:pass@localhost/mydb"

# Run resource monitoring
iqtoolkit-analyzer scripts run postgresql performance/resource_monitoring \
    -c "postgresql://user:pass@localhost/mydb"
```

The runner dispatches `.sql` files via `psql -f`, streams output to stdout, and returns a non-zero exit code on failure — consistent with how the analyzer handles all other script libraries (sqlserver-toolkit, mysql-tools, mongo-toolkit).

### How the subsystem works (relevant files in iqtoolkit-analyzer)

| File | Role |
|------|------|
| `iqtoolkit_analyzer/scripts/sync.py` | `git clone --depth 1` or `git pull --ff-only` into `~/.iqtoolkit/script_libraries/` |
| `iqtoolkit_analyzer/scripts/registry.py` | Walks the cache dir, discovers `.sql` / `.sh` files, resolves executor per extension |
| `iqtoolkit_analyzer/scripts/runner.py` | Dispatches to `psql`, `mysql`, `sqlcmd`, `bash`, `node` based on `ScriptEntry.executor` |
| `iqtoolkit_analyzer/cli/scripts_commands.py` | Click CLI: `scripts sync`, `scripts list`, `scripts run` |
| `iqtoolkit_analyzer/config.py:ScriptLibraryConfig` | Parses `script_libraries` block from `.iqtoolkit-analyzer.yml` |

### Deeper integration opportunities (future work)

**1. AI analysis of pgtools output**
The analyzer has an LLM layer (`cli/_ai_helpers.py` → `LLMClient` → `LLMProviderAdapter`). pgtools script output can be piped into the analyzer's AI layer for natural language recommendations. For example: run `resource_monitoring.sql`, capture output, pass to LLM with a prompt: *"Given these PostgreSQL metrics, what are the top 3 actions to take?"*

**2. Trending into AnalysisResultV2**
Phase 7 of the pgtools roadmap (trending/baselines) should output results that conform to `iqtoolkit-contracts/AnalysisResultV2` so they appear in the analyzer's unified report format. The `pgtools_monitoring.snapshots` table becomes a data source the analyzer can query.

**3. `pgtools check-wraparound` as a health gate**
Once Phase 6 adds `monitoring/wraparound_risk.sql`, it should be wired into the analyzer's `pg health` command as a mandatory check — wraparound age surfaced alongside connection counts and cache hit ratio.

**4. Shell scripts via the runner**
`automation/run_hot_update_report.sh` and `automation/pgtools_health_check.sh` already work through the bash executor. The runner calls `bash script.sh` — no changes needed to pgtools shell scripts.

### What pgtools must NOT do for this integration to stay clean

- Do not add Python, Node, or any runtime dependency — keep everything as plain SQL and bash so the `psql` / `bash` executors handle it without special setup.
- Do not hardcode connection strings inside scripts — all connection config flows in from the analyzer via `psql -c "connection_string" -f script.sql`.
- The `bin/pgtools` CLI (Phase 3) and `iqtoolkit-analyzer scripts run` are complementary, not competing — `bin/pgtools` is for standalone use, the analyzer integration is for managed/multi-database use.

---

## Honest Assessment

**Good reference library, not yet a production toolkit.**

### What it does well
- **Coverage is broad.** Monitoring, bloat, locks, replication, HOT updates, missing indexes, config analysis, partition management, query profiling — the right topics are all here.
- **The annotations are excellent.** `bloating.sql` has sample output, interpretation guidance, threshold ladders, and autovacuum tuning examples inline.
- **The SQL is correct.** Queries hit the right catalog views (`pg_stat_user_tables`, `pg_stat_bgwriter`, `pg_stat_statements`) and compute the right ratios.

### Where it falls short
- **All snapshots, no trending.** Can't tell if things are getting better or worse.
- **Silent privilege failures.** Insufficient permissions return empty results, not errors. Looks like "no problems" when the real answer is "you can't see the data."
- **No wraparound monitoring.** The single most dangerous PostgreSQL failure mode has no dedicated script.
- **No inactive replication slot detection.** A slot with no consumer will fill your disk.
- **FK index detection has false positives.** String matching on `indexdef` is fragile.
- **CI is broken.** Three test steps are commented out, `psql --dry-run` doesn't exist.
- **No CLI.** You have to know the directory layout and file names to use it.

### Compared to alternatives
pgBadger, pganalyze, and Postgres checkup do trending, historical comparison, and automated recommendations out of the box. pgtools doesn't compete with those yet. What pgtools does better: transparent SQL you can read, audit, and run anywhere without an agent, a SaaS account, or a log parser — a real advantage in locked-down environments.

### Bottom line
Good enough to use today as a **diagnostic reference** — run a script when something is on fire and it'll point you in the right direction. Not production-grade until Phase 1 (CI fixed), Phase 3 (CLI), and Phase 6 (missing scripts) are done. The bones are solid. The roadmap is the right one.

---

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
       ↓
Phase 5 (script fixes) — can begin after Phase 1
       ↓
Phase 6 (missing scripts) — after Phase 3 CLI is stable
       ↓
Phase 7 (trending) — last, requires stable script layer
```

Phase 1 is a hard prerequisite. Phases 2 and 3 can be developed in parallel branches. Phase 4 is last because it packages the output of everything before it. Do not cut a release until all four phases are merged and CI is fully green.

---

## Phase 5 — Script-Level Bug Fixes

**Goal**: Fix correctness issues in existing SQL scripts identified during review.

### Bugs to Fix

| File | Issue | Fix |
|------|-------|-----|
| `monitoring/bloating.sql` line 98 | `WHERE n_dead_tup > 0` is commented out — returns tables with zero dead tuples, polluting output | Uncomment and raise threshold to `n_dead_tup > 1000` |
| `optimization/missing_indexes.sql` FK detection | Cross-joins on `indexdef LIKE '%' || fk.column_name || '%'` — string match produces false positives (e.g. `user_id` matches `business_user_id`) | Rewrite using `pg_index` / `pg_attribute` join instead of string matching on `indexdef` |
| All scripts | Insufficient privileges return empty result sets — looks like "no problems" instead of "cannot see data" | Add privilege check block at top of each script: query `has_table_privilege` or `pg_has_role` and `\warn` if insufficient, then exit cleanly |

### Acceptance Criteria
- [ ] `bloating.sql` only returns tables with meaningful dead tuple counts
- [ ] `missing_indexes.sql` FK detection has zero false positives on a schema with overlapping column names
- [ ] All scripts print a clear privilege warning and exit non-zero when run without required permissions

---

## Phase 6 — Missing Scripts

**Goal**: Cover critical failure modes that have no script in the repo today.

### New Files to Create

**`monitoring/wraparound_risk.sql`** — dedicated XID age monitoring:
```sql
-- Database-level risk (cluster-wide view)
SELECT datname,
       age(datfrozenxid)                          AS xid_age,
       2100000000 - age(datfrozenxid)             AS xids_remaining,
       CASE
           WHEN age(datfrozenxid) > 1500000000 THEN 'CRITICAL'
           WHEN age(datfrozenxid) > 1000000000 THEN 'WARNING'
           WHEN age(datfrozenxid) > 500000000  THEN 'MONITOR'
           ELSE 'OK'
       END AS risk_level
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Table-level breakdown — find the table driving the age
SELECT schemaname, relname,
       age(relfrozenxid)                          AS table_xid_age,
       pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS size,
       last_autovacuum,
       last_vacuum
FROM pg_class
JOIN pg_namespace ON pg_class.relnamespace = pg_namespace.oid
WHERE relkind = 'r'
ORDER BY age(relfrozenxid) DESC
LIMIT 20;
```

Add `check-wraparound` command to `bin/pgtools` dispatcher.

**`monitoring/replication_slots.sql`** — inactive slot WAL accumulation:

Replication slots that have no active consumer hold WAL on disk indefinitely. `replication.sql` monitors lag on active standbys but does not alert on this failure mode.

```sql
SELECT slot_name,
       slot_type,
       active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
       restart_lsn,
       confirmed_flush_lsn,
       CASE
           WHEN active = false THEN 'DANGER: inactive slot holding WAL'
           ELSE 'OK'
       END AS status
FROM pg_replication_slots
ORDER BY active ASC, restart_lsn ASC;
```

Add `check-slots` command to `bin/pgtools` dispatcher.

**`monitoring/pgbouncer_status.sql`** — PgBouncer pool health:

Most production deployments use PgBouncer. None of the existing scripts surface pooler state. This script connects to the PgBouncer admin database (`pgbouncer`) and queries `SHOW POOLS`, `SHOW STATS`, and `SHOW CLIENTS`.

Note: requires a separate psql connection to the PgBouncer admin port (default 6432). Add `pgtools check-pooler --host pgbouncer-host --port 6432` command.

**`troubleshooting/triage_runbook.sql`** — unified triage sequence:

The three query packs (`query_pack_01/02/03`) have no documented order of use. Replace with a single file that encodes the triage sequence explicitly:

1. Long-running queries (`pg_stat_activity` by duration)
2. Blocking chain (self-join on `pg_locks WHERE NOT granted`)
3. Wait events (`pg_stat_activity WHERE wait_event IS NOT NULL`)
4. Autovacuum state (`pg_stat_user_tables` by `n_dead_tup`)
5. Checkpoint pressure (`pg_stat_bgwriter` ratios)
6. XID age (`age(datfrozenxid)` across databases)

### CLI Additions

Add to `bin/pgtools` dispatcher:
```bash
check-wraparound) run_sql "$PGTOOLS_ROOT/monitoring/wraparound_risk.sql" "$@" ;;
check-slots)      run_sql "$PGTOOLS_ROOT/monitoring/replication_slots.sql" "$@" ;;
triage)           run_sql "$PGTOOLS_ROOT/troubleshooting/triage_runbook.sql" "$@" ;;
```

### Acceptance Criteria
- [ ] `pgtools check-wraparound` surfaces all databases including `template0/template1`
- [ ] `pgtools check-slots` flags inactive slots with retained WAL size
- [ ] `pgtools triage` runs all 6 steps in order and exits 0
- [ ] BATS tests cover all three new scripts (Phase 2 test files updated)

---

## Phase 7 — Trending and Baselines

**Goal**: Shift from point-in-time snapshots to time-series data so metrics are meaningful relative to a baseline. This is the difference between a DBA toolkit and an observability platform.

### Problem

Every script in the repo gives you the state right now. `checkpoints_req = 47` means nothing without knowing if that number is from the last 5 minutes or the last 5 days. `cache_hit_ratio = 94%` looks fine until you know it was 99% yesterday.

### Design

A lightweight schema written to a dedicated monitoring database (or a `pgtools` schema in the target database). A cron job or `pg_cron` entry captures snapshots on a schedule. Scripts compare current values to the rolling baseline.

**`monitoring/schema/pgtools_schema.sql`** — creates the capture schema:
```sql
CREATE SCHEMA IF NOT EXISTS pgtools_monitoring;

CREATE TABLE IF NOT EXISTS pgtools_monitoring.snapshots (
    captured_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    metric_name         TEXT NOT NULL,
    metric_value        NUMERIC,
    metric_text         TEXT,
    labels              JSONB
) PARTITION BY RANGE (captured_at);

-- Retention: 30 days of snapshots
CREATE INDEX ON pgtools_monitoring.snapshots (metric_name, captured_at DESC);
```

**`monitoring/capture_snapshot.sql`** — inserts current metric values into the schema. Captures:
- `checkpoints_req` / `checkpoints_timed` ratio
- `cache_hit_ratio` per database
- `age(datfrozenxid)` per database
- Connection count vs `max_connections`
- Dead tuple ratio for top 20 tables by dead tuple count

**`monitoring/trending_report.sql`** — compares current snapshot to 24h and 7d rolling averages. Flags metrics that have degraded by more than 10% from their baseline.

**`automation/capture_metrics.sh`** — shell wrapper for `pg_cron` or system cron:
```bash
#!/bin/bash
# Add to crontab: */15 * * * * /usr/local/share/pgtools/automation/capture_metrics.sh
psql -f "$PGTOOLS_ROOT/monitoring/capture_snapshot.sql" "$@"
```

### CLI Additions
```bash
init-monitoring)  run_sql "$PGTOOLS_ROOT/monitoring/schema/pgtools_schema.sql" "$@" ;;
capture)          run_sql "$PGTOOLS_ROOT/monitoring/capture_snapshot.sql" "$@" ;;
trending)         run_sql "$PGTOOLS_ROOT/monitoring/trending_report.sql" "$@" ;;
```

### Acceptance Criteria
- [ ] `pgtools init-monitoring` creates the schema idempotently
- [ ] `pgtools capture` runs without error and inserts rows
- [ ] `pgtools trending` produces output after at least 2 captures
- [ ] Schema uses partitioning so old snapshots can be dropped without locking
- [ ] BATS test: capture twice, assert `trending` report runs without error

---

## Known Bugs (Fix in Phase 1)

| File | Line | Bug |
|------|------|-----|
| `automation/test_pgtools.sh` | ~174 | `psql --dry-run` is not a valid flag |
| `automation/test_pgtools.sh` | ~176 | `psql -c "\\i $file"` — `\i` is a meta-command, invalid in `-c` |
| `automation/test_pgtools.sh` | ~308 | Division by zero when `TESTS_RUN=0` |
| `.github/workflows/ci.yml` | multiple | Three test steps commented out |
| `.github/workflows/ci.yml` | shellcheck step | Only lints `automation/*.sh`, misses other shell scripts |
