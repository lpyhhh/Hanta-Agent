# Discover Samples — 发现样本

## 执行

```bash
cd <pipeline_root>
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py discover
```

## 逻辑

通过 skill 内的 `config_loader.py` 扫描 `project_dir/data/`，匹配 config.yaml 中
`input.r1_suffixes` / `input.r2_suffixes` 的双端文件对。按样本名字母排序。

## 输出

### stdout — 短摘要

```json
{
  "status": "success",
  "sample_count": 3,
  "samples": ["SRR24113203", "SRR24113204", "SRR24113205"],
  "sample_sheet": ".../results/sample_sheet.csv",
  "pending_list": ".../results/pending_samples.txt"
}
```

### 文件

- `results/sample_sheet.csv` — `sample,r1,r2` 列
- `results/pending_samples.txt` — 每行一个样本名，供 Phase 3 遍历

## 判定

`sample_count > 0` → 继续 Phase 3。
`sample_count == 0` → 报告"data 目录无匹配样本"，停止。
