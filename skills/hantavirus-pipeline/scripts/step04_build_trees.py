#!/usr/bin/env python3
"""
Step 4: MAFFT 多序列比对 → IQ-TREE 最大似然树构建（L/M/S 顺序执行，全核）
输入: step01_<Segment>_tree_input.faa (step01 输出)
输出: step04_<Segment>_aligned.faa  +  step04_<Segment>_tree.treefile
"""

import os
import sys
import subprocess

from ete3 import Tree
from config_loader import load_config, get_cpu_count


def process_segment(sample: str, seg: str, cpu_count: int, cfg: dict) -> str:
    """单个片段: MAFFT 比对 + IQ-TREE 建树, 返回 treefile 路径"""
    indir = os.path.join(cfg["phylogeny_dir"], sample)
    input_faa = os.path.join(indir, f"step01_{seg}_tree_input.faa")

    if not os.path.exists(input_faa):
        print(f"WARNING: [{seg}] no input FASTA, skipping")
        return None

    log_dir = cfg.get("log_dir", os.path.join(cfg["results_dir"], "log", sample))
    os.makedirs(log_dir, exist_ok=True)

    mafft_preset = cfg["phylogeny"].get("mafft_preset", "auto")

    # ---- MAFFT ----
    aligned = os.path.join(indir, f"step04_{seg}_aligned.faa")
    cmd = f"mafft --{mafft_preset} --thread {cpu_count} {input_faa} > {aligned} 2>{log_dir}/mafft_{seg}.log"
    ret = subprocess.run(cmd, shell=True)
    if ret.returncode != 0:
        print(f"ERROR: [{seg}] MAFFT failed (see {log_dir}/mafft_{seg}.log)")
        return None

    # ---- IQ-TREE ----
    prefix = os.path.join(indir, f"step04_{seg}_tree")
    iqtree_bs = cfg["phylogeny"]["iqtree_bootstrap"]
    iqtree_alrt = cfg["phylogeny"]["iqtree_alrt"]
    cmd = (
        f"iqtree -s {aligned} -m MFP -B {iqtree_bs} -alrt {iqtree_alrt} "
        f"-nt {cpu_count} -pre {prefix} -redo --quiet "
        f"> {log_dir}/iqtree_{seg}.log 2>&1"
    )
    ret = subprocess.run(cmd, shell=True)
    treefile = f"{prefix}.treefile"
    if ret.returncode != 0 or not os.path.exists(treefile):
        print(f"ERROR: [{seg}] IQ-TREE failed (see {log_dir}/iqtree_{seg}.log)")
        return None

    # ---- Midpoint Rooting ----
    try:
        # 使用 format=1 兼容 IQ-TREE 的 "SH-aLRT/UFBoot" (如 100/100) 格式
        t = Tree(treefile, format=1)
        t.set_outgroup(t.get_midpoint_outgroup())
        # 必须指定 format=1 导出，否则保存后的新树会丢失 bootstrap 值
        t.write(outfile=treefile, format=1)
    except Exception as e:
        print(f"ERROR: [{seg}] ETE3 rooting failed: {e}")
        return None

    return treefile


def build_trees(sample: str, cfg: dict) -> dict:
    """L/M/S 顺序构建进化树，每段占满全部 CPU, 返回 {segment: treefile_path}"""
    cpu_count = get_cpu_count()

    trees = {}
    for seg in ["L", "M", "S"]:
        print(f"Building {seg} tree (cpu={cpu_count}) ... ", end="", flush=True)
        treefile = process_segment(sample, seg, cpu_count, cfg)
        if treefile:
            trees[seg] = treefile
            print("done")
        else:
            print("skipped")

    return trees


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 step04_build_trees.py <SAMPLE>")
        print("Example: python3 step04_build_trees.py SRR24113203")
        sys.exit(1)

    sample = sys.argv[1]
    cfg = load_config(sample)
    trees = build_trees(sample, cfg)

    outdir = os.path.join(cfg["phylogeny_dir"], sample)
    print(f"Trees built ({len(trees)}/3 segments) → {outdir}/")


if __name__ == "__main__":
    main()