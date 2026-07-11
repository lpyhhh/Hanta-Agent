---
name: hantavirus-preflight-check
description: >-
  Validates a Hantavirus working directory before analysis by checking data,
  preparing output folders, cloning or updating the source repository,
  syncing skills, checking Conda and the target environment, pairing read
  files, and ensuring the DB directory exists without downloading databases.
---

# Hantavirus Preflight Check

## Overview
This skill performs the preflight phase for the Hantavirus workflow.

It does all of the following:
- requires an explicit `--workdir`
- checks that `data/` already exists
- creates `results/preflight/` and `logs/`
- clones or updates `Yu-Lab-Hantavirus`
- verifies `environment.yaml` and `skills/`
- syncs repository skills into `<WORKDIR>/.agents/skills/`
- checks Conda and `lpy-hantavirus-skills`
- pairs FASTQ read files without renaming them
- creates an empty `DB/` directory if missing

It does not do virus analysis, database download, or database integrity
validation.

## Dependencies
None.

## Quick Start
```bash
uv run .agents/skills/hantavirus-preflight-check/scripts/hantavirus_preflight.py check \
  --workdir /Users/pyl/Desktop/hantavirus/test \
  --repo-url https://github.com/lpyhhh/Yu-Lab-Hantavirus.git \
  --env-name lpy-hantavirus-skills \
  --output /Users/pyl/Desktop/hantavirus/test/results/preflight/preflight_report.json
```

## Utility Scripts
### `check`
Run the full preflight validation.

Required arguments:
- `--workdir`
- `--repo-url`
- `--env-name`
- `--output`

Generated files:
- `<WORKDIR>/results/preflight/preflight_report.json`
- `<WORKDIR>/results/preflight/sample_sheet.csv`
- `<WORKDIR>/results/preflight/unmatched_reads.txt`
- `<WORKDIR>/logs/preflight.log`

## Common Mistakes
- Pointing `--workdir` at a path that does not exist.
- Expecting the script to create `data/` automatically.
- Treating `db_missing` as success and starting downstream analysis anyway.
