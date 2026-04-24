# pgtools: The First Responder's Toolbelt for PostgreSQL

`pgtools` is a curated collection of safe, read-only diagnostic scripts for PostgreSQL and TimescaleDB, wrapped in a simple command-line interface. It is designed for Support Engineers, DBAs, and developers who need to triage production database issues quickly and without causing harm.

Every script is executed with strict, short timeouts to ensure that diagnostic queries never impact a heavily loaded system.

## Core Principles

- **Zero-Harm Policy**: Every script is read-only and executed with a 5-second `statement_timeout` and 3-second `lock_timeout`.
- **No Dependencies**: The toolbelt relies only on `bash` and `psql`. No Python, Go, or other complex dependencies are required.
- **Ticket-Ready Output**: All output is formatted for easy copy-pasting into Zendesk, Jira, or Markdown documents.
- **Community-Driven**: Built for general PostgreSQL users, with specialized diagnostics for TimescaleDB.

## Getting Started

### Installation

```bash
# 1. Clone the repository
git clone <https://github.com/thepostgresguy/pgtools.git>
cd pgtools

# 2. Make the wrapper script executable
chmod +x pgtools.sh
```

### Usage

All commands are run through the `pgtools.sh` wrapper.

```bash
./pgtools.sh <command> "<connection_string>"
```

**Example: Check for blocking locks**
```bash
./pgtools.sh locks "postgresql://user:pass@host:port/dbname"
```

**Example: Check TimescaleDB chunk stats using a service name**
```bash
./pgtools.sh chunk-stats "service=my_customer_db"
```

## Available Commands

Run `./pgtools.sh` with no arguments to see the full list of commands.

### General Diagnostics

*   `locks`: Show current lock contention and blocking queries.
*   `activity`: Display current query activity from `pg_stat_activity`.
*   `top-queries`: Show most time-consuming queries (requires `pg_stat_statements`).
*   `bloat`: Identify table and index bloat.
*   `replication`: Monitor replication lag and status.
*   `disk-usage`: Show disk usage by table and index.
*   `cache-hit`: Show table and index cache hit rates.

### TimescaleDB Diagnostics

*   `chunk-stats`: Show chunk count and size per hypertable.
*   `compression-stats`: Show compression ratio and job status per hypertable.
*   `cagg-stats`: Show continuous aggregate health and refresh policy status.
*   `job-errors`: Show recent errors from background jobs.
*   `uncompressed-chunks`: Show chunks that are old but not compressed.

### Administration

*   `permissions`: Audit user and role permissions.
*   `ownership`: Display table and object ownership.

## Incident Response Workflow Example

A customer reports "the database is slow." Here's a typical triage flow using `pgtools`:

1.  **Check for blocking locks.** This is the most common cause of a sudden slowdown.
    ```bash
    ./pgtools.sh locks "<conn_string>"
    ```

2.  **Check current activity.** See what queries are actively running or waiting.
    ```bash
    ./pgtools.sh activity "<conn_string>"
    ```

3.  **Check top queries.** If `pg_stat_statements` is enabled, find out which queries are consuming the most database time historically.
    ```bash
    ./pgtools.sh top-queries "<conn_string>"
    ```

4.  **Check cache hit rate.** A low hit rate points to I/O bottlenecks.
    ```bash
    ./pgtools.sh cache-hit "<conn_string>"
    ```

## Contributing

Contributions are welcome! Please see CONTRIBUTING.md for detailed guidelines on how to add new diagnostic scripts.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

