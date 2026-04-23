# Contributing to pgtools

We welcome contributions from the PostgreSQL and TimescaleDB communities! This document provides guidelines for contributing to the `pgtools` "First Responder" Toolbelt.

The goal of this project is to create a safe, reliable, and easy-to-use set of diagnostic scripts for support engineers and DBAs to use when triaging production database issues.

## Core Principles

All contributions must adhere to a strict **"Zero-Harm"** policy.

1.  **Read-Only**: Scripts must *never* perform write operations. No `CREATE TABLE`, `ALTER`, `UPDATE`, `DELETE`, or `TRUNCATE`. Temporary tables should be avoided unless absolutely necessary and lightweight.
2.  **Lightweight**: Queries must be efficient and avoid expensive operations that could impact a heavily loaded customer system.
3.  **No Heavy Dependencies**: We stick to `bash` and `psql`. No Python, Go, or other languages that require complex installation.
4.  **Safety First**: All queries are executed via the `pgtools.sh` wrapper, which enforces a short `statement_timeout` and `lock_timeout`.

## Getting Started

```bash
# Fork the repository on GitHub
# Clone your fork
git clone https://github.com/your-username/pgtools.git
cd pgtools

# Create a feature branch
git checkout -b feature/your-feature-name
```

## Types of Contributions

### 🔧 New Scripts and Tools
**What we're looking for:**
- Monitoring scripts for specific PostgreSQL features
- Performance analysis tools
- Administration utilities  
- Security audit scripts
- Troubleshooting aids
- Automation tools

### 📚 Documentation and Examples
**What we need:**
- Real-world usage examples
- Industry-specific workflows
- Troubleshooting scenarios
- Configuration best practices
- Performance tuning guides

### 🐛 Bug Fixes and Improvements
**Areas for improvement:**
- PostgreSQL version compatibility
- Performance optimization of existing scripts
- Output formatting enhancements
- Error handling improvements
- Cross-platform compatibility

### 🔄 Workflow Contributions
**Operational workflows we'd love to see:**
- Disaster recovery procedures
- Maintenance automation
- Monitoring integration guides
- Incident response playbooks
- Compliance audit procedures

## Script Standards

### Required Header Format
Every script must include a comprehensive header:

```sql
/*
 * Script: script_name.sql
 * Purpose: Brief description of what the script does
 * 
 * ANNOTATED EXAMPLE:
 *   # Basic usage
 *   psql -d database_name -f path/to/script.sql
 *
 *   # Advanced usage with filtering
 *   psql -d database_name -f path/to/script.sql | grep "CRITICAL"
 *
 * SAMPLE OUTPUT:
 *   column1    | column2      | column3     | description
 *   -----------|--------------|-------------|-------------
 *   value1     | value2       | value3      | Sample data row
 *
 * INTERPRETATION:
 *   - Explain what different output values mean
 *   - Describe normal vs. concerning values
 *   - Provide actionable guidance
 *
 * Requirements:
 *   - PostgreSQL version (e.g., 10+, 12+)
 *   - Required privileges (e.g., pg_monitor role)
 *   - Required extensions (e.g., pg_stat_statements)
 *
 * Author: Your Name <your.email@company.com>
 * Version: 1.0
 * Last Modified: YYYY-MM-DD
 */
```

### Code Style Guidelines
```sql
-- Use clear, descriptive column aliases
SELECT 
    schemaname AS schema_name,
    tablename AS table_name,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(schemaname||'.'||tablename) DESC
LIMIT 50;
```

## Testing Requirements

### PostgreSQL Version Compatibility
Test your scripts across supported PostgreSQL versions (10, 11, 12, 13, 14, 15):

```bash
# Use Docker for testing different versions
docker run -d --name pg10-test -e POSTGRES_PASSWORD=test postgres:10-alpine
docker run -d --name pg15-test -e POSTGRES_PASSWORD=test postgres:15-alpine

# Test your script
psql -h localhost -p 5432 -U postgres -d postgres -f your_script.sql
```

### Test Checklist
- [ ] Script executes without errors on PostgreSQL 15+
- [ ] Output is properly formatted and readable
- [ ] Script handles edge cases (empty tables, no data, etc.)
- [ ] Performance is acceptable on databases with 1M+ rows
- [ ] Required privileges are minimal and documented
- [ ] Script works with both superuser and limited privileges (where applicable)

## Submission Process

### Pull Request Guidelines

1. **Create Feature Branch**
   ```bash
   git checkout -b feature/descriptive-name
   ```

2. **Make Your Changes**
   - Follow coding standards
   - Add comprehensive tests
   - Update documentation
   - Include usage examples

3. **Test Thoroughly**
   ```bash
   # Run existing test suite
   ./automation/test_pgtools.sh
   
   # Test your specific changes
   psql -d test_db -f your_new_script.sql
   
   # Recommended: mirror CI locally
   ./scripts/precommit_checks.sh --database test_db
   ```

4. **Submit Pull Request**
   - Use descriptive title
   - Include detailed description
   - Reference any related issues
   - Update CHANGELOG.md
   - Update relevant README files

### Pull Request Template
```markdown
## Description
Brief description of changes and motivation.

## Type of Change
- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Documentation update
- [ ] Workflow improvement

## Testing
- [ ] Tested on PostgreSQL 15+
- [ ] Tested with sample data
- [ ] Performance tested on large dataset
- [ ] Documentation examples verified

## Checklist
- [ ] Code follows project style guidelines
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] No breaking changes (or properly documented)
```

## Documentation Standards

### README Updates
When adding new scripts, update the relevant README files:

1. **Main README.md**: Add script to appropriate category
2. **Directory README.md**: Add detailed description and examples
3. **CHANGELOG.md**: Document your additions

### Example Documentation
```markdown
#### `your_new_script.sql`
**Purpose:** Brief description of what the script does
**Use Cases:**
- Specific use case 1
- Specific use case 2

**Sample Output:**
\`\`\`
column1    | column2    | description
-----------|------------|-------------
value1     | value2     | Sample data
\`\`\`

**Alert Thresholds:**
- **Critical:** > X (immediate action required)
- **Warning:** X-Y (monitor closely)
- **Normal:** < Y (no action needed)
```

## Community Guidelines

### Code of Conduct
- **Be respectful** and inclusive in all interactions
- **Help newcomers** learn PostgreSQL and contribute effectively
- **Provide constructive feedback** in reviews and discussions
- **Share knowledge** and learn from others' experiences

### Getting Help
**New to PostgreSQL?**
- Check [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- Review existing pgtools scripts for patterns
- Ask questions in GitHub Issues

**Need help with implementation?**
- Open a draft PR for early feedback
- Ask for help in GitHub Discussions
- Reference similar existing scripts

## Recognition

Contributors will be recognized in:
- **Release notes**: Major contributions highlighted
- **Script headers**: Author attribution in contributed scripts
- **Community showcase**: Outstanding contributions featured

## Questions?

Open an issue with the "question" label or start a discussion in GitHub Discussions.

Thank you for contributing to pgtools! Your expertise helps make PostgreSQL administration easier for the entire community.