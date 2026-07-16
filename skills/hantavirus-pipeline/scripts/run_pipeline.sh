#!/bin/bash
set -euo pipefail

# ==========================================
# 汉坦病毒分析流水线 (单样本)
# 用法: bash run_pipeline.sh <SAMPLE>
# ==========================================

if [ $# -lt 1 ]; then
    echo "Usage: bash run_pipeline.sh <SAMPLE>"
    echo "Example: bash run_pipeline.sh SRR24113203"
    exit 1
fi

SAMPLE="$1"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# ---- 从 config.yaml 加载配置 ----
eval $(python3 -c "
import sys, yaml
cfg = yaml.safe_load(open('${SCRIPT_DIR}/config.yaml'))
base = cfg['project_dir']
fp = cfg['fastp']
bt = cfg['bowtie2']
mh = cfg['megahit']
dm = cfg['diamond']
inp = cfg.get('input', {})

print(f'DATA_DIR={base}/data')
print(f'DB_DIR={base}/DB/diamond')
print(f'RRNA_DB={base}/DB/bowtie2/SILVA')
print(f'RESULTS_DIR={base}/results')
print(f'CLEAN_DIR={base}/results/01_clean_data')
print(f'RRNA_DIR={base}/results/02_rRNA_removed')
print(f'MEGAHIT_DIR={base}/results/03_assembly')
print(f'DIAMOND_DIR={base}/results/04_diamond')
print(f'LOG_DIR={base}/results/log/\"{sys.argv[1]}\"')

print(f'R1_SUFFIXES=\"{inp.get(\"r1_suffixes\", \"_1.fastq.gz\")}\"')
print(f'R2_SUFFIXES=\"{inp.get(\"r2_suffixes\", \"_2.fastq.gz\")}\"')

print(f'FASTP_DETECT_ADAPTER={\"true\" if fp.get(\"detect_adapter_for_pe\") else \"false\"}')
print(f'FASTP_CUT_FRONT={\"true\" if fp.get(\"cut_front\") else \"false\"}')
print(f'FASTP_CUT_TAIL={\"true\" if fp.get(\"cut_tail\") else \"false\"}')
print(f'FASTP_CUT_WINDOW_SIZE={fp[\"cut_window_size\"]}')
print(f'FASTP_CUT_MEAN_QUALITY={fp[\"cut_mean_quality\"]}')
print(f'FASTP_Q={fp[\"qualified_quality_phred\"]}')
print(f'FASTP_U={fp[\"unqualified_percent_limit\"]}')
print(f'FASTP_N={fp[\"n_base_limit\"]}')
print(f'FASTP_L={fp[\"length_required\"]}')
print(f'FASTP_DISABLE_TRIM_POLY_G={\"true\" if fp.get(\"disable_trim_poly_g\") else \"false\"}')

print(f'BOWTIE2_PRESET={bt[\"preset\"]}')

print(f'MEGAHIT_MIN_CONTIG_LEN={mh[\"min_contig_len\"]}')

print(f'DIAMOND_EVALUE={dm[\"evalue\"]}')
print(f'DIAMOND_MAX_TARGET_SEQS={dm[\"max_target_seqs\"]}')
" "$SAMPLE")

# ---- CPU 自动检测 ----
THREADS=$(nproc)

# ---- 创建所有需要的目录 ----
mkdir -p "${CLEAN_DIR}" "${RRNA_DIR}" "${MEGAHIT_DIR}" "${DIAMOND_DIR}" "${LOG_DIR}"

# ---- 使用 YAML 后缀配置定位样本的双端测序文件 ----
cd "${DATA_DIR}"

r1_file=""
r2_file=""

IFS=',' read -ra R1_ARR <<< "$R1_SUFFIXES"
IFS=',' read -ra R2_ARR <<< "$R2_SUFFIXES"

for idx in "${!R1_ARR[@]}"; do
    r1_suffix="${R1_ARR[$idx]}"
    r2_suffix="${R2_ARR[$idx]}"
    # 去掉可能的 . 前缀（如 ".r1.fq.gz" 处理为 "r1.fq.gz" 匹配）
    candidate="${SAMPLE}${r1_suffix}"
    if [ -f "${candidate}" ]; then
        r1_file="${candidate}"
        r2_file="${SAMPLE}${r2_suffix}"
        if [ -f "${r2_file}" ]; then
            break
        else
            r1_file=""  # R2 不存在，重置
        fi
    fi
done

if [ -z "${r1_file}" ]; then
    echo "ERROR: Cannot find paired-end files for sample ${SAMPLE} in ${DATA_DIR}"
    echo "R1 suffixes tried: ${R1_SUFFIXES}"
    echo "R2 suffixes tried: ${R2_SUFFIXES}"
    exit 1
fi

# ==========================================
# 流水线开始
# ==========================================

# ---- fastp 质控 ----
echo -n "fastp ${SAMPLE} ... "
fastp \
    -i "${DATA_DIR}/${r1_file}" -I "${DATA_DIR}/${r2_file}" \
    -o "${CLEAN_DIR}/${SAMPLE}_clean_R1.fq.gz" -O "${CLEAN_DIR}/${SAMPLE}_clean_R2.fq.gz" \
    $([ "${FASTP_DETECT_ADAPTER}" = "true" ] && echo "--detect_adapter_for_pe") \
    $([ "${FASTP_CUT_FRONT}" = "true" ] && echo "--cut_front") \
    $([ "${FASTP_CUT_TAIL}" = "true" ] && echo "--cut_tail") \
    --cut_window_size "${FASTP_CUT_WINDOW_SIZE}" \
    --cut_mean_quality "${FASTP_CUT_MEAN_QUALITY}" \
    -q "${FASTP_Q}" -u "${FASTP_U}" -n "${FASTP_N}" -l "${FASTP_L}" \
    $([ "${FASTP_DISABLE_TRIM_POLY_G}" = "true" ] && echo "--disable_trim_poly_g") \
    -h "${CLEAN_DIR}/${SAMPLE}_fastp.html" -j "${CLEAN_DIR}/${SAMPLE}_fastp.json" \
    -w "${THREADS}" \
    > "${LOG_DIR}/fastp.log" 2>&1
echo "done"

# ---- Bowtie2 去 rRNA ----
echo -n "bowtie2 ${SAMPLE} ... "
bowtie2 "--${BOWTIE2_PRESET}" \
    -x "${RRNA_DB}" \
    -1 "${CLEAN_DIR}/${SAMPLE}_clean_R1.fq.gz" \
    -2 "${CLEAN_DIR}/${SAMPLE}_clean_R2.fq.gz" \
    --un-conc "${RRNA_DIR}/${SAMPLE}_non_rRNA_reads.fastq" \
    -S "${RRNA_DIR}/${SAMPLE}_rRNA_mapped.sam" \
    -p "${THREADS}" \
    > "${LOG_DIR}/bowtie2.log" 2>&1

# 删除 SAM 中间文件
rm -f "${RRNA_DIR}/${SAMPLE}_rRNA_mapped.sam"
echo "done"

# ---- Megahit 组装 ----
echo -n "megahit ${SAMPLE} ... "
rm -rf "${MEGAHIT_DIR}/${SAMPLE}"
megahit \
    -1 "${RRNA_DIR}/${SAMPLE}_non_rRNA_reads.1.fastq" \
    -2 "${RRNA_DIR}/${SAMPLE}_non_rRNA_reads.2.fastq" \
    -o "${MEGAHIT_DIR}/${SAMPLE}" \
    --min-contig-len "${MEGAHIT_MIN_CONTIG_LEN}" \
    --cpu "${THREADS}" \
    > "${LOG_DIR}/megahit.log" 2>&1
echo "done"

# ---- Prodigal 翻译 ----
echo -n "prodigal ${SAMPLE} ... "
CONTIGS_FASTA="${MEGAHIT_DIR}/${SAMPLE}/final.contigs.fa"
PROTEIN_FAA="${MEGAHIT_DIR}/${SAMPLE}/final.contigs_proteins.faa"
if [ -f "${CONTIGS_FASTA}" ]; then
    prodigal -i "${CONTIGS_FASTA}" -a "${PROTEIN_FAA}" -p meta \
        > "${LOG_DIR}/prodigal.log" 2>&1 || true
    echo "done"
else
    echo "WARNING: no contigs found, skipping prodigal"
fi

# ---- Diamond Blastp ----
echo -n "diamond ${SAMPLE} ... "
if [ -f "${PROTEIN_FAA}" ]; then
    for seg in L M S; do
        if [ -f "${DB_DIR}/${seg}.dmnd" ]; then
            diamond blastp \
                --threads "${THREADS}" \
                -d "${DB_DIR}/${seg}.dmnd" \
                -q "${PROTEIN_FAA}" \
                -o "${DIAMOND_DIR}/${SAMPLE}_vs_${seg}.tab" \
                --evalue "${DIAMOND_EVALUE}" \
                --max-target-seqs "${DIAMOND_MAX_TARGET_SEQS}" \
                --outfmt 6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore \
                --header \
                > "${LOG_DIR}/diamond_${seg}.log" 2>&1
        fi
    done
    echo "done"
else
    echo "WARNING: no protein sequences, skipping diamond"
fi

# ---- 最终输出 ----
echo "Pipeline done → ${DIAMOND_DIR}"
