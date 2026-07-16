#!/usr/bin/env python3
"""
Step 5: 自动拓扑校验 (施莽 2025 方案: aLRT + midpoint root)
输入: step01_merged_hits.csv + step04_<Segment>_tree.treefile
输出: step05_verification.csv

判定逻辑 (施莽 Peng 2025, Microbiology Spectrum):
  1. IQ-TREE 输出的 "SH-aLRT/Bootstrap" 双支持值分别提取
  2. SH-aLRT >= 阈值 (默认 80) 即通过
  3. 沿 query 祖先上溯, 找到第一个包含目标 REF 的节点进行判定
  4. 无外群, 树已由 IQ-TREE --root MIDPOINT 定根
"""

import os
import re
import sys

import pandas as pd
from ete3 import Tree

from config_loader import load_config

# UID 起始值，远大于正常的 bootstrap 值 (0–100)，避免冲突
_UID_BASE = 100000


def _load_iqtree(treefile: str) -> tuple:
    """
    解析 IQ-TREE newick (含 "SH-aLRT/Bootstrap" 双支持值).
    用唯一 UID 替换每个双支持值, 返回 (ete3.Tree, {uid: (alrt, bs)}).
    """
    with open(treefile) as fh:
        text = fh.read().strip()

    pattern = re.compile(r"\)([\d.]+)/(\d+)(?=[:),;])")
    support_map: dict = {}
    uid = _UID_BASE

    def _replace(m: re.Match) -> str:
        nonlocal uid
        uid += 1
        support_map[uid] = (float(m.group(1)), int(m.group(2)))
        return f"){uid}"

    preprocessed = pattern.sub(_replace, text)
    tree = Tree(preprocessed, format=0)
    return tree, support_map


def _resolve_support(node, support_map: dict) -> tuple:
    """从树节点解析支持值, 返回 (sh_alrt, bootstrap)."""
    raw = node.support
    if raw is None or raw == "":
        return (0, 0)
    try:
        val = int(raw)
    except (ValueError, TypeError):
        return (0, 0)
    if val > _UID_BASE:
        return support_map.get(val, (0, 0))
    return (0, val)


def leaf_label(node) -> str:
    return getattr(node, "name", str(node))


def verify_single(treefile: str, query_id: str, target_ref: str,
                  sh_alrt_min: int,
                  tree_cache: dict = None) -> dict:
    """
    施莽方案: 沿 query 祖先上溯, 找第一个含目标 REF 的节点,
    仅用 SH-aLRT 判定.
    """
    cache_key = treefile
    if tree_cache is not None and cache_key in tree_cache:
        tree, support_map = tree_cache[cache_key]
    else:
        try:
            tree, support_map = _load_iqtree(treefile)
        except Exception as e:
            return {"passed": False, "sh_alrt": 0, "bootstrap": 0,
                    "reason": f"Parse: {e}"}
        if tree_cache is not None:
            tree_cache[cache_key] = (tree, support_map)

    qnodes = tree.search_nodes(name=query_id)
    if not qnodes:
        return {"passed": False, "sh_alrt": 0, "bootstrap": 0,
                "reason": "Query not in tree"}

    ref_name = f"REF|{target_ref}"
    rnodes = tree.search_nodes(name=ref_name)
    if not rnodes:
        return {"passed": False, "sh_alrt": 0, "bootstrap": 0,
                "reason": f"REF {target_ref} not in tree"}

    # 沿 query 祖先逐层上溯, 找第一个含 REF 的共同祖先
    current = qnodes[0].up
    while current is not None:
        leaves = {leaf_label(l) for l in current.iter_leaves()}

        if ref_name not in leaves:
            current = current.up
            continue

        alrt, bs = _resolve_support(current, support_map)

        if alrt >= sh_alrt_min:
            return {"passed": True, "sh_alrt": alrt, "bootstrap": bs,
                    "reason": "OK"}
        else:
            return {"passed": False, "sh_alrt": alrt, "bootstrap": bs,
                    "reason": f"SH-aLRT {alrt:.1f}<{sh_alrt_min}"}

    return {"passed": False, "sh_alrt": 0, "bootstrap": 0,
            "reason": "No ancestor with target REF"}


def verify_sample(sample: str, cfg: dict) -> str:
    indir = os.path.join(cfg["phylogeny_dir"], sample)
    outpath = os.path.join(indir, "step05_verification.csv")

    merged_csv = os.path.join(indir, "step01_merged_hits.csv")
    if not os.path.exists(merged_csv):
        print(f"ERROR: No merged hits at {merged_csv}. Run step01 first.")
        return ""

    merged = pd.read_csv(merged_csv)

    sh_alrt_min = cfg["phylogeny"]["sh_alrt_min"]
    tree_cache = {}
    all_rows = []

    for seg in ["L", "M", "S"]:
        treefile = os.path.join(indir, f"step04_{seg}_tree.treefile")
        if not os.path.exists(treefile):
            continue

        seg_hits = merged[merged["DB"] == seg]
        if seg_hits.empty:
            continue

        def cid(pid):
            return re.sub(r"_\d+$", "", pid)

        for _, row in seg_hits.iterrows():
            qid = row["Protein_ID"]
            v = verify_single(treefile, qid, row["Subject_ID"],
                              sh_alrt_min, tree_cache)
            all_rows.append({
                "Sample":     sample,
                "Segment":    seg,
                "Protein_ID": qid,
                "Contig_ID":  cid(qid),
                "Target_REF": row["Subject_ID"],
                "SH_aLRT":    v["sh_alrt"],
                "Bootstrap":  v["bootstrap"],
                "Passed":     v["passed"],
                "Reason":     v["reason"],
            })

    if not all_rows:
        print(f"ERROR: No results for {sample}")
        return ""

    df = pd.DataFrame(all_rows)
    df.to_csv(outpath, index=False)

    n_pass = int(df["Passed"].sum())
    print(f"Verified: {n_pass}/{len(df)} passed → {outpath}")
    return outpath


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 step05_verify_trees.py <SAMPLE>")
        print("Example: python3 step05_verify_trees.py SRR24113203")
        sys.exit(1)

    sample = sys.argv[1]
    cfg = load_config(sample)
    verify_sample(sample, cfg)


if __name__ == "__main__":
    main()
