---
name: hantavirus-pipeline
description: >-
  Use when running the Hantavirus phylogenetic analysis pipeline on paired-end
  metagenomic reads. Orchestrates preflight checks, sample discovery,
  single-sample processing (QC, assembly, Diamond BLAST, MAFFT, IQ-TREE,
  topology verification), and result collection. All scripts are self-contained
  inside this skill — no external script dependencies.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [bioinformatics, hantavirus, phylogeny, pipeline, metagenomics]
---

# Hantavirus Pipeline Skill

## Overview

自包含的汉坦病毒系统发育分析 pipeline。所有原始脚本、配置加载器、包装脚本
打包在 `scripts/` 目录内。对外只有一个入口：wrapper 的四个子命令。

你只需要告诉我"跑汉坦病毒 pipeline"，我会按顺序完成预检 → 发现样本 → 逐个
处理 → 收集结果。上下文只保留简洁的 JSON 摘要，所有日志写入磁盘。

## When to Use

- "跑汉坦病毒 pipeline"
- "分析我的 hantavirus 样本"
- "检查 pipeline 环境是否就绪"
- "告诉我 sample X 的结果文件在哪"

## Quick Start

```bash
cd /Users/pyl/Desktop/hantavirus-pipeline

# 1. 预检
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py preflight

# 2. 发现样本
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py discover

# 3. 处理单个样本
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py run-sample -s SRR24113203

# 4. 收集结果
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py collect -s SRR24113203
```

## Directory Structure

```
<project_root>/                          # e.g. /Users/pyl/Desktop/hantavirus-pipeline
├── results/                             # pipeline 级输出
│   ├── preflight/preflight_report.json
│   ├── sample_sheet.csv
│   ├── pending_samples.txt
│   └── log/<sample>/                    # 每样本每步骤的日志
└── skills/hantavirus-pipeline/          # ← 本 Skill（自包含，可直接拷贝复用）
    ├── SKILL.md                         # 你正在读的文件
    ├── config.yaml                      # ★ 唯一人工维护的配置（与 scripts/ 同级）
    ├── scripts/                         # 原始脚本 + wrapper
    │   ├── hantavirus_skill_runner.py   # 入口（四个子命令）
    │   ├── config_loader.py             # 配置加载
    │   ├── config.yaml                  # 自动从 ../config.yaml 同步
    │   ├── run_pipeline.sh              # QC + 组装 + Diamond
    │   ├── step01_merge_diamond.py      # 合并比对结果
    │   ├── step04_build_trees.py        # MAFFT + IQ-TREE
    │   ├── step05_verify_trees.py       # 拓扑验证
    │   └── step06_report.py             # 最终报告
    └── references/                      # 子流程详细文档
        ├── preflight.md
        ├── discover-samples.md
        ├── run-sample.md
        └── collect-results.md
```

## Workflow（Agent 执行流程）

加载本 Skill 后，按 4 个 Phase 顺序执行。每个 Phase 完成后才进入下一个。

### Phase 1: Preflight（预检）

见 `references/preflight.md`。

执行后获取 `overall_pass: true/false`。若 false，报告失败的检查项并停止。
不自动安装任何依赖。

### Phase 2: Discover Samples（发现样本）

见 `references/discover-samples.md`。

获取 JSON 摘要（样本数量 + 名称列表）。若为 0，报告并停止。

### Phase 3: Process Samples（逐个处理）

见 `references/run-sample.md`。

对 pending_samples.txt 中的每个样本，**串行**执行（全核跑 MAFFT/IQ-TREE，并行会
导致 CPU 争抢）。每个样本返回短 JSON：

```json
{
  "sample": "SRR24113203",
  "status": "success",
  "final_report": "/path/to/step06_final_report.tsv",
  "log_dir": "/path/to/log/SRR24113203/"
}
```

失败样本记录后继续下一个。上下文不加载任何日志内容。

### Phase 4: Collect Results（收集结果）

见 `references/collect-results.md`。

对每个已完成的样本验证最终文件存在。最终输出汇总表（纯文本）：

```
Hantavirus Pipeline Complete
=============================
Total: 3  Passed: 2  Failed: 1

Passed:
  SRR24113203 → step06_final_report.tsv

Failed:
  SRR24113205 → step01 failed (log: results/log/SRR24113205/step01.log)
```

## Configuration

唯一的配置文件：`skills/hantavirus-pipeline/config.yaml`（与 scripts/ 同级）。
只需修改两处：

| 字段         | 说明                                     |
| ------------ | ---------------------------------------- |
| `project_dir`| 数据/数据库/结果存放的根目录              |
| `conda_env`  | conda 环境名（默认 lpy-hantavirus-skills）|

其他参数（fastp、bowtie2、megahit、diamond 阈值等）保持默认即可。

wrapper 启动时自动同步主配置到 `scripts/config.yaml`，config_loader.py 无需改动。

## Error Handling

| 场景                       | 行为                             |
| -------------------------- | -------------------------------- |
| 预检失败                   | 列出失败项，停止                 |
| 无样本发现                 | 报告，停止                       |
| 单个样本中途失败           | 记录失败，继续下一个             |
| conda 环境缺失             | 报告名称，停止（不自动创建）     |
| 数据库文件缺失             | 报告路径，停止                   |
| 所有样本失败               | 汇总全部失败原因，停止           |

## Common Mistakes

1. **并行跑多个样本。** MAFFT/IQ-TREE 用全部 CPU 核心，并行会导致严重争抢和 OOM。
2. **把日志加载进上下文。** 日志可达数百 MB。失败时用 `tail -20 <log>` 只看尾部。
3. **忘记先跑 preflight。** 环境/数据库缺失会导致神秘的运行时错误。
4. **config.yaml 没改 project_dir。** 默认路径是 `/media/jjz/lpy/lpy-yu/hantavirus`，
   你需要改成自己的数据路径。

## Verification Checklist

- [ ] `config.yaml` 中 `project_dir` 指向正确的数据路径
- [ ] `project_dir/data/` 下有双端测序文件
- [ ] `project_dir/DB/diamond/{L,M,S}.dmnd` 和 `.faa` 存在
- [ ] `project_dir/DB/bowtie2/SILVA*.bt2` 存在
- [ ] `conda env list` 中存在 `lpy-hantavirus-skills`
- [ ] `preflight` 命令输出 `overall_pass: true`
