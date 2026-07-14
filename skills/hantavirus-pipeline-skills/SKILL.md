---
name: hantavirus-pipeline-skills
description: >-
  Run the complete hantavirus assembly and annotation pipeline. 
  First runs quality control (fastp), rRNA depletion (Bowtie2), and de novo assembly (MEGAHIT).
  Then runs annotation (geNomad for viral identification and hmmsearch for Hanta profiling).
---

# Hantavirus Pipeline (Assembly + Annotation)

## Overview

This skill runs a complete per-sample assembly and annotation workflow for hantavirus sequencing data:

1. **Assembly Pipeline:**
   ```text
   paired-end FASTQ.gz -> fastp -> Bowtie2 rRNA depletion -> MEGAHIT -> final.contigs.fa
   ```

2. **Annotation Pipeline:**
   ```text
   final.contigs.fa -> geNomad (viral prediction) & hmmsearch (Hantavirus HMM profiling) -> unique Hanta contigs (.fna)
   ```

## Dependencies

Required Conda environment: `lpy-hantavirus-skills`.

## Quick Start

1. Copy or edit `config.yaml` in this skill directory.
2. Set directory paths: `data_dir`, `results_dir`, and `db_dir`.
3. Run the pipeline:
   ```bash
   cd skills/hantavirus-pipeline-skills
   bash run.sh config.yaml
   ```
