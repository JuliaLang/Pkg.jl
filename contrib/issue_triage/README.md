# GitHub Issues Triaging System for Pkg.jl

Fast and efficient tool for collecting and analyzing open issues from the JuliaLang/Pkg.jl repository using GitHub's GraphQL API.

## Features

- **Lightning Fast**: Fetches ~572 issues with comments in under 1 minute
- **Complete Data**: Full issue content, all comments, reactions, labels, and metadata
- **CSV Export**: Clean, parseable format with proper text escaping
- **Triaging Insights**: Automatic analysis and recommendations

## Quick Start

1. **Install dependencies**:
   ```bash
   julia --project=. -e 'using Pkg; Pkg.instantiate()'
   ```

2. **Run the fetcher**:
   ```bash
   julia --project=. fetch_issues.jl
   ```

3. **Verify output** (optional):
   ```bash
   julia --project=. verify_csv.jl
   ```

**Requirements**: Set `PERSONAL_ACCESS_TOKEN` environment variable with your GitHub token.

## Output

Generates `pkg_issues.csv` with comprehensive issue data:

- **Basic info**: Number, title, author, state, dates
- **Content**: Full issue body and all comments with authors
- **Metadata**: Labels, assignees, milestones, reactions
- **Analytics**: Age, days since update, engagement metrics

## Current Repository Status

Latest fetch (July 3, 2025):
- **572 open issues** spanning 9+ years (2016-2025)
- **389 issues have comments** (68% engagement rate)
- **487 stale issues** (>1 year old, >90 days since update)
- **396 unlabeled issues** need categorization
- 🔥 **67 issues** have high engagement (10+ comments or 5+ reactions)
- 🏷️ **396 issues** need labels for categorization
- 👤 **560 issues** need assignees

### Most Common Labels
1. **bug** (34 issues)
2. **enhancement** (23 issues)
3. **feature request** (23 issues)
4. **documentation** (22 issues)
5. **precompile** (13 issues)

## Files

### Core Scripts
- **`fetch_issues.jl`**: Main script that fetches all open issues and exports to CSV
- **`verify_csv.jl`**: Verification script that analyzes the generated CSV data

### Configuration
- **`Project.toml`**: Julia project dependencies
- **`Manifest.toml`**: Locked dependency versions

### Output
- **`pkg_issues.csv`**: Comprehensive CSV export of all issue data (572 issues × 25 columns)

## CSV Column Reference

### Basic Information
- `number`: GitHub issue number
- `title`: Issue title
- `state`: Issue state (always "open" for this dataset)
- `author`: GitHub username of issue creator
- `url`: Web URL to view the issue
- `api_url`: GitHub API endpoint for the issue

### Organization
- `assignees`: Semicolon-separated list of assigned users
- `labels`: Semicolon-separated list of applied labels
- `milestone`: Associated milestone title

### Engagement Metrics
- `comments_count`: Total number of comments
- `reactions_total`: Total reaction count
- `reactions_plus_one`: 👍 reactions
- `reactions_minus_one`: 👎 reactions
- `reactions_laugh`: 😄 reactions
- `reactions_hooray`: 🎉 reactions
- `reactions_confused`: 😕 reactions
- `reactions_heart`: ❤️ reactions
- `reactions_rocket`: 🚀 reactions
- `reactions_eyes`: 👀 reactions

### Temporal Data
- `created_at`: Issue creation timestamp
- `updated_at`: Last activity timestamp
- `age_days`: Days since creation
- `days_since_update`: Days since last activity

### Content
- `body_preview`: First 200 characters of issue description
- `locked`: Whether the issue is locked for comments

## Rate Limiting & API Usage

The script uses GitHub's GraphQL API and respects rate limits:

- **Authentication**: Uses personal access token for 5,000 requests/hour
- **Monitoring**: Tracks remaining requests and automatically waits when approaching limits
- **Retries**: Implements exponential backoff for failed requests
- **Efficient Batching**: Fetches issues and comments together in optimized queries

## Example Usage

### Finding High-Priority Issues

```bash
# Issues with lots of engagement
grep -E "^[0-9]+.*,[0-9]{2,}," pkg_issues.csv | head -10

# Very old issues
sort -t, -k11nr pkg_issues.csv | head -20

# Recent issues needing labels
awk -F, '$6=="" && $11<30' pkg_issues.csv
```

### CSV Analysis with Common Tools

```bash
# Count issues by author
cut -d, -f4 pkg_issues.csv | sort | uniq -c | sort -nr | head -10

# Issues created this year
awk -F, '$9 ~ /^2025/' pkg_issues.csv | wc -l

# Find bug reports
grep -i "bug" pkg_issues.csv
```

## Troubleshooting

- **Rate limit errors**: The script will automatically wait for rate limit reset
- **Network issues**: The script includes retry logic with exponential backoff
- **Large repositories**: Adjust `SAMPLE_SIZE` for testing with smaller datasets

---
