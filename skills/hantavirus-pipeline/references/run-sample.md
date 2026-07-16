# Run Sample — 处理单个样本

## 执行

```bash
cd <pipeline_root>
conda run -n lpy-hantavirus-skills \
  python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py run-sample -s <SAMPLE>
```

## 步骤（遇错即停）

| 阶段     | 命令                                      | 内容                           |
| -------- | ----------------------------------------- | ------------------------------ |
| pipeline | `bash run_pipeline.sh <S>`                | fastp → bowtie2 → megahit → prodigal → diamond |
| step01   | `python3 step01_merge_diamond.py <S>`     | 合并三片段比对 + 去重 + 提取建树序列 |
| step04   | `python3 step04_build_trees.py <S>`       | MAFFT 比对 → IQ-TREE 建树 → midpoint root |
| step05   | `python3 step05_verify_trees.py <S>`      | 施莽 2025 方案: aLRT 拓扑验证    |
| step06   | `python3 step06_report.py <S>`            | 生成最终 TSV 报告               |

所有底层工具的输出重定向到 `results/log/<SAMPLE>/<stage>.log`。

## 输出

### stdout — 短 JSON

```json
{
  "sample": "SRR24113203",
  "status": "success",
  "steps": {
    "pipeline": {"status": "ok", "log": ".../pipeline.log"},
    "step01":   {"status": "ok", "log": ".../step01.log"},
    "step04":   {"status": "ok", "log": ".../step04.log"},
    "step05":   {"status": "ok", "log": ".../step05.log"},
    "step06":   {"status": "ok", "log": ".../step06.log"}
  },
  "final_report": ".../05_phylogeny/<S>/step06_final_report.tsv",
  "sample_result_dir": ".../05_phylogeny/<S>/",
  "log_dir": ".../results/log/<S>/"
}
```

### 最终产物

`<project_dir>/results/05_phylogeny/<SAMPLE>/step06_final_report.tsv`

含：蛋白总数 / 通过验证数 / 逐段 PASS/FAIL / 下游有参组装参考序列。

## 判定

`status: "success"` → 记录 passed，继续下一个样本。
`status: "failed"` → 记录 failed + 失败步骤，继续下一个样本。

## 注意

- 每个样本占全部 CPU 核心，必须串行执行。
- 不要读取任何 .log 文件进入上下文。失败时用 `tail -20` 查看尾部报错。
- 单样本耗时因数据量而异，可达数小时。
