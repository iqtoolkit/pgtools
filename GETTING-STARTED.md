# Getting Started with pgtools: The First Responder Toolbelt

Welcome to **pgtools**, the "First Responder" Support Toolbelt for safely diagnosing PostgreSQL and TimescaleDB databases. This guide will help you get up and running quickly.

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Core Usage](#core-usage)
- [Example Workflows](#example-workflows)
- [Available Commands](#available-commands)

## Prerequisites

- **Shell**: A `bash`-compatible shell.
- **Tools**: `psql` (the PostgreSQL command-line client) and `git`.
- **Database Access**: A valid PostgreSQL connection string or service name to connect to the target database. Most scripts require privileges equivalent to the `pg_monitor` role.

## Installation
```bash
# Clone the repository
git clone https://github.com/thepostgresguy/pgtools.git
cd pgtools

# Make the main script executable
chmod +x pgtools.sh
```

### Method 2: Download ZIP
```bash
# Download and extract
curl -L https://github.com/thepostgresguy/pgtools/archive/main.zip -o pgtools.zip
unzip pgtools.zip
cd pgtools-main
chmod +x automation/*.sh maintenance/*.sh integration/*.sh configuration/*.sh
```

### Verify Installation
```bash
# Test basic functionality
./automation/test_pgtools.sh --help

# Check script availability
ls -la monitoring/*.sql

# Run quick validation (requires local PostgreSQL)
./automation/test_pgtools.sh --fast
```

### Verify PostgreSQL Compatibility
This toolkit has been tested against PostgreSQL 14 through 18. Check your PostgreSQL version:

```bash
psql --version
```

If you're running PostgreSQL 13 or earlier, some scripts may not function as expected. Consider upgrading or testing in a development environment first.

For more details on script requirements and compatibility, refer to the README files in each directory.

## First Steps

### 1. Test Database Connection
Before using pgtools, verify you can connect to your PostgreSQL database:

```bash
# Test connection (replace with your details)
psql -h localhost -p 5432 -U your_username -d your_database -c "SELECT version();"
```

### 2. Run Your First Health Check
Start with a basic database health assessment:

```bash
# Basic lock monitoring (safe to run on production)
psql -d your_database -f monitoring/locks.sql

# Check for table bloating
psql -d your_database -f monitoring/bloating.sql

# Monitor transaction age (important for database health)
psql -d your_database -f monitoring/txid.sql
```

### 3. Generate Your First Report
Create a comprehensive health report:

```bash
# Generate basic health report
mkdir -p reports
echo "=== Database Health Report $(date) ===" > reports/health_report.txt
psql -d your_database -f monitoring/locks.sql >> reports/health_report.txt
psql -d your_database -f monitoring/replication.sql >> reports/health_report.txt
psql -d your_database -f monitoring/connection_pools.sql >> reports/health_report.txt
```

## Essential Scripts

### Core Monitoring Scripts
These are the most important scripts to start with:

#### 1. `monitoring/locks.sql` - Lock Analysis
```bash
# Check for blocking queries and lock contention
psql -d production -f monitoring/locks.sql

# What to look for:
# - granted = 'f' (waiting locks)
# - Long-running queries (high query_age)
# - AccessExclusiveLock during business hours
```

#### 2. `monitoring/bloating.sql` - Table Health
```bash
# Identify tables needing maintenance
psql -d production -f monitoring/bloating.sql

# Alert thresholds:
# - >20% dead tuples: Schedule VACUUM
# - >50% dead tuples: Urgent VACUUM needed
```

#### 3. `monitoring/replication.sql` - Replication Status
```bash
# Monitor replication lag (run on primary server)
psql -d production -f monitoring/replication.sql

# Critical alerts:
# - Lag >5 minutes on sync replicas
# - Inactive replication slots
```

### Administrative Scripts

#### 4. `administration/table_ownership.sql` - Security Audit
```bash
# Review table ownership and permissions
psql -d production -f administration/table_ownership.sql
```

#### 5. `security/permission_audit.sql` - Comprehensive Security Check
```bash
# Complete security audit
psql -d production -f security/permission_audit.sql
```

### Performance Analysis

#### 6. `performance/query_performance_profiler.sql` - Query Analysis
```bash
# Analyze slow queries (requires pg_stat_statements)
psql -d production -f performance/query_performance_profiler.sql
```

## Common Workflows

### Daily Health Check Routine
```bash
#!/bin/bash
# daily_health_check.sh

DATABASE="your_production_db"
REPORT_DIR="daily_reports"
DATE=$(date +%Y%m%d)

mkdir -p $REPORT_DIR

echo "=== Daily Health Check $DATE ===" > $REPORT_DIR/health_$DATE.log

echo "1. Checking locks..." >> $REPORT_DIR/health_$DATE.log
psql -d $DATABASE -f monitoring/locks.sql >> $REPORT_DIR/health_$DATE.log

echo "2. Checking bloating..." >> $REPORT_DIR/health_$DATE.log
psql -d $DATABASE -f monitoring/bloating.sql >> $REPORT_DIR/health_$DATE.log

echo "3. Checking replication..." >> $REPORT_DIR/health_$DATE.log
psql -d $DATABASE -f monitoring/replication.sql >> $REPORT_DIR/health_$DATE.log

echo "4. Checking transaction age..." >> $REPORT_DIR/health_$DATE.log
psql -d $DATABASE -f monitoring/txid.sql >> $REPORT_DIR/health_$DATE.log

echo "Health check complete: $REPORT_DIR/health_$DATE.log"
```

### Weekly Maintenance Routine
```bash
#!/bin/bash
# weekly_maintenance.sh

DATABASE="your_production_db"

echo "=== Weekly Maintenance $(date) ==="

# 1. Run comprehensive ANALYZE
echo "Running ANALYZE operations..."
./maintenance/auto_maintenance.sh --operation analyze --database $DATABASE --verbose

# 2. Security audit
echo "Running security audit..."
psql -d $DATABASE -f security/permission_audit.sql > weekly_security_audit.log

# 3. Performance analysis
echo "Analyzing performance..."
psql -d $DATABASE -f performance/resource_monitoring.sql > weekly_performance.log

echo "Weekly maintenance complete!"
```

### Incident Response Workflow
```bash
#!/bin/bash
# incident_response.sh

DATABASE=$1

echo "=== INCIDENT RESPONSE $(date) ==="

# Step 1: Immediate assessment
echo "1. Checking for blocking queries..."
psql -d $DATABASE -f monitoring/postgres_locking_blocking.sql

# Step 2: Resource analysis
echo "2. Analyzing system resources..."
psql -d $DATABASE -f monitoring/buffer_troubleshoot.sql

# Step 3: Performance check
echo "3. Performance analysis..."
psql -d $DATABASE -f performance/wait_event_analysis.sql

# Step 4: Connection analysis
echo "4. Connection patterns..."
psql -d $DATABASE -f monitoring/connection_pools.sql
```

## Setting Up Automation

### 1. Configure Automated Health Checks
```bash
# Copy configuration template
cp automation/pgtools.conf.example automation/pgtools.conf

# Edit configuration
nano automation/pgtools.conf
# Set your database connection details:
# DATABASE_NAME=production
# DATABASE_HOST=localhost
# DATABASE_PORT=5432
# DATABASE_USER=monitoring_user
```

### 2. Install Cron Jobs
```bash
# Set up automated monitoring
./automation/pgtools_scheduler.sh install

# Manual cron job examples:
# Daily health check at 2 AM
0 2 * * * /path/to/pgtools/automation/pgtools_health_check.sh --database production --format email

# Weekly maintenance on Sundays at 1 AM
0 1 * * 0 /path/to/pgtools/maintenance/auto_maintenance.sh --operation analyze --database production
```

### 3. Set Up Alerting
```bash
# Example email alerting script
cat > check_critical_issues.sh << 'EOF'
#!/bin/bash
DATABASE="production"

# Check for critical blocking
BLOCKS=$(psql -d $DATABASE -t -c "SELECT count(*) FROM pg_locks WHERE NOT granted;")
if [ "$BLOCKS" -gt 0 ]; then
    echo "ALERT: $BLOCKS blocked queries detected" | mail -s "PostgreSQL Alert" admin@company.com
fi

# Check replication lag
if psql -d $DATABASE -c "SELECT count(*) FROM pg_stat_replication;" -t | grep -q -v "0"; then
    LAG=$(psql -d $DATABASE -t -c "SELECT max(extract(epoch from replay_lag)) FROM pg_stat_replication;")
    if (( $(echo "$LAG > 300" | bc -l) )); then
        echo "ALERT: Replication lag exceeds 5 minutes" | mail -s "PostgreSQL Replication Alert" admin@company.com
    fi
fi
EOF

chmod +x check_critical_issues.sh

# Add to cron (every 5 minutes during business hours)
*/5 9-18 * * 1-5 /path/to/check_critical_issues.sh
```

## Troubleshooting

### Common Issues and Solutions

#### Script Permission Errors
```bash
# Fix: Make scripts executable
chmod +x automation/*.sh maintenance/*.sh integration/*.sh configuration/*.sh
```

#### Database Connection Issues
```bash
# Test connection manually
psql -h your_host -p 5432 -U your_user -d your_database -c "SELECT 1;"

# Check pg_hba.conf for connection permissions
# Ensure user has required privileges
```

#### Missing pg_stat_statements
```bash
# Install extension (requires superuser)
psql -d your_database -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

# Add to postgresql.conf:
# shared_preload_libraries = 'pg_stat_statements'
# Then restart PostgreSQL
```

#### Insufficient Privileges
```bash
# Grant monitoring role (PostgreSQL 15+)
psql -d your_database -c "GRANT pg_monitor TO your_monitoring_user;"

# For pre-15 legacy versions, grant specific permissions:
psql -d your_database -c "GRANT SELECT ON ALL TABLES IN SCHEMA pg_catalog TO your_monitoring_user;"
```

### PostgreSQL Version-Specific Notes

**Verified Support**: PostgreSQL 14, 15, 16, 17, and 18 (tested in CI)

- **PostgreSQL 14-15**: Full compatibility; all core features available
- **PostgreSQL 16-18**: Recommended for new deployments; all scripts validated
- **PostgreSQL < 14**: Not tested; some scripts may not function as expected

**Known Limitations**:
- Some security audit scripts may need privilege verification on non-superuser accounts
- Extension preload/reload sequence matters in CI environments
- Dynamic privilege checks vary by PostgreSQL version

### Getting Help

#### Script-Specific Help
```bash
# Most shell scripts have help options
./maintenance/auto_maintenance.sh --help
./automation/pgtools_health_check.sh --help
```

#### SQL Script Documentation
```sql
-- All SQL scripts have comprehensive headers with:
-- - Usage instructions
-- - Sample output
-- - Requirements
-- - Interpretation guides
```

#### Community Support
- **GitHub Issues**: Report bugs or request features
- **Discussions**: Ask questions and share experiences
- **Documentation**: Check script-specific README files in each directory

## Next Steps

### 1. Explore Advanced Features
```bash
# Try comprehensive automation
./automation/pgtools_health_check.sh --format html --email

# Set up Grafana integration
./integration/grafana_dashboard_generator.sh --type comprehensive

# Configure Prometheus monitoring
./integration/prometheus_exporter.sh --port 9187 --daemon
```

### 2. Customize for Your Environment
```bash
# Create custom monitoring scripts
cp monitoring/locks.sql monitoring/custom_locks.sql
# Edit to add environment-specific filters

# Set up environment-specific configurations
cp automation/pgtools.conf automation/staging.conf
cp automation/pgtools.conf automation/production.conf
```

### 3. Integration with Existing Tools
- **Monitoring Systems**: Integrate with Nagios, Zabbix, or other monitoring platforms
- **CI/CD Pipelines**: Add database health checks to deployment pipelines
- **Documentation**: Document your specific workflows and configurations

### 4. Contributing Back
- **Share configurations**: Contribute environment-specific examples
- **Report issues**: Help improve pgtools by reporting bugs
- **Add features**: Contribute new scripts or enhancements
- **Documentation**: Help improve guides and examples

## Quick Reference Card

### Essential Daily Commands
```bash
# Health check
psql -d prod -f monitoring/locks.sql

# Check bloating
psql -d prod -f monitoring/bloating.sql

# Monitor replication
psql -d prod -f monitoring/replication.sql

# Automated maintenance
./maintenance/auto_maintenance.sh --operation auto
```

### Emergency Commands
```bash
# Find blocking queries
psql -d prod -f monitoring/postgres_locking_blocking.sql

# Check system resources
psql -d prod -f monitoring/buffer_troubleshoot.sql

# Analyze wait events
psql -d prod -f performance/wait_event_analysis.sql
```

### Weekly Tasks
```bash
# Comprehensive analysis
./maintenance/auto_maintenance.sh --operation analyze --parallel 4

# Security audit
psql -d prod -f security/permission_audit.sql

# Performance review
psql -d prod -f performance/query_performance_profiler.sql
```

## Conclusion

You're now ready to start using pgtools effectively! Remember:

1. **Start small** - Begin with basic monitoring scripts
2. **Build gradually** - Add automation as you become comfortable
3. **Monitor regularly** - Consistent monitoring prevents major issues
4. **Document everything** - Keep track of your specific configurations
5. **Stay updated** - Check for new releases and features

For additional help, refer to the comprehensive documentation in each directory's README file, or visit the project repository for community support.

Happy PostgreSQL administration! 🐘🔧