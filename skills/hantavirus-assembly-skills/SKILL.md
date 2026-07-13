---
name: hantavirus-assembly-skills
description: >-
  Run the hantavirus paired-end sequencing assembly pipeline for recurring batch
  jobs. Use this skill when raw gzipped FASTQ pairs must be quality-filtered with
  fastp, depleted of rRNA with Bowtie2, assembled with MEGAHIT, and reported as
  per-sample final.contigs.fa files plus logs and machine-readable status.
---

# Hantavirus Assembly

## Overview

This skill runs a per-sample short-read assembly workflow for hantavirus sequencing data:

```text
paired-end FASTQ.gz -> fastp -> Bowtie2 rRNA depletion -> MEGAHIT -> final.contigs.fa
```

The workflow is designed for recurring batch processing. Samples are discovered from the configured input directory and processed independently. A data or tool failure for one sample is recorded and does not prevent later samples from running. The existing shell scripts are the execution authority; do not reimplement the pipeline in the agent response.

The skill is installed at a custom path selected by the user. In the examples below, `<skill-dir>` means the directory containing this `SKILL.md`, `run.sh`, and `config.yaml`.

## Dependencies

The workflow requires the pre-existing Conda environment `lpy-hantavirus-skills` with:

- `fastp`
- `bowtie2`
- `megahit`
- `python3`
- `gzip`
- `awk`
- Bash 4.0 or newer

It also requires:

- A directory containing paired-end `.fastq.gz` or `.fq.gz` files.
- A Bowtie2 rRNA reference index, normally SILVA.
- Sufficient local storage for intermediate reads, SAM/output files, logs, and assembled contigs.

`run.sh` attempts to invoke the Conda environment through `conda run -n`. If `conda` is unavailable, it runs in the current environment and prints a warning. The agent should verify the required executables and reference index before starting a production batch.

## Quick Start

1. Copy or edit `config.yaml` in this skill directory.
2. Set `data_dir`, `results_dir`, and `db_dir` to real absolute paths.
3. Confirm the input pairs and Bowtie2 index exist.
4. Run the batch:

```bash
cd <skill-dir>
bash ./run.sh ./config.yaml
```

The command prints the final pipeline log. The primary assembly result for sample `SAMPLE` is:

```text
{results_dir}/megahit/SAMPLE/final.contigs.fa
```

## Utility Scripts

### `run.sh`

Recommended entry point. Usage:

```bash
bash run.sh [config.yaml]
```

The configuration argument may be an absolute path or a path resolvable from the current directory or skill directory. This wrapper is preferred because it handles the Conda environment invocation.

### `scripts/assembly.sh`

Core pipeline implementation. Usage:

```bash
bash scripts/assembly.sh /absolute/path/to/config.yaml
```

It reads the supported YAML configuration, discovers paired samples, runs the three processing stages, writes logs and status, and prints the final pipeline log. Use this direct entry point only when the required environment is already active.

### `scripts/runtime_report.sh`

Converts the `total_seconds` field from a runtime log into `HH:MM:SS` format:

```bash
bash scripts/runtime_report.sh /path/to/runtime.log
```

The input must contain a tab-separated line beginning with `total_seconds`.

## Workflow

1. **Resolve configuration**
   - Resolve the supplied configuration path.
   - Require non-empty `data_dir` and `results_dir`.
   - Resolve the Bowtie2 index as `{db_dir}/bowtie2/SILVA`.
   - Read thread, fastp, Bowtie2, MEGAHIT, input suffix, and cleanup settings.

2. **Prepare output directories**
   - Create `fastp/`, `rRNA/`, `megahit/`, and `logs/` below `results_dir`.
   - Start a new `logs/pipeline.log` containing the configuration and run metadata.

3. **Discover paired samples**
   - Match R1 files using the configured `input.r1_suffixes` values.
   - Derive the sample name from the R1 basename and locate the corresponding R2 using the paired suffix at the same position in `input.r2_suffixes`.
   - Duplicate sample names and missing R2 files are recorded as sample failures.

4. **Validate each sample**
   - Test both compressed files with `gzip -t`.
   - Count records and require matching R1/R2 read counts.
   - Invalid gzip data, malformed FASTQ record counts, and read-count mismatches are logged and skipped.

5. **Run fastp**
   - Trim and quality-filter paired reads according to the `fastp` section of the configuration.
   - Write cleaned reads and fastp reports under `fastp/`.
   - Capture tool output in `logs/{sample}.fastp.log`.

6. **Remove rRNA reads with Bowtie2**
   - Align cleaned reads against the resolved rRNA index.
   - Keep unaligned paired reads for assembly.
   - Capture tool output in `logs/{sample}.bowtie2.log`.

7. **Assemble with MEGAHIT**
   - Assemble the non-rRNA paired reads using the configured k-mer range, minimum contig length, memory fraction, and thread count.
   - Write the result to `megahit/{sample}/final.contigs.fa`.
   - Capture tool output in `logs/{sample}.megahit.log`.

8. **Finalize the batch**
   - Optionally remove fastp and rRNA intermediate directories according to `cleanup` settings.
   - Append totals, failures, failed sample names, and runtime to `logs/pipeline.log`.
   - Write `logs/.pipeline_status.txt` for downstream automation.

## Output Contract

The stable outputs are:

```text
{results_dir}/
├── megahit/{sample}/
│   └── final.contigs.fa
└── logs/
    ├── pipeline.log
    ├── {sample}.detail.log
    ├── {sample}.fastp.log
    ├── {sample}.bowtie2.log
    ├── {sample}.megahit.log
    └── .pipeline_status.txt
```

`fastp/` and `rRNA/` may also remain when cleanup is disabled. The status file uses key-value lines including:

```text
status=ok|partial
total=<number>
done=<number>
failed=<number>
pipeline_seconds=<number>
results_dir=<path>
failed_samples=<space-separated names>
```

`failed_samples` is present only when one or more samples fail. A batch with any failed sample has `status=partial`; the process still completes the remaining discovered samples.

## Failure Handling

- Configuration path missing, or required `data_dir`/`results_dir` values missing: stop before sample processing with exit code 1.
- Missing input pairs, duplicate sample names, invalid gzip files, and read-count mismatches: log the sample failure and continue with the batch.
- fastp, Bowtie2, or MEGAHIT failure: log the command output path, mark the sample failed, and continue with the next sample.
- No full assembly should be declared successful solely because the process exits successfully; inspect `logs/.pipeline_status.txt` and confirm each expected `final.contigs.fa` exists.

Before a production batch, validate global prerequisites once: required executables, Bowtie2 index files, input directory readability, output storage, and sufficient disk space. This prevents avoidable per-sample failures during repeated runs.

## Common Mistakes

1. **Using relative paths unintentionally**: use absolute `data_dir`, `results_dir`, and `db_dir` values in recurring jobs.
2. **Incorrect index location**: automatic resolution expects `{db_dir}/bowtie2/SILVA`; set the database directory accordingly.
3. **Mismatched suffix arrays**: `input.r1_suffixes` and `input.r2_suffixes` must contain the same number of comma-separated entries, in matching order.
4. **Missing paired files**: an R1 file is not sufficient; the derived R2 path must exist with the paired suffix.
5. **Uncontrolled resource use**: `threads: auto` uses all available CPUs. Set a fixed thread count for shared systems and reproducible batch scheduling.
6. **Deleting intermediates too early**: disable cleanup when investigating fastp or Bowtie2 failures and enable it only after the batch contract is verified.
