# Preflight — 环境预检

## 执行

```bash
cd <pipeline_root>
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py preflight
```

## 检查项

| 检查             | 验证内容                                              |
| ---------------- | ----------------------------------------------------- |
| conda_env        | `lpy-hantavirus-skills` 存在于 `conda env list`       |
| scripts          | run_pipeline.sh, config_loader.py, step01~06 在 scripts/ 内 |
| config_yaml      | 主 config.yaml 存在                                   |
| data_dir         | `project_dir/data/` 目录存在                          |
| diamond_db       | `DB/diamond/{L,M,S}.dmnd` + `{L,M,S}.faa` 全部存在   |
| bowtie2_silva_db | `DB/bowtie2/SILVA*.bt2` 索引文件存在                  |
| cli_tools        | fastp, bowtie2, megahit, diamond, prodigal, mafft, iqtree 可用 |
| python_packages  | yaml, pandas, ete3 可 import（在 conda 环境中）       |

## 输出

### stdout — 短摘要

```json
{
  "status": "success",
  "overall_pass": false,
  "report_path": ".../results/preflight/preflight_report.json",
  "failures": ["conda_env", "bowtie2_silva_db"]
}
```

### 文件 — 完整报告

`results/preflight/preflight_report.json` — 含所有检查项详情。

## 判定

`overall_pass: true` → 继续 Phase 2。
`overall_pass: false` → 列出 `failures` 数组中的检查项，停止。不自动安装。
