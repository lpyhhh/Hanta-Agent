#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# hantavirus-assembly-skills
# Pipeline: fastp (QC/trim) → Bowtie2 (rRNA removal) → MEGAHIT (assembly)
# Usage: assembly.sh [config.yaml]
#   Accepts an absolute path, a relative path, or a bare filename.
#   Bare filename resolves relative to this script's directory.
# ============================================================

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config_input="${1:-config.yaml}"
if [[ -f "${config_input}" ]]; then
    config_file="${config_input}"
else
    config_file="${script_dir}/${config_input}"
fi

if [[ ! -f "${config_file}" ]]; then
    echo "ERROR: config file not found: ${config_file}" >&2
    exit 1
fi

# ========== YAML Parser ==========
cfg() {
    local key="$1"
    local default="${2:-}"
    python3 - "$config_file" "$key" "$default" <<'PY'
import sys

path, wanted, default = sys.argv[1:4]

def parse_scalar(value):
    value = value.strip()
    if not value:
        return ""
    if (value[0:1], value[-1:]) in [("'", "'"), ('"', '"')]:
        return value[1:-1]
    return value

values = {}
parents = []
with open(path, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.split("#", 1)[0].rstrip("\n")
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent % 2:
            raise SystemExit(f"ERROR: only 2-space YAML indentation is supported: {raw.rstrip()}")
        level = indent // 2
        line = line.strip()
        if ":" not in line:
            raise SystemExit(f"ERROR: unsupported YAML line: {raw.rstrip()}")
        key, value = line.split(":", 1)
        key = key.strip()
        parents = parents[:level]
        full = ".".join(parents + [key])
        if value.strip() == "":
            parents.append(key)
        else:
            values[full] = parse_scalar(value)

print(values.get(wanted, default))
PY
}

cfg_bool() {
    local key="$1"
    local default="${2:-false}"
    local value
    value=$(cfg "$key" "$default")
    case "${value,,}" in
        1|true|yes|y|on) return 0 ;;
        0|false|no|n|off|"") return 1 ;;
        *) echo "ERROR: config ${key} must be true or false, got: ${value}" >&2; exit 1 ;;
    esac
}

count_reads() {
    gzip -cd "$1" | awk 'END { if (NR % 4 == 0) print NR / 4; else print "INVALID" }'
}

split_csv() {
    local value="$1"
    local -n out_ref="$2"
    local item
    IFS=',' read -r -a out_ref <<< "${value}"
    for i in "${!out_ref[@]}"; do
        item="${out_ref[$i]}"
        item="${item#${item%%[![:space:]]*}}"
        item="${item%${item##*[![:space:]]}}"
        out_ref[$i]="${item}"
    done
}

# ========== Logging ==========
log_dir=""  # set after parsing results_dir

log_main() {
    local level="$1"   # START | CONFIG | SAMPLE | TOTAL
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] ${level} | $*" >> "${log_dir}/pipeline.log"
}

log_sample_detail() {
    local sample="$1"
    local step="$2"     # fastp | bowtie2 | megahit
    local status="$3"   # OK | FAIL
    shift 3
    # Main pipeline log
    log_main "SAMPLE" "${sample} | ${step} | ${status} | $*"
    # Per-sample detail log
    {
        echo "=== ${step} ==="
        echo "STATUS: ${status}"
        echo "MSG: $*"
        echo "---"
    } >> "${log_dir}/${sample}.detail.log"
}

# ========== Config Parsing ==========
run_seconds=${SECONDS}
data_dir=$(cfg data_dir)
results_dir=$(cfg results_dir)

# Validate required paths
if [[ -z "${data_dir}" ]]; then
    echo "ERROR: data_dir not set in ${config_file}" >&2
    exit 1
fi
if [[ -z "${results_dir}" ]]; then
    echo "ERROR: results_dir not set in ${config_file}" >&2
    exit 1
fi

db_dir=$(cfg db_dir)
bowtie2_index="${db_dir}/bowtie2/SILVA"

