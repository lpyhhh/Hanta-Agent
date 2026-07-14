#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# hantavirus-annotation-skills
# Pipeline: MEGAHIT contigs → genomad (virus taxonomy) & hmmsearch (HMM profiling)
#   data_dir   = input:  directory containing <sample>/final.contigs.fa (MEGAHIT output)
#   results_dir= output: where annotation results are written
#   db_dir     = databases: genomad_db/ + hmm/hanta_aligned.hmm
# Usage: run_backup.sh [config.yaml]
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

# ========== Logging ==========
log_dir=""  # set after parsing results_dir

log_main() {
    local level="$1"   # START | CONFIG | SAMPLE | TOTAL
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] ${level} | $*" >> "${log_dir}/annotation_pipeline.log"
}

log_sample_detail() {
    local sample="$1"
    local step="$2"     # genomad | hmmsearch
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
megahit_dir=$(cfg megahit_dir)
results_dir=$(cfg results_dir)

if [[ -z "${results_dir}" ]]; then
    echo "ERROR: results_dir not set in ${config_file}" >&2
    exit 1
fi

if [[ -z "${megahit_dir}" ]]; then
    megahit_dir="${results_dir}/megahit"
fi

# Validate megahit_dir exists and contains samples
if [[ ! -d "${megahit_dir}" ]]; then
    echo "ERROR: megahit_dir not found: ${megahit_dir}" >&2
    exit 1
fi

db_dir=$(cfg db_dir)
if [[ -z "${db_dir}" ]]; then
    echo "ERROR: db_dir not set in ${config_file}" >&2
    exit 1
fi

genomad_db="${db_dir}/genomad_db"
hmm_db_cfg=$(cfg hmm_db "")
if [[ -n "${hmm_db_cfg}" ]]; then
    hmm_db="${hmm_db_cfg}"
else
    hmm_db="${db_dir}/hmm/hanta_aligned.hmm"
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

# ---- genomad configuration ----
genomad_splits=$(cfg genomad.splits 2)
genomad_min_score=$(cfg genomad.min_score 0.5)
genomad_cleanup=$(cfg genomad.cleanup true)
genomad_lenient_taxonomy=$(cfg genomad.lenient_taxonomy true)
genomad_full_ictv_lineage=$(cfg genomad.full_ictv_lineage true)
genomad_disable_find_proviruses=$(cfg genomad.disable_find_proviruses true)

# ---- hmmsearch configuration ----
hmm_E=$(cfg hmmsearch.E 1e-3)
hmm_domE=$(cfg hmmsearch.domE 10)
hmm_acc=$(cfg hmmsearch.acc true)
hmm_noali=$(cfg hmmsearch.noali true)
hmm_notextw=$(cfg hmmsearch.notextw true)

# ---- cleanup configuration ----
cleanup_genomad=$(cfg cleanup.delete_genomad_dir false)
cleanup_hmm=$(cfg cleanup.delete_hmm_dir false)

genomad_dir="${results_dir}/genomad"
hmm_dir="${results_dir}/hmm"
class_dir="${hmm_dir}/2-class"
log_dir="${results_dir}/logs_annotation"

mkdir -p "${genomad_dir}" "${hmm_dir}" "${class_dir}" "${log_dir}"

# ========== Start Pipeline Log ==========
cat > "${log_dir}/annotation_pipeline.log" << EOF
====== Hantavirus Annotation Pipeline ======
START: $(date '+%Y-%m-%d %H:%M:%S')
CONFIG: ${config_file}
MEGAHIT_DIR: ${megahit_dir}
RESULTS_DIR: ${results_dir}
THREADS: ${threads}
GENOMAD_DB: ${genomad_db}
HMM_DB: ${hmm_db}
GENOMAD_SPLITS: ${genomad_splits}
GENOMAD_MIN_SCORE: ${genomad_min_score}
HMMSEARCH_E: ${hmm_E}
HMMSEARCH_DOME: ${hmm_domE}
------------------------------------------
EOF

log_main "CONFIG" "threads=${threads} genomad_db=${genomad_db} hmm_db=${hmm_db}"

# ========== Main Sample Loop ==========
total_samples=0
done_samples=0
fail_samples=0
declare -a fail_list=()
shopt -s nullglob

# Iterate through sample directories in megahit_dir
for sample_dir in "${megahit_dir}"/*; do
    if [[ ! -d "${sample_dir}" ]]; then
        continue
    fi

    sample=$(basename "${sample_dir}")
    contigs_fa="${sample_dir}/final.contigs.fa"

    if [[ ! -f "${contigs_fa}" ]]; then
        echo "Skipping ${sample}: no final.contigs.fa found."
        continue
    fi

    total_samples=$((total_samples + 1))
    sample_start=${SECONDS}

    echo "[${sample}] Starting annotation" > "${log_dir}/${sample}.detail.log"

    # ---- Step 1: genomad ----
    sample_genomad_dir="${genomad_dir}/${sample}"
    mkdir -p "${sample_genomad_dir}"

    genomad_args=(
        end-to-end
        --splits "${genomad_splits}"
        --min-score "${genomad_min_score}"
        "${contigs_fa}"
        "${sample_genomad_dir}"
        "${genomad_db}"
    )
    cfg_bool genomad.cleanup "${genomad_cleanup}" && genomad_args+=(--cleanup)
    cfg_bool genomad.lenient_taxonomy "${genomad_lenient_taxonomy}" && genomad_args+=(--lenient-taxonomy)
    cfg_bool genomad.full_ictv_lineage "${genomad_full_ictv_lineage}" && genomad_args+=(--full-ictv-lineage)
    cfg_bool genomad.disable_find_proviruses "${genomad_disable_find_proviruses}" && genomad_args+=(--disable-find-proviruses)

    genomad_start=${SECONDS}
    if genomad "${genomad_args[@]}" > "${log_dir}/${sample}.genomad.log" 2>&1; then
        genomad_elapsed=$((SECONDS - genomad_start))

        # Post-process genomad output
        genomad_summary="${sample_genomad_dir}/final.contigs_summary/final.contigs_virus_summary.tsv"
        hanta_tsv="${sample_genomad_dir}/Hantaviridae_taxonmy.tsv"
        hanta_id="${sample_genomad_dir}/Hantaviridae.tsv"
        hanta_fna="${sample_genomad_dir}/Hantaviridae.fna"

        if [[ -f "${genomad_summary}" ]]; then
            if grep -q "Hantaviridae" "${genomad_summary}"; then
                grep "Hantaviridae" "${genomad_summary}" > "${hanta_tsv}"
                awk -F'\t' '{print $1}' "${hanta_tsv}" > "${hanta_id}"
                if ! seqkit grep -f "${hanta_id}" "${sample_genomad_dir}/final.contigs_summary/final.contigs_virus.fna" -o "${hanta_fna}"; then
                    log_sample_detail "${sample}" "genomad" "FAIL" "seqkit grep failed on Hantaviridae hits"
                    fail_samples=$((fail_samples + 1))
                    fail_list+=("${sample}")
                    continue
                fi
            else
                touch "${hanta_fna}"  # No Hantaviridae hits — empty file is valid
            fi
        else
            log_sample_detail "${sample}" "genomad" "FAIL" "genomad summary missing: ${genomad_summary}"
            fail_samples=$((fail_samples + 1))
            fail_list+=("${sample}")
            continue
        fi

        log_sample_detail "${sample}" "genomad" "OK" "${genomad_elapsed}s"
    else
        genomad_elapsed=$((SECONDS - genomad_start))
        log_sample_detail "${sample}" "genomad" "FAIL" "${genomad_elapsed}s see ${log_dir}/${sample}.genomad.log"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    # ---- Step 2: hmmsearch ----
    hmm_out="${hmm_dir}/${sample}.hmmsearch"
    hmm_id="${hmm_dir}/${sample}.id"
    hmm_fna="${hmm_dir}/${sample}.fna"

    hmmsearch_args=(
        -E "${hmm_E}" --domE "${hmm_domE}" --cpu "${threads}"
        --domtblout "${hmm_out}"
    )
    cfg_bool hmmsearch.acc "${hmm_acc}" && hmmsearch_args+=(--acc)
    cfg_bool hmmsearch.noali "${hmm_noali}" && hmmsearch_args+=(--noali)
    cfg_bool hmmsearch.notextw "${hmm_notextw}" && hmmsearch_args+=(--notextw)
    hmmsearch_args+=("${hmm_db}" "${contigs_fa}")

    hmm_start=${SECONDS}
    if hmmsearch "${hmmsearch_args[@]}" > "${log_dir}/${sample}.hmmsearch.log" 2>&1; then
        hmm_elapsed=$((SECONDS - hmm_start))

        if grep -v '^#' "${hmm_out}" | awk '{print $1}' | awk '{sub(/_[0-9]+$/, "", $1); print $1}' | sort -u > "${hmm_id}" && [[ -s "${hmm_id}" ]]; then
            if ! seqkit grep -f "${hmm_id}" "${contigs_fa}" -o "${hmm_fna}"; then
                log_sample_detail "${sample}" "hmmsearch" "FAIL" "seqkit grep failed on hmmsearch hits"
                fail_samples=$((fail_samples + 1))
                fail_list+=("${sample}")
                continue
            fi
        else
            touch "${hmm_fna}"  # No hits — empty file is valid
        fi

        log_sample_detail "${sample}" "hmmsearch" "OK" "${hmm_elapsed}s"
    else
        hmm_elapsed=$((SECONDS - hmm_start))
        log_sample_detail "${sample}" "hmmsearch" "FAIL" "${hmm_elapsed}s see ${log_dir}/${sample}.hmmsearch.log"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    # ---- Step 3: Merge and deduplicate ----
    unique_fna="${class_dir}/${sample}.fna"
    if ! cat "${hmm_fna}" "${hanta_fna}" | seqkit rmdup -s -i -o "${unique_fna}"; then
        log_sample_detail "${sample}" "merge" "FAIL" "seqkit rmdup failed"
        fail_samples=$((fail_samples + 1))
        fail_list+=("${sample}")
        continue
    fi

    done_samples=$((done_samples + 1))
done

# ========== Cleanup ==========
cfg_bool cleanup.delete_genomad_dir "${cleanup_genomad}" && rm -rf "${genomad_dir}"
cfg_bool cleanup.delete_hmm_dir "${cleanup_hmm}" && rm -rf "${hmm_dir}"

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
} >> "${log_dir}/annotation_pipeline.log"

# Write machine-readable status file
cat > "${log_dir}/.annotation_pipeline_status.txt" << EOF
status=$([ "${fail_samples}" -eq 0 ] && echo "ok" || echo "partial")
total=${total_samples}
done=${done_samples}
failed=${fail_samples}
pipeline_seconds=${pipeline_elapsed}
results_dir=${results_dir}
EOF
if (( fail_samples > 0 )); then
    echo "failed_samples=${fail_list[*]}" >> "${log_dir}/.annotation_pipeline_status.txt"
fi

cat "${log_dir}/annotation_pipeline.log"
