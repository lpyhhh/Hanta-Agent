#!/usr/bin/env python3
"""
共用配置加载模块。
从 config.yaml 读取 project_dir，自动推导所有子目录路径，
并提供数据目录下的样本发现功能。
"""

import os
import sys
import yaml


def load_config(sample: str = None) -> dict:
    """
    加载 config.yaml，自动推导所有子目录路径。

    参数:
        sample: 样本名，用于推导 log_dir。可选，为 None 时不设置 log_dir。

    返回:
        dict: 包含所有路径和工具参数的配置字典。
    """
    cfg_dir = os.path.dirname(os.path.abspath(__file__))
    cfg_path = os.path.join(cfg_dir, "config.yaml")

    if not os.path.exists(cfg_path):
        sys.exit(f"ERROR: config.yaml not found at {cfg_path}")

    with open(cfg_path) as f:
        cfg = yaml.safe_load(f)

    base = cfg["project_dir"]

    # 自动推导所有子目录
    cfg["data_dir"] = os.path.join(base, "data")
    cfg["db_dir"] = os.path.join(base, "DB", "diamond")
    cfg["rrna_db"] = os.path.join(base, "DB", "bowtie2", "SILVA")
    cfg["results_dir"] = os.path.join(base, "results")
    cfg["clean_dir"] = os.path.join(base, "results", "01_clean_data")
    cfg["rrna_dir"] = os.path.join(base, "results", "02_rRNA_removed")
    cfg["assembly_dir"] = os.path.join(base, "results", "03_assembly")
    cfg["diamond_dir"] = os.path.join(base, "results", "04_diamond")
    cfg["phylogeny_dir"] = os.path.join(base, "results", "05_phylogeny")

    if sample:
        cfg["log_dir"] = os.path.join(base, "results", "log", sample)

    # 解析后缀列表
    r1_raw = cfg.get("input", {}).get("r1_suffixes", "")
    r2_raw = cfg.get("input", {}).get("r2_suffixes", "")
    cfg["r1_suffixes"] = [s.strip() for s in r1_raw.split(",") if s.strip()]
    cfg["r2_suffixes"] = [s.strip() for s in r2_raw.split(",") if s.strip()]

    return cfg


def get_cpu_count() -> int:
    """返回当前设备的 CPU 核数。"""
    return os.cpu_count() or 4


def discover_samples(cfg: dict = None) -> list:
    """
    扫描数据目录，自动发现所有双端测序样本。

    返回:
        list of dict: [{"sample": str, "r1": str, "r2": str}, ...]
        按样本名字母排序。
    """
    if cfg is None:
        cfg = load_config()

    data_dir = cfg["data_dir"]
    r1_suffixes = cfg.get("r1_suffixes", [])
    r2_suffixes = cfg.get("r2_suffixes", [])

    if not os.path.isdir(data_dir):
        sys.exit(f"ERROR: data directory not found: {data_dir}")

    if len(r1_suffixes) != len(r2_suffixes):
        sys.exit("ERROR: r1_suffixes and r2_suffixes must have the same number of entries")

    # 列出数据目录下所有文件
    all_files = set(os.listdir(data_dir))

    found = {}  # sample_name -> {"r1": path, "r2": path}

    for i, (r1_suf, r2_suf) in enumerate(zip(r1_suffixes, r2_suffixes)):
        for fname in sorted(all_files):
            if not fname.endswith(r1_suf):
                continue
            # 提取样本名：去掉 R1 后缀
            sample = fname[:-len(r1_suf)]
            if sample in found:
                continue  # 已通过其他模式匹配到

            # 构造 R2 文件名
            r2_fname = sample + r2_suf
            if r2_fname not in all_files:
                continue

            found[sample] = {
                "sample": sample,
                "r1": fname,
                "r2": r2_fname,
            }

    # 按样本名排序
    result = [found[k] for k in sorted(found.keys())]
    return result


# 命令行接口
if __name__ == "__main__":
    cfg = load_config()
    samples = discover_samples(cfg)

    print(f"CPU cores: {get_cpu_count()}")
    print(f"Data directory: {cfg['data_dir']}")
    print(f"Samples found: {len(samples)}")
    print()

    if len(sys.argv) > 1 and sys.argv[1] == "list":
        for s in samples:
            print(f"  {s['sample']}")
            print(f"    R1: {s['r1']}")
            print(f"    R2: {s['r2']}")
    else:
        for k, v in cfg.items():
            if k not in ("r1_suffixes", "r2_suffixes"):
                print(f"  {k}: {v}")
