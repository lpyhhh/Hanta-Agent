#!/usr/bin/env python3
"""
Step 1: 合并 Diamond L/M/S 比对结果，去重，并提取建树序列
输入: results/04_diamond/<Sample>_vs_*.tab
输出:
  - results/05_phylogeny/<Sample>/step01_merged_hits.csv (去重后)
  - results/05_phylogeny/<Sample>/step01_L_tree_input.faa
  - results/05_phylogeny/<Sample>/step01_M_tree_input.faa
  - results/05_phylogeny/<Sample>/step01_S_tree_input.faa
"""

import os
import re
import sys
from collections import OrderedDict

import pandas as pd

from config_loader import load_config


def parse_tab(filepath: str) -> pd.DataFrame:
    """解析 Diamond tab 输出."""
    if not os.path.exists(filepath) or os.path.getsize(filepath) == 0:
        return pd.DataFrame()
    df = pd.read_csv(filepath, sep="\t", comment="#", header=None)
    if df.empty:
        return df
    df.columns = [
        "qseqid", "sseqid", "pident", "length", "mismatch",
        "gapopen", "qstart", "qend", "sstart", "send", "evalue", "bitscore"
    ]
    return df


def contig_id(protein_id: str) -> str:
    """从 Protein_ID 提取 Contig_ID (去掉尾部 _数字)."""
    return re.sub(r"_\d+$", "", protein_id)


def load_fasta(filepath: str) -> OrderedDict:
    """解析 FASTA, 返回 OrderedDict[id, seq]."""
    seqs = OrderedDict()
    if not os.path.exists(filepath):
        return seqs
    curr_id = None
    curr_seq = []
    with open(filepath) as f:
        for line in f:
            if line.startswith(">"):
                if curr_id:
                    seqs[curr_id] = "".join(curr_seq)
                curr_id = line[1:].split()[0]
                curr_seq = []
            else:
                curr_seq.append(line.strip())
        if curr_id:
            seqs[curr_id] = "".join(curr_seq)
    return seqs


def write_fasta(seqs: OrderedDict, filepath: str):
    """写出 FASTA 文件."""
    with open(filepath, "w") as f:
        for sid, seq in seqs.items():
            f.write(f">{sid}\n{seq}\n")


def deduplicate_hits(df: pd.DataFrame) -> pd.DataFrame:
    """按 (DB, Contig_ID) 去重，保留 Bitscore 最大的行."""
    df = df.sort_values("Bitscore", ascending=False)
    df = df.drop_duplicates(subset=["DB", "Contig_ID"], keep="first")
    return df.sort_values(["DB", "Bitscore"], ascending=[True, False]).reset_index(drop=True)


def extract_tree_seqs(sample: str, merged_df: pd.DataFrame, cfg: dict) -> list:
    """
    基于去重后的合并结果提取建树序列.
    每个段 (L/M/S) 输出: Query + Reference (无外群, midpoint root).
    """
    outdir = os.path.join(cfg["phylogeny_dir"], sample)
    os.makedirs(outdir, exist_ok=True)

    # 1. 加载 Prodigal 输出的 Query 蛋白序列
    prodigal_faa = os.path.join(cfg["assembly_dir"], sample, "final.contigs_proteins.faa")
    if not os.path.exists(prodigal_faa):
        print(f"ERROR: Prodigal output not found at {prodigal_faa}")
        return []
    query_all = load_fasta(prodigal_faa)
    if not query_all:
        print(f"ERROR: Prodigal output is empty at {prodigal_faa}")
        return []

    # 2. 构建 Protein_ID -> {DB segments} 映射
    pid_to_segs = {}
    for _, row in merged_df.iterrows():
        pid = row["Protein_ID"]
        seg = row["DB"]
        if pid not in pid_to_segs:
            pid_to_segs[pid] = set()
        pid_to_segs[pid].add(seg)

    SEGMENTS = ["L", "M", "S"]
    generated = []
    for seg in SEGMENTS:
        # 3. 加载该段参考数据库
        db_faa = os.path.join(cfg["db_dir"], f"{seg}.faa")
        ref_prots = OrderedDict()
        for rid, seq in load_fasta(db_faa).items():
            ref_prots[f"REF|{rid}"] = seq

        # 4. Query: 从 Prodigal 中提取命中该段的蛋白
        query_prots = OrderedDict()
        for pid, segs in pid_to_segs.items():
            if seg in segs and pid in query_all:
                query_prots[pid] = query_all[pid]

        if not query_prots:
            continue

        # 5. 合并输出: Query + Reference (无外群, midpoint root)
        combined = OrderedDict()
        combined.update(query_prots)
        combined.update(ref_prots)

        out_faa = os.path.join(outdir, f"step01_{seg}_tree_input.faa")
        write_fasta(combined, out_faa)
        generated.append(out_faa)

    return generated


def merge(sample: str, cfg: dict) -> str:
    clean_sample = sample.rstrip("_")

    # 兼容 <sample>_vs_*.tab 和旧流程产生的 <sample>__vs_*.tab
    file_prefix = None
    for prefix in [f"{clean_sample}_vs_", f"{clean_sample}__vs_"]:
        test_fp = os.path.join(cfg["diamond_dir"], f"{prefix}L.tab")
        if os.path.exists(test_fp):
            file_prefix = prefix
            break
    if not file_prefix:
        print(f"ERROR: No Diamond files found for {clean_sample}")
        return ""

    outdir = os.path.join(cfg["phylogeny_dir"], clean_sample)
    os.makedirs(outdir, exist_ok=True)
    outpath = os.path.join(outdir, "step01_merged_hits.csv")

    # 1. 读取并合并 L/M/S 三个 Diamond tab 文件
    rows = []
    for seg in ["L", "M", "S"]:
        fp = os.path.join(cfg["diamond_dir"], f"{file_prefix}{seg}.tab")
        df = parse_tab(fp)
        for _, r in df.iterrows():
            pid = str(r["qseqid"])
            rows.append({
                "DB": seg, "Contig_ID": contig_id(pid), "Protein_ID": pid,
                "Subject_ID": str(r["sseqid"]), "Pident": float(r["pident"]),
                "Length": int(r["length"]), "Evalue": float(r["evalue"]),
                "Bitscore": float(r["bitscore"]),
            })

    if not rows:
        print(f"ERROR: No hits found for {clean_sample}")
        return ""

    df = pd.DataFrame(rows)
    pident_min = cfg["merge"]["pident_min"]
    evalue_max = cfg["diamond"]["evalue"]
    df = df[(df["Pident"] >= pident_min) & (df["Evalue"] <= evalue_max)]

    # 2. 按 (DB, Contig_ID) 去重，保留 Bitscore 最大的行
    before = len(df)
    df = deduplicate_hits(df)
    after = len(df)

    # 3. 写入合并 CSV
    df.to_csv(outpath, index=False)

    # 4. 提取建树序列 (Query + Reference, 无外群)
    generated = extract_tree_seqs(clean_sample, df, cfg)

    print(f"Merged {after} hits → {outpath}")
    return outpath


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 step01_merge_diamond.py <SAMPLE>")
        print("Example: python3 step01_merge_diamond.py SRR24113203")
        sys.exit(1)

    sample = sys.argv[1]
    cfg = load_config(sample)
    merge(sample, cfg)


if __name__ == "__main__":
    main()
