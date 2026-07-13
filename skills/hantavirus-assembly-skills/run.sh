#!/usr/bin/env bash
# ============================================================
# hantavirus-assembly-skills 入口包装
# 自动激活 lpy-hantavirus-skills conda 环境后运行 assembly.sh
# Usage: bash run.sh [config.yaml]
#   config.yaml 默认取同目录下的 config.yaml
# ============================================================
set -euo pipefail

skill_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config_input="${1:-config.yaml}"

# 解析 config 路径：绝对路径直接用，否则相对于 skill_dir
if [[ -f "${config_input}" ]]; then
    config_file="${config_input}"
else
    config_file="${skill_dir}/${config_input}"
fi

if [[ ! -f "${config_file}" ]]; then
    echo "ERROR: config file not found: ${config_file}" >&2
    echo "Usage: bash run.sh [path/to/config.yaml]" >&2
    exit 1
fi

CONDA_ENV="lpy-hantavirus-skills"

# 通过 conda run 启动（错误率最低，不需要 conda init）
if command -v conda &>/dev/null; then
    conda run -n "${CONDA_ENV}" bash "${skill_dir}/scripts/assembly.sh" "${config_file}"
else
    echo "WARNING: conda not found. Proceeding with current environment."
    echo "  Make sure '${CONDA_ENV}' is already activated, or manually:"
    echo "    conda activate ${CONDA_ENV}"
    echo "    bash ${skill_dir}/scripts/assembly.sh ${config_file}"
    echo "---"
    bash "${skill_dir}/scripts/assembly.sh" "${config_file}"
fi
