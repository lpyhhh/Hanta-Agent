# Yu-Lab-Hantavirus

本仓库包含 Yu-Lab 团队在 Hantavirus 相关的代码、数据和文档。

## 🎯 近期工作与研究目的
- **近期工作**：搭建 Hantavirus 病毒分析流程（数据预处理、基因组组装、注释），为后续知识图谱与大语言模型提供数据支撑。
- **研究目的**：针对 2026 年 6 月的 Hantavirus 疫情，深入研究其传播机制和致病机理，为公共卫生防控提供科学依据。

## 🚀 快速开始

### 1. 环境准备
确保已安装 `conda`，然后克隆仓库并创建环境：
```bash
git clone https://github.com/lpyhhh/Yu-Lab-Hantavirus.git
cd Yu-Lab-Hantavirus
conda env create -f environment.yml
```

### 2. 数据库与数据准备
- **数据库**：将所需 DB 下载至 `Yu-Lab-Hantavirus/DB` 目录下（具体 DB 待定）。
- **数据存放**：下机原始数据放入 `Yu-Lab-Hantavirus/data`。
- **命名规范**：支持 `样本名_1.fastq.gz`, `_r1.fq.gz`, `_R1.fq.gz` 等格式（详见 `config.yaml`，也可以自定义添加格式）。

### 3. Skills 运行方式
1. 编辑 `skills/hantavirus-assembly-skills/contig.yaml`，配置 `data_dir`、`results_dir` 和 `db_dir`（默认参数基于广泛hantavirus文献调研设置）。
2. 在 AI 对话框中输入以下 prompt：
   > 用 skills/hantavirus-assembly-skills 处理数据，同时使用父子 agent 运行

## ⏱️ 性能测试
- **测试数据**：两个宏转录组学下机数据
- **测试环境**：32 CPU, 128GB RAM
- **Pipeline 用时**：0h 29m 1s  
1.1G IM22A003_r1.fq.gz  
1015M IM22A003_r2.fq.gz  
362M IM22A007_r1.fq.gz  
331M IM22A007_r2.fq.gz
