---
name: hantavirus-skills
description: >-
  Entry skill for the Hantavirus pipeline. It requires an explicit WORKDIR,
  runs only the hantavirus-preflight-check phase, reads small preflight result
  files, and stops when preflight is not successful.
---

# Hantavirus Skills

## Overview
`hantavirus-skills` is the top-level entry point for this workflow.

Current scope is intentionally narrow:
- require an explicit `WORKDIR`
- run only `hantavirus-preflight-check`
- do not start downstream analysis
- do not download databases

If preflight does not return `success`, stop and report the blocking status.

## Dependencies
- `hantavirus-preflight-check`: performs workspace validation, repository sync,
  Conda checks, read pairing, and DB directory checks.

## Quick Start
Ask the agent to run Hantavirus preflight in a specific working directory.

Example:

```text
Run hantavirus preflight for WORKDIR=/Users/pyl/Desktop/hantavirus/test
```

## Workflow
1. Require the user to provide `WORKDIR` explicitly.
2. Ensure the preflight skill is available at `<WORKDIR>/.agents/skills/`.
3. Run:

```bash
uv run .agents/skills/hantavirus-preflight-check/scripts/hantavirus_preflight.py check \
  --workdir <WORKDIR> \
  --repo-url https://github.com/lpyhhh/Yu-Lab-Hantavirus.git \
  --env-name lpy-hantavirus-skills \
  --output <WORKDIR>/results/preflight/preflight_report.json
```

4. Read only these small outputs:
   - `results/preflight/preflight_report.json`
   - `results/preflight/sample_sheet.csv`
   - `results/preflight/unmatched_reads.txt`
   - a brief summary from `logs/preflight.log`
5. If status is not `success`, stop. Do not enter downstream analysis.

## Common Mistakes
- Omitting `WORKDIR`.
- Assuming preflight should create `data/` automatically.
- Continuing into analysis when preflight returned a blocking status.
