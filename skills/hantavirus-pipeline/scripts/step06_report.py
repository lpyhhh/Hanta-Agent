#!/usr/bin/env python3
"""
Step 6: 生成最终报告
输入: step05_verification.csv
输出: step06_final_report.tsv (通过验证的样本-参考对照表, 用于下游有参组装)
"""

import os
import sys

import pandas as pd

from config_loader import load_config


def final_report(sample: str, cfg: dict) -> str:
    indir = os.path.join(cfg["phylogeny_dir"], sample)
    verif_csv = os.path.join(indir, "step05_verification.csv")

    if not os.path.exists(verif_csv):
        print(f"ERROR: {verif_csv} not found. Run step05 first.")
        return ""

    verif = pd.read_csv(verif_csv)

    # 加载 id-tax.tsv（ID → Tax 映射表）
    id_tax_path = os.path.join(cfg["db_dir"], "id-tax.tsv")
    if os.path.exists(id_tax_path):
        # 表头可能是空格或 tab 分隔，先读第一行解析列名
        with open(id_tax_path) as f:
            header_parts = f.readline().strip().split()
        col_name = header_parts[1] if len(header_parts) >= 2 else "Tax"
        id_tax = pd.read_csv(id_tax_path, sep="\t", header=None,
                             skiprows=1, names=["ID", col_name])
        tax_map = dict(zip(id_tax["ID"], id_tax[col_name]))
        verif[col_name] = verif["Target_REF"].map(tax_map).fillna("N/A")
    else:
        print(f"WARNING: {id_tax_path} not found, skipping taxonomy annotation.")

    outpath = os.path.join(indir, "step06_final_report.tsv")

    lines = []
    lines.append(f"# 汉坦病毒系统发育验证报告")
    lines.append(f"# 样本: {sample}")
    lines.append(f"#")

    # 汇总
    n_pass = int(verif["Passed"].sum())
    n_total = len(verif)
    lines.append(f"# 蛋白总数: {n_total}  |  通过验证: {n_pass}  |  排除: {n_total - n_pass}")
    lines.append(f"#")

    # 逐段结果
    for seg in ["L", "M", "S"]:
        sub = verif[verif["Segment"] == seg]
        if sub.empty:
            lines.append(f"# Segment {seg}: 无数据")
        else:
            pass_rows = sub[sub["Passed"]]
            fail_rows = sub[~sub["Passed"]]
            lines.append(f"# Segment {seg}:")
            if not pass_rows.empty:
                lines.append(f"#   PASS: " + ", ".join(
                    f"{r['Protein_ID']}→{r['Target_REF']}" for _, r in pass_rows.iterrows()))
            if not fail_rows.empty:
                lines.append(f"#   FAIL: " + ", ".join(
                    f"{r['Protein_ID']}({r['Reason']})" for _, r in fail_rows.iterrows()))

    lines.append(f"#")

    # 有参组装参考
    lines.append(f"# 有参组装参考序列 (用于 downstream guided assembly):")
    passed = verif[verif["Passed"]]
    for seg in ["L", "M", "S"]:
        seg_passed = passed[passed["Segment"] == seg]
        if seg_passed.empty:
            lines.append(f"#   {seg}: N/A")
        else:
            refs = seg_passed["Target_REF"].unique().tolist()
            lines.append(f"#   {seg}: {', '.join(refs)}")

    lines.append(f"#")
    lines.append(f"# --- 详细表 ---")
    lines.append("")

    # 写入
    with open(outpath, "w") as f:
        f.write("\n".join(lines))

    # 附加详细 CSV
    verif.to_csv(outpath, sep="\t", mode="a", index=False)

    print(f"Report → {outpath}")
    return outpath


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 step06_report.py <SAMPLE>")
        print("Example: python3 step06_report.py SRR24113203")
        sys.exit(1)

    sample = sys.argv[1]
    cfg = load_config(sample)
    final_report(sample, cfg)


if __name__ == "__main__":
    main()
