# PostgreSQL Monitoring Scripts

This directory contains essential monitoring scripts for PostgreSQL database health, performance analysis, and proactive issue detection. These scripts are designed for daily operational use and incident response.

## 📋 Table of Contents

- [Quick Reference](#quick-reference)
- [Scripts Overview](#scripts-overview)
- [Usage Patterns](#usage-patterns)
- [Monitoring Workflows](#monitoring-workflows)
- [Alert Thresholds](#alert-thresholds)
- [Troubleshooting Guide](#troubleshooting-guide)
- [Integration Examples](#integration-examples)

## Quick Reference

### Daily Health Check Commands
```bash
# Essential daily monitoring routine
psql -d mydb -f monitoring/locks.sql                    # Check for blocking queries
psql -d mydb -f monitoring/replication.sql              # Verify replication health
psql -d mydb -f monitoring/txid.sql                     # Monitor transaction wraparound
psql -d mydb -f monitoring/connection_pools.sql         # Check connection efficiency
```

### Emergency Response Commands
```bash
# Immediate issue investigation
psql -d mydb -f monitoring/postgres_locking_blocking.sql # Identify blocking sessions
psql -d mydb -f monitoring/bloating.sql                 # Check for space issues
psql -d mydb -f monitoring/buffer_troubleshoot.sql      # Analyze memory usage
```

## Scripts Overview

### 🔒 Lock Analysis Scripts

#### `locks.sql`
**Purpose:** Real-time database lock monitoring and analysis
**Use Cases:** 
- Daily lock health checks
- Performance degradation investigation
- Deadlock prevention monitoring

**Sample Output:**
```
 locktype | relation |  mode           | granted | pid  | query_start         | query
----------|----------|-----------------|---------|------|--------------------|---------
 relation | users    | AccessShareLock | t       | 1234 | 2025-10-25 10:30:00| SELECT * FROM users WHERE id = 1
 relation | orders   | RowExclusiveLock| t       | 5678 | 2025-10-25 10:29:45| UPDATE orders SET status = 'completed'
```

**Key Metrics:**
- **Lock Types:** Relation, tuple, transaction ID locks
- **Lock Modes:** AccessShare, RowExclusive, ShareUpdate, etc.
- **Grant Status:** Whether lock is granted or waiting
- **Query Context:** Active queries holding or waiting for locks

**Customization Parameters:**
```sql
-- Filter by specific lock types (uncomment as needed)
-- WHERE locktype = 'relation'           -- Table-level locks only
-- WHERE NOT granted                     -- Show only waiting locks
-- WHERE query NOT LIKE '%IDLE%'         -- Exclude idle connections
```

#### `postgres_locking_blocking.sql`
**Purpose:** Advanced blocking query identification and resolution
**Use Cases:**
- Critical performance incidents
- Detailed deadlock analysis
- Query optimization planning

**Sample Output:**
```
blocking_pid | blocked_pid | blocking_query                    | blocked_query              | wait_time
-------------|-------------|-----------------------------------|----------------------------|----------
    1234     |    5678     | UPDATE users SET last_login = NOW | SELECT * FROM users WHERE  | 00:02:15
    1234     |    9012     | UPDATE users SET last_login = NOW | DELETE FROM user_sessions  | 00:01:30
```

**Alert Thresholds:**
- **Critical:** Blocks lasting >5 minutes
- **Warning:** Blocks lasting >1 minute
- **Monitor:** Any blocking relationship during peak hours

**Resolution Actions:**
```sql
-- Terminate blocking session (use with caution)
SELECT pg_terminate_backend(1234);

-- Cancel blocking query (safer option)
SELECT pg_cancel_backend(1234);
```

### 📊 Performance Monitoring Scripts

#### `bloating.sql`
**Purpose:** Table and index bloat detection and space analysis
**Use Cases:**
- Storage capacity planning
- VACUUM scheduling optimization
- Performance degradation investigation

> **Note:** Output is filtered to tables with more than 1,000 dead tuples (`n_dead_tup > 1000`). Tables with negligible bloat are excluded to keep results actionable.

**Sample Output:**
```
schemaname | tablename | size_gb | dead_tuples | live_tuples | bloat_ratio | recommended_action
-----------|-----------|---------|-------------|-------------|-------------|------------------
public     | users     | 2.5     | 150000      | 850000      | 15.0%       | VACUUM
public     | orders    | 8.2     | 45000       | 2100000     | 2.1%        | OK
public     | sessions  | 1.1     | 890000      | 110000      | 89.0%       | VACUUM FULL
```

**Alert Thresholds:**
- **Critical:** Bloat ratio >50% (consider VACUUM FULL)
- **Warning:** Bloat ratio >20% (schedule VACUUM)
- **Monitor:** Bloat ratio >10% (track trend)

**Optimization Actions:**
```sql
-- Regular maintenance VACUUM
VACUUM ANALYZE public.users;

-- Heavy maintenance (schedule during maintenance window)
VACUUM FULL public.sessions;

-- Automated threshold-based maintenance
./maintenance/auto_maintenance.sh --operation vacuum --dead-threshold 20
```

#### `buffer_troubleshoot.sql`
**Purpose:** Shared buffer pool analysis and cache efficiency monitoring
**Requires:** `pg_buffercache` extension (`CREATE EXTENSION pg_buffercache;`)
**Use Cases:**
- Memory configuration optimization
- I/O performance analysis
- Query plan optimization

**Sample Output:**
```
buffer_category        | buffers_used | buffers_total | usage_percent | hit_ratio
-----------------------|--------------|---------------|---------------|----------
Shared Buffers Total   | 98304        | 131072        | 75.0%        | 99.2%
Table Data            | 65536        | 131072        | 50.0%        | 99.5%
Indexes               | 24576        | 131072        | 18.8%        | 98.8%
TOAST                 | 8192         | 131072        | 6.2%         | 97.1%
```

**Optimization Guidelines:**
- **Hit Ratio >95%:** Good cache performance
- **Hit Ratio 90-95%:** Consider increasing shared_buffers
- **Hit Ratio <90%:** Investigate query patterns or increase memory

### 🔄 Replication Monitoring Scripts

#### `replication.sql`
**Purpose:** Comprehensive replication health and lag monitoring
**Use Cases:**
- High availability monitoring
- Backup validation
- Disaster recovery planning

**Sample Output:**
```
application_name | client_addr    | state     | sent_lsn     | write_lag | flush_lag | replay_lag | sync_state
-----------------|----------------|-----------|--------------|-----------|-----------|------------|------------
standby-1        | 192.168.1.10  | streaming | 0/3A000140   | 00:00:01  | 00:00:01  | 00:00:02   | sync
standby-2        | 192.168.1.11  | streaming | 0/39FF8A20   | 00:00:15  | 00:00:16  | 00:00:18   | async
backup-server    | 192.168.1.20  | streaming | 0/39FE2340   | 00:02:30  | 00:02:35  | 00:02:40   | async
```

**Alert Thresholds:**
- **Critical:** Lag >5 minutes on sync replicas
- **Warning:** Lag >1 minute on sync replicas, >10 minutes on async
- **Monitor:** Any disconnected replicas

#### `txid.sql`
**Purpose:** Transaction ID monitoring and wraparound prevention
**Use Cases:**
- Database availability protection
- Maintenance window planning
- Emergency VACUUM scheduling

**Sample Output:**
```
database_name | age        | percent_toward_wraparound | recommended_action | urgency
--------------|------------|---------------------------|-------------------|----------
myapp_prod    | 156000000  | 7.3%                     | Monitor           | Low
myapp_dev     | 890000000  | 41.6%                    | Schedule VACUUM   | Medium  
old_archive   | 1650000000 | 77.2%                    | VACUUM FREEZE NOW | Critical
```

**Critical Actions:**
```sql
-- Emergency transaction wraparound prevention
VACUUM FREEZE;

-- Database-wide aggressive VACUUM
VACUUM FREEZE ANALYZE;

-- Check progress
SELECT datname, age(datfrozenxid) FROM pg_database;
```

### 📡 Connection Monitoring Scripts

#### `connection_pools.sql`
**Purpose:** Connection pooling efficiency and connection pattern analysis
**Use Cases:**
- Connection pool optimization
- Application performance tuning
- Resource capacity planning

**Sample Output:**
```
pool_type    | total_connections | active | idle | idle_in_transaction | max_connections | pool_efficiency
-------------|-------------------|--------|------|-------------------|-----------------|----------------
Application  | 45               | 12     | 30   | 3                 | 100            | 85%
Reporting    | 8                | 2      | 6    | 0                 | 20             | 92%
Background   | 15               | 5      | 10   | 0                 | 25             | 88%
```

**Optimization Guidelines:**
- **Idle in Transaction >5%:** Review application connection handling
- **Pool Efficiency <80%:** Consider adjusting pool size or connection patterns
- **High Active Ratio:** May indicate need for more connections or query optimization

## Usage Patterns

### 1. Daily Monitoring Routine
```bash
#!/bin/bash
# daily_health_check.sh

echo "=== PostgreSQL Daily Health Check $(date) ==="

echo "Checking locks..."
psql -d $DATABASE -f monitoring/locks.sql -o daily_locks.log

echo "Checking replication..."
psql -d $DATABASE -f monitoring/replication.sql -o daily_replication.log

echo "Checking transaction age..."
psql -d $DATABASE -f monitoring/txid.sql -o daily_txid.log

echo "Checking connections..."
psql -d $DATABASE -f monitoring/connection_pools.sql -o daily_connections.log

# Alert on critical findings
if grep -q "Critical" daily_*.log; then
    echo "ALERT: Critical issues found - check logs"
    # Send alert notification
fi
```

### 2. Performance Investigation Workflow
```bash
#!/bin/bash
# performance_investigation.sh

echo "=== Performance Investigation $(date) ==="

# Step 1: Check for blocking queries
echo "1. Checking for blocking queries..."
psql -d $DATABASE -f monitoring/postgres_locking_blocking.sql

# Step 2: Analyze buffer efficiency
echo "2. Analyzing buffer performance..."
psql -d $DATABASE -f monitoring/buffer_troubleshoot.sql

# Step 3: Check for bloating issues
echo "3. Checking for table/index bloating..."
psql -d $DATABASE -f monitoring/bloating.sql

# Step 4: Review connection patterns
echo "4. Analyzing connection patterns..."
psql -d $DATABASE -f monitoring/connection_pools.sql

echo "Investigation complete. Review output for optimization opportunities."
```

### 3. Incident Response Checklist
```bash
#!/bin/bash
# incident_response.sh

echo "=== INCIDENT RESPONSE - PostgreSQL $(date) ==="

# STEP 1: Immediate assessment
echo "STEP 1: Immediate Assessment"
psql -d $DATABASE -c "SELECT NOW() as current_time, version();"
psql -d $DATABASE -c "SELECT count(*) as active_connections FROM pg_stat_activity WHERE state = 'active';"

# STEP 2: Identify blocking queries
echo "STEP 2: Blocking Query Analysis"
psql -d $DATABASE -f monitoring/postgres_locking_blocking.sql

# STEP 3: Check system resources
echo "STEP 3: Resource Analysis"  
psql -d $DATABASE -f monitoring/buffer_troubleshoot.sql

# STEP 4: Replication health (if applicable)
echo "STEP 4: Replication Status"
psql -d $DATABASE -f monitoring/replication.sql

# STEP 5: Transaction wraparound check
echo "STEP 5: Transaction Age Check"
psql -d $DATABASE -f monitoring/txid.sql

echo "=== INCIDENT RESPONSE COMPLETE ==="
echo "Review output and take appropriate action based on findings"
```

## Alert Thresholds

### Critical Alerts (Immediate Action Required)
| Metric | Threshold | Action |
|--------|-----------|--------|
| Blocking duration | >5 minutes | Terminate blocking session |
| Replication lag (sync) | >5 minutes | Check network/load |
| Transaction age | >75% toward wraparound | Emergency VACUUM FREEZE |
| Buffer hit ratio | <85% | Investigate queries/memory |
| Table bloat | >50% | Schedule VACUUM FULL |

### Warning Alerts (Plan Action)
| Metric | Threshold | Action |
|--------|-----------|--------|
| Blocking duration | >1 minute | Monitor and investigate |
| Replication lag (async) | >10 minutes | Check replica health |
| Transaction age | >40% toward wraparound | Schedule maintenance VACUUM |
| Buffer hit ratio | 85-95% | Consider memory tuning |
| Table bloat | 20-50% | Schedule regular VACUUM |

### Monitoring Alerts (Track Trends)
| Metric | Threshold | Action |
|--------|-----------|--------|
| Idle in transaction | >5% of connections | Review application code |
| Index bloat | >10% | Monitor for growth |
| Connection pool efficiency | <80% | Analyze connection patterns |

## Troubleshooting Guide

### Common Issues and Solutions

#### 1. High Lock Contention
**Symptoms:** Multiple blocked queries, slow performance
**Investigation:**
```bash
psql -d $DATABASE -f monitoring/postgres_locking_blocking.sql
```
**Solutions:**
- Optimize query patterns to reduce lock duration
- Consider lock timeout settings
- Implement application-level queueing

#### 2. Replication Lag
**Symptoms:** Standby servers falling behind
**Investigation:**
```bash
psql -d $DATABASE -f monitoring/replication.sql
```
**Solutions:**
- Check network connectivity to replicas
- Review wal_sender_timeout and wal_receiver_timeout
- Consider increasing max_wal_senders

#### 3. High Buffer Misses
**Symptoms:** Poor query performance, high I/O
**Investigation:**
```bash
psql -d $DATABASE -f monitoring/buffer_troubleshoot.sql
```
**Solutions:**
- Increase shared_buffers (typically 25% of RAM)
- Optimize frequently accessed queries
- Consider adding indexes for sequential scans

#### 4. Table Bloating
**Symptoms:** Large table sizes, slow queries
**Investigation:**
```bash
psql -d $DATABASE -f monitoring/bloating.sql
```
**Solutions:**
- Run VACUUM ANALYZE on affected tables
- Adjust autovacuum settings for high-update tables
- Consider VACUUM FULL during maintenance windows

## Integration Examples

### 1. Prometheus/Grafana Integration
```bash
# Export metrics for monitoring systems
./automation/export_metrics.sh --include-monitoring

# Custom metrics collection
psql -d $DATABASE -f monitoring/locks.sql -t -A -F',' > /tmp/postgres_locks.csv
```

### 2. Automated Alerting
```bash
#!/bin/bash
# monitoring_alerts.sh

# Check for critical blocking
BLOCKS=$(psql -d $DATABASE -f monitoring/postgres_locking_blocking.sql -t -c "SELECT COUNT(*) FROM blocked_queries WHERE wait_time > '00:05:00';")

if [ "$BLOCKS" -gt 0 ]; then
    echo "CRITICAL: $BLOCKS long-running blocks detected" | mail -s "PostgreSQL Alert" admin@company.com
fi

# Check replication lag
LAG=$(psql -d $DATABASE -f monitoring/replication.sql -t -c "SELECT MAX(EXTRACT(epoch FROM replay_lag)) FROM pg_stat_replication;")

if (( $(echo "$LAG > 300" | bc -l) )); then
    echo "WARNING: Replication lag exceeds 5 minutes" | mail -s "PostgreSQL Replication Alert" admin@company.com
fi
```

### 3. Health Check Dashboard
```bash
#!/bin/bash
# generate_health_dashboard.sh

cat << EOF > /tmp/postgres_health.html
<!DOCTYPE html>
<html>
<head><title>PostgreSQL Health Dashboard</title></head>
<body>
<h1>PostgreSQL Health Dashboard - $(date)</h1>

<h2>Locks Status</h2>
<pre>$(psql -d $DATABASE -f monitoring/locks.sql -H)</pre>

<h2>Replication Status</h2>
<pre>$(psql -d $DATABASE -f monitoring/replication.sql -H)</pre>

<h2>Connection Status</h2>
<pre>$(psql -d $DATABASE -f monitoring/connection_pools.sql -H)</pre>

</body>
</html>
EOF

echo "Dashboard generated: /tmp/postgres_health.html"
```

## Best Practices

### 1. Monitoring Schedule
- **Every 5 minutes:** Lock status during business hours
- **Every 15 minutes:** Replication lag and connection status
- **Hourly:** Buffer performance and bloating checks
- **Daily:** Transaction age and comprehensive health check

### 2. Alert Fatigue Prevention
- Use tiered alerting (info, warning, critical)
- Implement alert correlation to avoid spam
- Set different thresholds for business vs. off hours

### 3. Historical Trending
- Store monitoring results for trend analysis
- Track performance baselines for comparison
- Use time-series databases for long-term storage

### 4. Documentation Standards
- Document all custom alert thresholds
- Maintain runbooks for common issues
- Keep contact information updated for escalations

This monitoring framework provides comprehensive visibility into PostgreSQL database health and performance, enabling proactive issue detection and rapid incident response.