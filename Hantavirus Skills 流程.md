**Hantavirus Skills 流程**

**总结**
- 目标目录：`/Users/pyl/Desktop/hantavirus/test`
- 总 pipeline 名称：`hantavirus-skills`
- 所有 skill 独立安装到：`<WORKDIR>/.agents/skills/`
- 来源仓库：`https://github.com/lpyhhh/Yu-Lab-Hantavirus.git`
- 本阶段只做 preflight，不做病毒分析，不下载数据库。

**目录结构**
```text
/Users/pyl/Desktop/hantavirus/test/
  .agents/skills/
    hantavirus-skills/
      SKILL.md
    hantavirus-preflight-check/
      SKILL.md
      scripts/hantavirus_preflight.py
      references/db-layout.md
  data/
  results/preflight/
  logs/
  Yu-Lab-Hantavirus/
    environment.yaml
    skills/
  DB/
    kraken2/
    bowtie/
```

**父 Skill：hantavirus-skills**
- 作为总入口。
- 要求用户指定 `WORKDIR`。
- 当前只调用/指导 `hantavirus-preflight-check`。
- 只读取 preflight 小结果文件：
  - `results/preflight/preflight_report.json`
  - `results/preflight/sample_sheet.csv`
  - `results/preflight/unmatched_reads.txt`
  - `logs/preflight.log` 摘要
- preflight 不通过则停止，不进入后续分析。

**子 Skill：hantavirus-preflight-check**
1. 检查 `--workdir`
   - 必须显式指定。
   - 路径不存在则报错停止。

2. 检查 `data/`
   - 必须已存在。
   - 不自动创建。
   - 不存在则状态为 `data_missing`，提示用户先放入双端 reads。

3. 创建输出目录
   - `results/preflight/`
   - `logs/`

4. 克隆或更新 GitHub 仓库
   - 到 `<WORKDIR>/Yu-Lab-Hantavirus/`
   - 检查 `<WORKDIR>/Yu-Lab-Hantavirus/environment.yaml`
   - 检查 `<WORKDIR>/Yu-Lab-Hantavirus/skills/`

5. 安装/sync skills
   - 从 `<WORKDIR>/Yu-Lab-Hantavirus/skills/`
   - 同步到 `<WORKDIR>/.agents/skills/`
   - 每个 skill 保持独立目录，不互相合并。

6. 检查 conda
   - 环境名：`lpy-hantavirus-skills`
   - conda 不存在：`conda_missing`
   - 环境不存在：允许执行  
     `conda env create -f <WORKDIR>/Yu-Lab-Hantavirus/environment.yaml`
   - 环境存在：记录，不强制更新。

7. 检查双端 reads 配对
   - 支持：
     - `*_R1.fastq.gz` / `*_R2.fastq.gz`
     - `*_r1.fastq.gz` / `*_r2.fastq.gz`
     - `*_1.fastq.gz` / `*_2.fastq.gz`
     - `*_R1_001.fastq.gz` / `*_R2_001.fastq.gz`
   - 不重命名原始文件。
   - 输出：
     - `sample_sheet.csv`
     - `unmatched_reads.txt`

8. 检查 `DB/`
   - 不下载数据库。
   - 不验证数据库完整性。
   - 不存在则创建空 `DB/`，状态为 `db_missing`，提示用户按 md 手动下载。

**主命令**
```bash
uv run .agents/skills/hantavirus-preflight-check/scripts/hantavirus_preflight.py check \
  --workdir /Users/pyl/Desktop/hantavirus/test \
  --repo-url https://github.com/lpyhhh/Yu-Lab-Hantavirus.git \
  --env-name lpy-hantavirus-skills
```

**状态码**
```text
success
data_missing
repo_failed
environment_yaml_missing
skills_missing
skills_install_failed
conda_missing
env_create_failed
sample_pairing_failed
db_missing
```

**测试**
- `data/` 不存在：应停止并返回 `data_missing`
- reads 正常配对：生成 `sample_sheet.csv`
- reads 不匹配：生成 `unmatched_reads.txt`
- conda 不存在：返回 `conda_missing`
- `DB/` 不存在：创建空目录并返回 `db_missing`
- 不触发任何病毒分析流程