input_r1_suffixes=$(cfg input.r1_suffixes "_r1.fq.gz,_R1.fq.gz,.r1.fq.gz,.R1.fq.gz,_1.fq.gz,_R1.fastq.gz,_r1.fastq.gz")
input_r2_suffixes=$(cfg input.r2_suffixes "_r2.fq.gz,_R2.fq.gz,.r2.fq.gz,.R2.fq.gz,_2.fq.gz,_R2.fastq.gz,_r2.fastq.gz")
split_csv "${input_r1_suffixes}" r1_suffixes
split_csv "${input_r2_suffixes}" r2_suffixes
if (( ${#r1_suffixes[@]} != ${#r2_suffixes[@]} )); then
    echo "ERROR: input.r1_suffixes and input.r2_suffixes must have the same number of items" >&2
    exit 1
fi

cpu_total=$(nproc)
threads_cfg=$(cfg threads auto)
if [[ "${threads_cfg}" == "auto" || -z "${threads_cfg}" ]]; then
    threads=${THREADS:-${cpu_total}}
else
    threads=${THREADS:-${threads_cfg}}
fi
if (( threads < 1 )); then
    threads=1
elif (( threads > cpu_total )); then
    threads=${cpu_total}
fi

fastp_detect_adapter_for_pe=$(cfg fastp.detect_adapter_for_pe true)
fastp_cut_front=$(cfg fastp.cut_front true)
fastp_cut_tail=$(cfg fastp.cut_tail true)
fastp_cut_window_size=$(cfg fastp.cut_window_size 4)
fastp_cut_mean_quality=$(cfg fastp.cut_mean_quality 20)
fastp_qualified_quality_phred=$(cfg fastp.qualified_quality_phred 20)
fastp_unqualified_percent_limit=$(cfg fastp.unqualified_percent_limit 30)
fastp_n_base_limit=$(cfg fastp.n_base_limit 5)
fastp_length_required=$(cfg fastp.length_required 50)
fastp_disable_trim_poly_g=$(cfg fastp.disable_trim_poly_g true)

bowtie2_preset=$(cfg bowtie2.preset sensitive)

megahit_k_min=$(cfg megahit.k_min 35)
megahit_k_max=$(cfg megahit.k_max 95)
megahit_k_step=$(cfg megahit.k_step 20)
megahit_min_contig_len=$(cfg megahit.min_contig_len 800)
megahit_memory=$(cfg megahit.memory 0.8)

cleanup_fastp=$(cfg cleanup.delete_fastp_dir true)
cleanup_rrna=$(cfg cleanup.delete_rrna_dir true)

# ========== Directory Setup ==========
fastp_dir="${results_dir}/fastp"
rrna_dir="${results_dir}/rRNA"
megahit_dir="${results_dir}/megahit"
log_dir="${results_dir}/logs"
mkdir -p "${fastp_dir}" "${rrna_dir}" "${megahit_dir}" "${log_dir}"

# ========== Start Pipeline Log ==========
cat > "${log_dir}/pipeline.log" << EOF
====== Hantavirus Assembly Pipeline ======
START: $(date '+%Y-%m-%d %H:%M:%S')
CONFIG: ${config_file}
DATA: ${data_dir}
RESULTS: ${results_dir}
THREADS: ${threads}
BOWTIE2_INDEX: ${bowtie2_index}
------------------------------------------
EOF

log_main "CONFIG" "threads=${threads} bowtie2_index=${bowtie2_index}"

# ========== Main Sample Loop ==========
total_samples=0
done_samples=0
fail_samples=0
declare -a fail_list=()

shopt -s nullglob
declare -A seen_samples=()

for suffix_i in "${!r1_suffixes[@]}"; do
  r1_suffix="${r1_suffixes[$suffix_i]}"
  r2_suffix="${r2_suffixes[$suffix_i]}"
  for r1 in "${data_dir}"/*"${r1_suffix}"; do
    [[ -f "${r1}" ]] || continue
    total_samples=$((total_samples + 1))
    sample_start=${SECONDS}
    sample=$(basename "${r1}" "${r1_suffix}")
    r2="${data_dir}/${sample}${r2_suffix}"

    # Duplicate check
    if [[ -n "${seen_samples[$sample]:-}" ]]; then
        log_sample_detail "${sample}" "pipeline" "SKIP" "duplicate sample name from R1: ${r1}"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi
    seen_samples[$sample]=1

    if [[ ! -f "${r2}" ]]; then
        log_sample_detail "${sample}" "pipeline" "FAIL" "missing R2: ${r2}"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    # ---- Step 1: fastp ----
    echo "[${sample}] fastp start" > "${log_dir}/${sample}.detail.log"

    # gzip check
    if ! gzip -t "${r1}" 2>>"${log_dir}/${sample}.fastp.err"; then
        log_sample_detail "${sample}" "fastp" "FAIL" "bad gzip R1"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi
    if ! gzip -t "${r2}" 2>>"${log_dir}/${sample}.fastp.err"; then
        log_sample_detail "${sample}" "fastp" "FAIL" "bad gzip R2"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    r1_reads=$(count_reads "${r1}")
    r2_reads=$(count_reads "${r2}")
    if [[ "${r1_reads}" != "${r2_reads}" || "${r1_reads}" == "INVALID" ]]; then
        log_sample_detail "${sample}" "fastp" "FAIL" "paired read count mismatch: R1=${r1_reads} R2=${r2_reads}"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    fastp_args=(
        -i "${r1}" -I "${r2}"
        -o "${fastp_dir}/${sample}.clean_R1.fq.gz"
        -O "${fastp_dir}/${sample}.clean_R2.fq.gz"
        --cut_window_size "${fastp_cut_window_size}"
        --cut_mean_quality "${fastp_cut_mean_quality}"
        -q "${fastp_qualified_quality_phred}"
        -u "${fastp_unqualified_percent_limit}"
        -n "${fastp_n_base_limit}"
        -l "${fastp_length_required}"
        -h "${fastp_dir}/${sample}.fastp.html"
        -j "${fastp_dir}/${sample}.fastp.json"
        -w "${threads}"
    )
    cfg_bool fastp.detect_adapter_for_pe "${fastp_detect_adapter_for_pe}" && fastp_args+=(--detect_adapter_for_pe)
    cfg_bool fastp.cut_front "${fastp_cut_front}" && fastp_args+=(--cut_front)
    cfg_bool fastp.cut_tail "${fastp_cut_tail}" && fastp_args+=(--cut_tail)
    cfg_bool fastp.disable_trim_poly_g "${fastp_disable_trim_poly_g}" && fastp_args+=(-x)

    fastp_start=${SECONDS}
    if fastp "${fastp_args[@]}" > "${log_dir}/${sample}.fastp.log" 2>&1; then
        fastp_elapsed=$((SECONDS - fastp_start))
        log_sample_detail "${sample}" "fastp" "OK" "${fastp_elapsed}s reads_in=${r1_reads}"
    else
        fastp_elapsed=$((SECONDS - fastp_start))
        log_sample_detail "${sample}" "fastp" "FAIL" "${fastp_elapsed}s see ${log_dir}/${sample}.fastp.log"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    # ---- Step 2: Bowtie2 (rRNA removal) ----
    echo "[${sample}] bowtie2 start" >> "${log_dir}/${sample}.detail.log"

    bowtie2_args=(
        "--${bowtie2_preset}"
        -x "${bowtie2_index}"
        -1 "${fastp_dir}/${sample}.clean_R1.fq.gz"
        -2 "${fastp_dir}/${sample}.clean_R2.fq.gz"
        --un-conc "${rrna_dir}/${sample}.non_rRNA_reads.fq"
        -S "${rrna_dir}/${sample}.rRNA_mapped.sam"
        -p "${threads}"
    )

    bowtie2_start=${SECONDS}
    if bowtie2 "${bowtie2_args[@]}" > "${log_dir}/${sample}.bowtie2.log" 2>&1; then
        bowtie2_elapsed=$((SECONDS - bowtie2_start))
        # Rename bowtie2 output
        if [[ -f "${rrna_dir}/${sample}.non_rRNA_reads.1.fq" ]]; then
            mv "${rrna_dir}/${sample}.non_rRNA_reads.1.fq" "${rrna_dir}/${sample}.non_rRNA_reads_R1.fq"
        fi
        if [[ -f "${rrna_dir}/${sample}.non_rRNA_reads.2.fq" ]]; then
            mv "${rrna_dir}/${sample}.non_rRNA_reads.2.fq" "${rrna_dir}/${sample}.non_rRNA_reads_R2.fq"
        fi
        log_sample_detail "${sample}" "bowtie2" "OK" "${bowtie2_elapsed}s"
    else
        bowtie2_elapsed=$((SECONDS - bowtie2_start))
        log_sample_detail "${sample}" "bowtie2" "FAIL" "${bowtie2_elapsed}s see ${log_dir}/${sample}.bowtie2.log"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    # ---- Step 3: MEGAHIT ----
    echo "[${sample}] megahit start" >> "${log_dir}/${sample}.detail.log"

    sample_megahit_dir="${megahit_dir}/${sample}"
    rm -rf "${sample_megahit_dir}"
    megahit_args=(
        -1 "${rrna_dir}/${sample}.non_rRNA_reads_R1.fq"
        -2 "${rrna_dir}/${sample}.non_rRNA_reads_R2.fq"
        --k-min "${megahit_k_min}"
        --k-max "${megahit_k_max}"
        --k-step "${megahit_k_step}"
        --min-contig-len "${megahit_min_contig_len}"
        -m "${megahit_memory}"
        -t "${threads}"
        -o "${sample_megahit_dir}"
    )

    megahit_start=${SECONDS}
    if megahit "${megahit_args[@]}" > "${log_dir}/${sample}.megahit.log" 2>&1; then
        megahit_elapsed=$((SECONDS - megahit_start))
        sample_elapsed=$((SECONDS - sample_start))
        log_sample_detail "${sample}" "megahit" "OK" "${megahit_elapsed}s contigs: ${sample_megahit_dir}/final.contigs.fa"
        done_samples=$((done_samples + 1))
    else
        megahit_elapsed=$((SECONDS - megahit_start))
        log_sample_detail "${sample}" "megahit" "FAIL" "${megahit_elapsed}s see ${log_dir}/${sample}.megahit.log"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi
  done
done

# ========== Cleanup ==========
cfg_bool cleanup.delete_fastp_dir "${cleanup_fastp}" && rm -rf "${fastp_dir}"
cfg_bool cleanup.delete_rrna_dir "${cleanup_rrna}" && rm -rf "${rrna_dir}"

# ========== Final Summary ==========
pipeline_elapsed=$((SECONDS - run_seconds))
{
    echo "------------------------------------------"
    echo "SUMMARY"
    echo "  Total samples:  ${total_samples}"
    echo "  Done:           ${done_samples}"
    echo "  Failed:         ${fail_samples}"
    if (( fail_samples > 0 )); then
        echo "  Failed list:    ${fail_list[*]}"
    fi
    echo "  Pipeline time:  $((pipeline_elapsed / 3600))h $(((pipeline_elapsed % 3600) / 60))m $((pipeline_elapsed % 60))s"
    echo "END: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "====== Done ======"
} >> "${log_dir}/pipeline.log"

# Write machine-readable status file
cat > "${log_dir}/.pipeline_status.txt" << EOF
status=$([ "${fail_samples}" -eq 0 ] && echo "ok" || echo "partial")
total=${total_samples}
done=${done_samples}
failed=${fail_samples}
pipeline_seconds=${pipeline_elapsed}
results_dir=${results_dir}
EOF
if (( fail_samples > 0 )); then
    echo "failed_samples=${fail_list[*]}" >> "${log_dir}/.pipeline_status.txt"
fi

# ========== Print Summary ==========
cat "${log_dir}/pipeline.log"
