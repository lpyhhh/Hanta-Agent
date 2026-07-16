#!/bin/bash
# ==========================================
# 汉坦病毒系统发育分析 - 一键全流程（自动发现所有样本）
# 用法: bash run_all.sh
# ==========================================
set -eo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# ---- 帮助信息 ----
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: bash run_all.sh"
    echo ""
    echo "  自动扫描 data/ 目录下所有双端测序样本，依次执行："
    echo "    1. 质控 + 去 rRNA + 组装 + Diamond 比对"
    echo "    2. 合并 Diamond 结果 + 提取建树序列"
    echo "    3. MAFFT 比对 + IQ-TREE 建树"
    echo "    4. 拓扑校验"
    echo "    5. 生成最终报告"
    echo ""
    echo "  配置文件: config.yaml（只需修改 project_dir）"
    echo "  输入文件后缀匹配规则在 config.yaml 的 input 段配置"
    echo "  日志输出: results/log/<sample>/"
    exit 0
fi

# ---- 检查 pyyaml 依赖 ----
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: pyyaml not installed. Run: pip install pyyaml"
    exit 1
fi

# ---- 加载配置 ----
eval $(python3 -c "
import sys, yaml
sys.path.insert(0, '${SCRIPT_DIR}')
cfg = yaml.safe_load(open('${SCRIPT_DIR}/config.yaml'))
base = cfg['project_dir']
print(f'PROJECT_DIR={base}')
print(f'DATA_DIR={base}/data')
print(f'DIAMOND_DIR={base}/results/04_diamond')
print(f'PHYLO_DIR={base}/results/05_phylogeny')
print(f'LOG_ROOT={base}/results/log')
") || {
    echo "ERROR: Failed to load config.yaml"
    exit 1
}

# ---- 发现所有样本 ----
echo "============================================"
echo "  Hantavirus Pipeline"
echo "  Project: ${PROJECT_DIR}"
echo "  CPU: $(nproc) cores"
echo "============================================"
echo ""

echo "Scanning data directory: ${DATA_DIR}"
SAMPLES_JSON=$(python3 -c "
import sys, json
sys.path.insert(0, '${SCRIPT_DIR}')
from config_loader import discover_samples, load_config
cfg = load_config()
samples = discover_samples(cfg)
print(json.dumps(samples))
")

SAMPLE_COUNT=$(echo "$SAMPLES_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "$SAMPLE_COUNT" -eq 0 ]; then
    echo "ERROR: No paired-end samples found in ${DATA_DIR}"
    echo "Check input suffixes in config.yaml match your file naming."
    exit 1
fi

echo "Found ${SAMPLE_COUNT} sample(s)"
echo ""

# 提取样本名列表
SAMPLE_NAMES=$(echo "$SAMPLES_JSON" | python3 -c "
import json,sys
samples = json.load(sys.stdin)
for s in samples:
    print(s['sample'])
")

# ---- 逐个处理 ----
TOTAL=$SAMPLE_COUNT
CURRENT=0
PASSED=()
FAILED=()

for SAMPLE in $SAMPLE_NAMES; do
    CURRENT=$((CURRENT + 1))
    FINAL_DIR="${PHYLO_DIR}/${SAMPLE}"

    echo ""
    echo "========================================="
    echo "  [${CURRENT}/${TOTAL}] Processing: ${SAMPLE}"
    echo "========================================="

    # Step 0: Pipeline (fastp → bowtie2 → megahit → diamond)
    echo "--- [1/5] QC + Assembly + Diamond ---"
    if bash "${SCRIPT_DIR}/run_pipeline.sh" "${SAMPLE}"; then
        echo "  [OK] Pipeline done"
    else
        echo "  [FAIL] Pipeline failed for ${SAMPLE}"
        FAILED+=("${SAMPLE}:pipeline")
        continue
    fi

    # Step 1: Merge Diamond
    echo "--- [2/5] Merge Diamond + Extract Tree Seqs ---"
    if python3 "${SCRIPT_DIR}/step01_merge_diamond.py" "${SAMPLE}"; then
        echo "  [OK] Merge done"
    else
        echo "  [FAIL] Merge failed for ${SAMPLE}"
        FAILED+=("${SAMPLE}:merge")
        continue
    fi

    # Step 4: Build Trees
    echo "--- [3/5] MAFFT + IQ-TREE ---"
    if python3 "${SCRIPT_DIR}/step04_build_trees.py" "${SAMPLE}"; then
        echo "  [OK] Trees built"
    else
        echo "  [FAIL] Tree building failed for ${SAMPLE}"
        FAILED+=("${SAMPLE}:trees")
        continue
    fi

    # Step 5: Verify
    echo "--- [4/5] Topology Verification ---"
    if python3 "${SCRIPT_DIR}/step05_verify_trees.py" "${SAMPLE}"; then
        echo "  [OK] Verification done"
    else
        echo "  [FAIL] Verification failed for ${SAMPLE}"
        FAILED+=("${SAMPLE}:verify")
        continue
    fi

    # Step 6: Report
    echo "--- [5/5] Final Report ---"
    if python3 "${SCRIPT_DIR}/step06_report.py" "${SAMPLE}"; then
        echo "  [OK] Report done"
    else
        echo "  [FAIL] Report failed for ${SAMPLE}"
        FAILED+=("${SAMPLE}:report")
        continue
    fi

    PASSED+=("${SAMPLE}")
    echo "  >>> ${SAMPLE} complete → ${FINAL_DIR}/"
done

# ---- 最终汇总 ----
echo ""
echo "============================================"
echo "  Pipeline Complete"
echo "============================================"
echo "  Total:   ${TOTAL}"
echo "  Passed:  ${#PASSED[@]}"
echo "  Failed:  ${#FAILED[@]}"
echo ""

if [ ${#PASSED[@]} -gt 0 ]; then
    echo "Passed samples:"
    for s in "${PASSED[@]}"; do
        echo "  ✓ ${s} → ${PHYLO_DIR}/${s}/"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo "Failed samples:"
    for f in "${FAILED[@]}"; do
        echo "  ✗ ${f}"
    done
fi

echo ""
echo "Logs: ${LOG_ROOT}/"
