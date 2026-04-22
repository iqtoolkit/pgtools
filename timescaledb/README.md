# TimescaleDB Diagnostics

Scripts for monitoring and troubleshooting TimescaleDB-specific features: chunk health, compression, continuous aggregates, background jobs, and tiered storage.

> **Prerequisite:** All scripts require the TimescaleDB extension to be installed.

## Quick Reference

- `chunk_health.sql` - Chunk count, size distribution, and interval configuration
- `compression_diagnostics.sql` - Compression settings, effectiveness, and backlog
- `continuous_aggregates.sql` - CAGG health and refresh policy lag
- `background_jobs.sql` - Job failures, error messages, and worker saturation
- `replication_tiering.sql` - Tiger Lake / tiered storage replication slot health

## Quick Start

```bash
# Chunk health (start here for slow query planning)
psql -d mydb -f timescaledb/chunk_health.sql

# Compression status and backlog
psql -d mydb -f timescaledb/compression_diagnostics.sql

# Continuous aggregate freshness
psql -d mydb -f timescaledb/continuous_aggregates.sql

# Background job failures
psql -d mydb -f timescaledb/background_jobs.sql

# Tiger Lake replication lag
psql -d mydb -f timescaledb/replication_tiering.sql
```

## Triage Flow

When investigating a performance issue in a TimescaleDB environment:

1. **Chunk count** (`chunk_health.sql`) — planning overhead is the most common silent cause
2. **Compression stats** (`compression_diagnostics.sql`) — is old data still uncompressed?
3. **Job stats** (`background_jobs.sql`) — are policies behind or workers saturated?
4. **CAGG freshness** (`continuous_aggregates.sql`) — are dashboards showing stale data?
5. **Replication lag** (`replication_tiering.sql`) — anything stuck at the tiering layer?

Then continue with the standard PostgreSQL triage using `monitoring/` and `performance/` scripts.

For detailed usage, examples, and workflows, please refer to the complete documentation.
