#!/usr/bin/env python3
"""
汉坦病毒 Pipeline 包装脚本
=============================
所有脚本打包在 Skill 内部（skills/hantavirus-pipeline/scripts/）。
主配置 config.yaml 在 scripts/ 的上一级（skill 根目录），
启动时自动同步到 scripts/config.yaml 给 config_loader.py 使用。
通过 conda run 调用。

用法:
  cd /path/to/hantavirus-pipeline
  conda run -n lpy-hantavirus-skills \
    python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py preflight
  conda run -n lpy-hantavirus-skills \
    python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py discover
  conda run -n lpy-hantavirus-skills \
    python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py run-sample -s SRR24113203
  conda run -n lpy-hantavirus-skills \
    python skills/hantavirus-pipeline/scripts/hantavirus_skill_runner.py collect -s SRR24113203

设计原则:
  - 大日志写文件，stdout 只输出短 JSON / 状态行
  - 所有路径从 config.yaml 推导，不硬编码
  - 返回码: 0=成功, 1=失败, 2=跳过(数据不存在)
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime


# ═══════════════════════════════════════════════════════════════
# 路径解析
# ═══════════════════════════════════════════════════════════════

def get_scripts_dir() -> str:
    """返回 wrapper 自身所在目录（skill 的 scripts/）。"""
    return os.path.dirname(os.path.abspath(__file__))


def get_skill_dir() -> str:
    """返回 skill 根目录（scripts/ 的上一级，与 scripts/ 和 config.yaml 同级）。"""
    return os.path.dirname(get_scripts_dir())


def get_pipeline_root() -> str:
    """
    返回 pipeline 根目录（skill 的 ../../）。
    scripts/ → hantavirus-pipeline/ → skills/ → pipeline_root/
    """
    skill_dir = get_skill_dir()               # .../skills/hantavirus-pipeline
    skills_dir = os.path.dirname(skill_dir)    # .../skills
    return os.path.dirname(skills_dir)         # .../hantavirus-pipeline (pipeline root)


def load_config() -> dict:
    """
    加载 skill 根目录的 config.yaml，自动推导所有子目录。
    随后同步到 scripts/config.yaml 供 config_loader.py 读取。
    """
    import yaml

    cfg_path = os.path.join(get_skill_dir(), "config.yaml")

    if not os.path.exists(cfg_path):
        die(1, f"Master config not found: {cfg_path}")

    with open(cfg_path) as f:
        cfg = yaml.safe_load(f)

    base = cfg["project_dir"]

    cfg.update({
        "data_dir":       os.path.join(base, "data"),
        "db_dir":         os.path.join(base, "DB", "diamond"),
        "rrna_db":        os.path.join(base, "DB", "bowtie2", "SILVA"),
        "results_dir":    os.path.join(base, "results"),
        "clean_dir":      os.path.join(base, "results", "01_clean_data"),
        "rrna_dir":       os.path.join(base, "results", "02_rRNA_removed"),
        "assembly_dir":   os.path.join(base, "results", "03_assembly"),
        "diamond_dir":    os.path.join(base, "results", "04_diamond"),
        "phylogeny_dir":  os.path.join(base, "results", "05_phylogeny"),
    })

    # 解析后缀列表
    r1_raw = cfg.get("input", {}).get("r1_suffixes", "")
    r2_raw = cfg.get("input", {}).get("r2_suffixes", "")
    cfg["r1_suffixes"] = [s.strip() for s in r1_raw.split(",") if s.strip()]
    cfg["r2_suffixes"] = [s.strip() for s in r2_raw.split(",") if s.strip()]

    # 同步到 scripts/config.yaml（config_loader.py 从自己目录读）
    sync_config(cfg_path)

    return cfg


def sync_config(master_path: str):
    """把主 config.yaml 同步到 scripts/config.yaml。"""
    dst = os.path.join(get_scripts_dir(), "config.yaml")
    if os.path.exists(master_path):
        shutil.copy2(master_path, dst)


# ═══════════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════════

def die(code: int, msg: str):
    print(json.dumps({"status": "error", "message": msg}), flush=True)
    sys.exit(code)


def ok(data: dict = None):
    out = {"status": "success"}
    if data:
        out.update(data)
    print(json.dumps(out, default=str), flush=True)
    sys.exit(0)


def skip(reason: str):
    print(json.dumps({"status": "skipped", "reason": reason}), flush=True)
    sys.exit(2)


def run_cmd(cmd: str, log_file: str = None, timeout: int = 7200) -> int:
    """运行命令，可选日志重定向。返回 exit_code。"""
    if log_file:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        with open(log_file, "a") as lf:
            lf.write(f"\n{'='*60}\n")
            lf.write(f"[{datetime.now().isoformat()}] {cmd}\n")
            lf.write(f"{'='*60}\n")
            ret = subprocess.run(cmd, shell=True, stdout=lf, stderr=subprocess.STDOUT,
                                 timeout=timeout)
    else:
        ret = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                             timeout=timeout)
        if ret.stdout:
            print(ret.stdout, end="", flush=True)
        if ret.stderr:
            print(ret.stderr, end="", file=sys.stderr, flush=True)
    return ret.returncode


def conda_prefix(cfg: dict) -> str:
    """返回 conda run 前缀。"""
    env = cfg.get("conda_env", "lpy-hantavirus-skills")
    return f"conda run -n {env}"


# ═══════════════════════════════════════════════════════════════
# 子命令
# ═══════════════════════════════════════════════════════════════

def cmd_preflight(cfg: dict):
    """
    环境预检。检查 conda 环境、脚本、数据、数据库、工具链。
    结果写入 results/preflight/preflight_report.json，stdout 只输出摘要。
    """
    from importlib import import_module

    report = {"timestamp": datetime.now().isoformat(), "checks": {}}
    checks = report["checks"]
    scripts_dir = get_scripts_dir()

    # ---- 1. conda 环境 ----
    try:
        ret = subprocess.run(["conda", "env", "list"], capture_output=True, text=True, timeout=10)
        env_list = ret.stdout
        env_name = cfg.get("conda_env", "lpy-hantavirus-skills")
        checks["conda_env"] = {
            "name": env_name,
            "exists": env_name in env_list,
            "message": f"conda env '{env_name}' {'found' if env_name in env_list else 'NOT FOUND'}",
        }
    except Exception as e:
        checks["conda_env"] = {"name": cfg.get("conda_env", ""), "exists": False, "message": str(e)}

    # ---- 2. 脚本文件（skill 的 scripts/ 目录内）----
    required_scripts = [
        "run_pipeline.sh", "config_loader.py",
        "step01_merge_diamond.py", "step04_build_trees.py",
        "step05_verify_trees.py", "step06_report.py",
    ]
    script_status = {}
    all_scripts_present = True
    for s in required_scripts:
        sp = os.path.join(scripts_dir, s)
        exists = os.path.exists(sp)
        script_status[s] = exists
        if not exists:
            all_scripts_present = False
    checks["scripts"] = {
        "path": scripts_dir,
        "all_present": all_scripts_present,
        "files": script_status,
        "message": "All scripts found" if all_scripts_present else "MISSING scripts",
    }

    # ---- 3. config.yaml ----
    master = os.path.join(get_skill_dir(), "config.yaml")
    checks["config_yaml"] = {
        "master": master,
        "exists": os.path.exists(master),
        "message": "OK" if os.path.exists(master) else f"NOT FOUND: {master}",
    }

    # ---- 4. project_dir / data ----
    data_dir = cfg["data_dir"]
    checks["data_dir"] = {
        "path": data_dir,
        "exists": os.path.isdir(data_dir),
        "message": "OK" if os.path.isdir(data_dir) else f"NOT FOUND: {data_dir}",
    }

    # ---- 5. 数据库 ----
    db_checks = {}
    db_dir = cfg["db_dir"]
    for seg in ["L", "M", "S"]:
        dmnd = os.path.join(db_dir, f"{seg}.dmnd")
        faa = os.path.join(db_dir, f"{seg}.faa")
        db_checks[f"{seg}.dmnd"] = os.path.exists(dmnd)
        db_checks[f"{seg}.faa"] = os.path.exists(faa)
    db_all = all(db_checks.values())
    checks["diamond_db"] = {
        "path": db_dir,
        "all_present": db_all,
        "files": db_checks,
        "message": "All DB files found" if db_all else "MISSING DB files",
    }

    # ---- 6. SILVA rRNA DB ----
    rrna_db = cfg["rrna_db"]
    silva_exists = False
    for suffix in [".1.bt2", ".2.bt2", ".3.bt2", ".4.bt2", ".rev.1.bt2", ".rev.2.bt2"]:
        if os.path.exists(rrna_db + suffix):
            silva_exists = True
            break
    checks["bowtie2_silva_db"] = {
        "path": rrna_db,
        "exists": silva_exists,
        "message": "SILVA index found" if silva_exists else f"NOT FOUND: {rrna_db}*.bt2",
    }

    # ---- 7. CLI 工具 ----
    tools = ["fastp", "bowtie2", "megahit", "diamond", "prodigal", "mafft", "iqtree"]
    tool_checks = {}
    all_tools = True
    for tool in tools:
        try:
            ret = subprocess.run(
                f"{conda_prefix(cfg)} {tool} --version",
                shell=True, capture_output=True, text=True, timeout=15,
            )
            version_line = (ret.stdout or ret.stderr or "").split("\n")[0].strip()
            exists = tool in (ret.stdout + ret.stderr).lower() or version_line
            tool_checks[tool] = {
                "available": True,
                "version": version_line[:80] if version_line else "detected",
            }
        except Exception as e:
            tool_checks[tool] = {"available": False, "version": str(e)[:80]}
            all_tools = False
    checks["cli_tools"] = {
        "all_available": all_tools,
        "tools": tool_checks,
        "message": "All tools available" if all_tools else "MISSING tools",
    }

    # ---- 8. Python 包 ----
    py_packages = ["yaml", "pandas", "ete3"]
    pkg_checks = {}
    all_pkgs = True
    for pkg in py_packages:
        try:
            mod = import_module(pkg)
            ver = getattr(mod, "__version__", "OK")
            pkg_checks[pkg] = {"available": True, "version": str(ver)}
        except ImportError:
            pkg_checks[pkg] = {"available": False, "version": "N/A"}
            all_pkgs = False
    checks["python_packages"] = {
        "all_available": all_pkgs,
        "packages": pkg_checks,
        "message": "All Python packages available" if all_pkgs else "MISSING packages",
    }

    # ---- 汇总 ----
    report["overall_pass"] = all([
        checks["conda_env"]["exists"],
        checks["scripts"]["all_present"],
        checks["config_yaml"]["exists"],
        checks["data_dir"]["exists"],
        checks["diamond_db"]["all_present"],
        checks["bowtie2_silva_db"]["exists"],
        checks["cli_tools"]["all_available"],
        checks["python_packages"]["all_available"],
    ])

    # ---- 写入文件 ----
    outdir = os.path.join(get_pipeline_root(), "results", "preflight")
    os.makedirs(outdir, exist_ok=True)
    outpath = os.path.join(outdir, "preflight_report.json")
    with open(outpath, "w") as f:
        json.dump(report, f, indent=2, default=str)

    # ---- stdout: 短摘要 ----
    summary = {
        "status": "success",
        "overall_pass": report["overall_pass"],
        "report_path": outpath,
        "failures": [k for k, v in checks.items()
                     if isinstance(v, dict) and not v.get(
                         "exists", v.get("all_present", v.get("all_available", True)))],
    }
    print(json.dumps(summary, default=str), flush=True)
    sys.exit(0 if report["overall_pass"] else 1)


def cmd_discover(cfg: dict):
    """发现样本。通过 skill 内的 config_loader.py 扫描数据目录。"""
    scripts_dir = get_scripts_dir()

    discover_cmd = (
        f'{conda_prefix(cfg)} python3 -c "'
        f'import sys, json; sys.path.insert(0, \\\"{scripts_dir}\\\"); '
        f'from config_loader import discover_samples, load_config; '
        f'_cfg = load_config(); '
        f'samples = discover_samples(_cfg); '
        f'print(json.dumps(samples))'
        f'"'
    )

    ret = subprocess.run(discover_cmd, shell=True, capture_output=True, text=True, timeout=30)
    if ret.returncode != 0:
        die(1, f"Discover failed: {ret.stderr}")

    try:
        samples = json.loads(ret.stdout.strip())
    except json.JSONDecodeError:
        die(1, f"Failed to parse discover output: {ret.stdout[:500]}")

    if not samples:
        skip("No samples found in data directory")

    # 写入 sample_sheet.csv
    outdir = os.path.join(get_pipeline_root(), "results")
    os.makedirs(outdir, exist_ok=True)

    import csv
    csv_path = os.path.join(outdir, "sample_sheet.csv")
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["sample", "r1", "r2"])
        w.writeheader()
        w.writerows(samples)

    # 写入 pending_samples.txt
    pending_path = os.path.join(outdir, "pending_samples.txt")
    sample_names = [s["sample"] for s in samples]
    with open(pending_path, "w") as f:
        f.write("\n".join(sample_names) + "\n")

    ok({
        "sample_count": len(samples),
        "samples": sample_names,
        "sample_sheet": csv_path,
        "pending_list": pending_path,
    })


def cmd_run_sample(cfg: dict, sample: str):
    """
    处理单个样本。执行所有步骤。大日志写文件，stdout 只输出短 JSON。
    遇错即停。
    """
    scripts_dir = get_scripts_dir()

    # 日志目录
    log_dir = os.path.join(get_pipeline_root(), "results", "log", sample)
    os.makedirs(log_dir, exist_ok=True)

    steps = [
        ("pipeline", f"bash {scripts_dir}/run_pipeline.sh {sample}"),
        ("step01",   f"python3 {scripts_dir}/step01_merge_diamond.py {sample}"),
        ("step04",   f"python3 {scripts_dir}/step04_build_trees.py {sample}"),
        ("step05",   f"python3 {scripts_dir}/step05_verify_trees.py {sample}"),
        ("step06",   f"python3 {scripts_dir}/step06_report.py {sample}"),
    ]

    results = {}
    all_ok = True

    for step_name, cmd in steps:
        log_file = os.path.join(log_dir, f"{step_name}.log")
        full_cmd = f"{conda_prefix(cfg)} {cmd}"
        ret_code = run_cmd(full_cmd, log_file=log_file)

        if ret_code != 0:
            results[step_name] = {"status": "failed", "exit_code": ret_code, "log": log_file}
            all_ok = False
            break
        else:
            results[step_name] = {"status": "ok", "log": log_file}

    final_report = os.path.join(
        cfg["phylogeny_dir"], sample, "step06_final_report.tsv"
    ) if all_ok else None

    if all_ok and not os.path.exists(final_report):
        all_ok = False
        results["step06"] = {"status": "missing_output", "expected": final_report}

    summary = {
        "sample": sample,
        "status": "success" if all_ok else "failed",
        "steps": results,
        "final_report": final_report if all_ok else None,
        "sample_result_dir": os.path.join(cfg["phylogeny_dir"], sample),
        "log_dir": log_dir,
    }

    print(json.dumps(summary, default=str), flush=True)
    sys.exit(0 if all_ok else 1)


def cmd_collect(cfg: dict, sample: str):
    """收集单个样本结果路径，只检查文件存在性。"""
    final_report = os.path.join(cfg["phylogeny_dir"], sample, "step06_final_report.tsv")
    verif_csv = os.path.join(cfg["phylogeny_dir"], sample, "step05_verification.csv")
    merged_csv = os.path.join(cfg["phylogeny_dir"], sample, "step01_merged_hits.csv")

    files = {
        "final_report": final_report,
        "verification":  verif_csv,
        "merged_hits":   merged_csv,
    }

    status_map = {}
    for name, path in files.items():
        status_map[name] = {
            "path": path,
            "exists": os.path.exists(path),
            "size": os.path.getsize(path) if os.path.exists(path) else 0,
        }

    all_exist = all(v["exists"] for v in status_map.values())

    summary = {
        "sample": sample,
        "complete": all_exist,
        "files": status_map,
        "result_dir": os.path.join(cfg["phylogeny_dir"], sample),
    }

    print(json.dumps(summary, default=str), flush=True)
    sys.exit(0 if all_exist else 1)


# ═══════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        prog="hantavirus_skill_runner",
        description="汉坦病毒 Pipeline 包装脚本（所有脚本打包在 skill 内）",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("preflight", help="环境预检")
    sub.add_parser("discover", help="发现样本")

    run = sub.add_parser("run-sample", help="处理单个样本")
    run.add_argument("--sample", "-s", required=True, help="样本名 (如 SRR24113203)")

    col = sub.add_parser("collect", help="收集样本结果")
    col.add_argument("--sample", "-s", required=True, help="样本名 (如 SRR24113203)")

    args = parser.parse_args()

    try:
        cfg = load_config()
    except Exception as e:
        die(1, f"Config load error: {e}")

    if args.command == "preflight":
        cmd_preflight(cfg)
    elif args.command == "discover":
        cmd_discover(cfg)
    elif args.command == "run-sample":
        cmd_run_sample(cfg, args.sample)
    elif args.command == "collect":
        cmd_collect(cfg, args.sample)


if __name__ == "__main__":
    main()
