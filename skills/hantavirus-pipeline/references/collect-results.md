# Collect Results — 收集结果

## 执行

```bash
cd <pipeline_root>
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py collect -s <SAMPLE>
```

## 校验

检查三个文件是否存在且 size > 0：

| 文件                                | 来源    |
| ----------------------------------- | ------- |
| `05_phylogeny/<S>/step06_final_report.tsv` | step06 |
| `05_phylogeny/<S>/step05_verification.csv` | step05 |
| `05_phylogeny/<S>/step01_merged_hits.csv`   | step01 |

## 输出

```json
{
  "sample": "SRR24113203",
  "complete": true,
  "files": {
    "final_report": {"path": "...", "exists": true, "size": 4521},
    "verification": {"path": "...", "exists": true, "size": 2840},
    "merged_hits":  {"path": "...", "exists": true, "size": 1234}
  },
  "result_dir": ".../05_phylogeny/SRR24113203/"
}
```

## 判定

`complete: true` → 样本计入 passed。
`complete: false` → 样本计入 failed（文件缺失或为空）。

## 注意

- 不读取文件内容，只检查存在性和大小。
- 不验证分析结果是否科学正确——检查 `step05_verification.csv` 的 Passed 列。
