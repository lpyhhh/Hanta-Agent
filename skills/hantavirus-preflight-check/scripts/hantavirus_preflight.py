#!/usr/bin/env python3

import argparse
import csv
import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


STATUS_SUCCESS = "success"
STATUS_DATA_MISSING = "data_missing"
STATUS_REPO_FAILED = "repo_failed"
STATUS_ENVIRONMENT_YAML_MISSING = "environment_yaml_missing"
STATUS_SKILLS_MISSING = "skills_missing"
STATUS_SKILLS_INSTALL_FAILED = "skills_install_failed"
STATUS_CONDA_MISSING = "conda_missing"
STATUS_ENV_CREATE_FAILED = "env_create_failed"
STATUS_SAMPLE_PAIRING_FAILED = "sample_pairing_failed"
STATUS_DB_MISSING = "db_missing"


@dataclass
class PairingResult:
    sample: str
    read1: str
    read2: str


class PreflightError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def log(message, log_path):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(message + "\n")


def run_command(command, log_path, cwd=None):
    result = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
    )
    log("$ " + " ".join(command), log_path)
    if result.stdout:
        log(result.stdout.rstrip(), log_path)
    if result.stderr:
        log(result.stderr.rstrip(), log_path)
    return result


def ensure_output_parent(output_path):
    output_path.parent.mkdir(parents=True, exist_ok=True)


def write_json(path, payload):
    ensure_output_parent(path)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def detect_pair_info(name):
    patterns = [
        ("_R1_001.fastq.gz", "_R2_001.fastq.gz"),
        ("_R1.fastq.gz", "_R2.fastq.gz"),
        ("_r1.fastq.gz", "_r2.fastq.gz"),
        ("_1.fastq.gz", "_2.fastq.gz"),
    ]
    for left, right in patterns:
        if name.endswith(left):
            return name[: -len(left)], "R1"
        if name.endswith(right):
            return name[: -len(right)], "R2"
    return None


def pair_reads(data_dir):
    buckets = {}
    ignored = []
    for path in sorted(data_dir.iterdir()):
        if not path.is_file():
            continue
        info = detect_pair_info(path.name)
        if info is None:
            ignored.append(path.name)
            continue
        sample, mate = info
        entry = buckets.setdefault(sample, {"R1": None, "R2": None})
        entry[mate] = path.name

    paired = []
    unmatched = []
    for sample, mates in sorted(buckets.items()):
        if mates["R1"] and mates["R2"]:
            paired.append(PairingResult(sample=sample, read1=mates["R1"], read2=mates["R2"]))
        else:
            if mates["R1"]:
                unmatched.append(mates["R1"])
            if mates["R2"]:
                unmatched.append(mates["R2"])

    unmatched.extend(ignored)
    return paired, unmatched


def write_sample_outputs(workdir, paired, unmatched):
    preflight_dir = workdir / "results" / "preflight"
    sample_sheet = preflight_dir / "sample_sheet.csv"
    unmatched_file = preflight_dir / "unmatched_reads.txt"

    with sample_sheet.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["sample_id", "read1", "read2"])
        for item in paired:
            writer.writerow([item.sample, item.read1, item.read2])

    with unmatched_file.open("w", encoding="utf-8") as handle:
        for item in unmatched:
            handle.write(item + "\n")

    return sample_sheet, unmatched_file


def clone_or_update_repo(repo_url, repo_dir, log_path):
    if repo_dir.exists():
        if not (repo_dir / ".git").exists():
            raise PreflightError(STATUS_REPO_FAILED, f"Repository path exists but is not a git repository: {repo_dir}")
        result = run_command(["git", "pull", "--ff-only"], log_path, cwd=repo_dir)
        if result.returncode != 0:
            raise PreflightError(STATUS_REPO_FAILED, f"Failed to update repository at {repo_dir}")
    else:
        result = run_command(["git", "clone", repo_url, str(repo_dir)], log_path)
        if result.returncode != 0:
            raise PreflightError(STATUS_REPO_FAILED, f"Failed to clone repository from {repo_url}")


def sync_skills(src_dir, dest_dir):
    if not src_dir.exists():
        raise PreflightError(STATUS_SKILLS_MISSING, f"Skills directory missing: {src_dir}")

    dest_dir.mkdir(parents=True, exist_ok=True)
    try:
        for child in src_dir.iterdir():
            target = dest_dir / child.name
            if child.is_dir():
                shutil.copytree(child, target, dirs_exist_ok=True)
            elif child.is_file():
                shutil.copy2(child, target)
    except Exception as exc:
        raise PreflightError(STATUS_SKILLS_INSTALL_FAILED, str(exc)) from exc


def conda_available():
    return shutil.which("conda") is not None


def conda_env_exists(env_name, log_path):
    result = run_command(["conda", "env", "list", "--json"], log_path)
    if result.returncode != 0:
        raise PreflightError(STATUS_CONDA_MISSING, "Unable to query conda environments")
    payload = json.loads(result.stdout or "{}")
    for env_path in payload.get("envs", []):
        if Path(env_path).name == env_name:
            return True
    return False


def create_conda_env(environment_yaml, log_path):
    result = run_command(["conda", "env", "create", "-f", str(environment_yaml)], log_path)
    if result.returncode != 0:
        raise PreflightError(STATUS_ENV_CREATE_FAILED, f"Failed to create conda environment from {environment_yaml}")


def summarize_log(log_path):
    if not log_path.exists():
        return []
    return log_path.read_text(encoding="utf-8").splitlines()[-20:]


def build_report(status, workdir, repo_dir, sample_sheet, unmatched_file, log_path, env_name, message):
    return {
        "status": status,
        "message": message,
        "workdir": str(workdir),
        "repo_dir": str(repo_dir),
        "env_name": env_name,
        "files": {
            "sample_sheet": str(sample_sheet),
            "unmatched_reads": str(unmatched_file),
            "log": str(log_path),
        },
        "log_summary": summarize_log(log_path),
    }


def run_check(args):
    workdir = Path(args.workdir).expanduser().resolve()
    if not workdir.exists():
        raise SystemExit(f"ERROR: workdir does not exist: {workdir}")

    preflight_dir = workdir / "results" / "preflight"
    logs_dir = workdir / "logs"
    preflight_dir.mkdir(parents=True, exist_ok=True)
    logs_dir.mkdir(parents=True, exist_ok=True)

    log_path = logs_dir / "preflight.log"
    if log_path.exists():
        log_path.unlink()

    data_dir = workdir / "data"
    sample_sheet = preflight_dir / "sample_sheet.csv"
    unmatched_file = preflight_dir / "unmatched_reads.txt"
    repo_dir = workdir / "Yu-Lab-Hantavirus"
    output_path = Path(args.output).expanduser().resolve()

    if not data_dir.exists():
        write_sample_outputs(workdir, [], [])
        report = build_report(
            STATUS_DATA_MISSING,
            workdir,
            repo_dir,
            sample_sheet,
            unmatched_file,
            log_path,
            args.env_name,
            "data/ is missing; place paired-end read files before rerunning preflight.",
        )
        write_json(output_path, report)
        print(f"Success! Data written to: {output_path}")
        return 1

    try:
        clone_or_update_repo(args.repo_url, repo_dir, log_path)

        environment_yaml = repo_dir / "environment.yaml"
        if not environment_yaml.exists():
            raise PreflightError(STATUS_ENVIRONMENT_YAML_MISSING, f"Missing environment file: {environment_yaml}")

        repo_skills_dir = repo_dir / "skills"
        if not repo_skills_dir.exists():
            raise PreflightError(STATUS_SKILLS_MISSING, f"Missing skills directory: {repo_skills_dir}")

        sync_skills(repo_skills_dir, workdir / ".agents" / "skills")

        if not conda_available():
            raise PreflightError(STATUS_CONDA_MISSING, "conda executable not found")

        if not conda_env_exists(args.env_name, log_path):
            create_conda_env(environment_yaml, log_path)

        paired, unmatched = pair_reads(data_dir)
        write_sample_outputs(workdir, paired, unmatched)
        if unmatched:
            raise PreflightError(
                STATUS_SAMPLE_PAIRING_FAILED,
                "One or more read files could not be paired. See unmatched_reads.txt.",
            )

        db_dir = workdir / "DB"
        if not db_dir.exists():
            db_dir.mkdir(parents=True, exist_ok=True)
            (db_dir / "kraken2").mkdir(exist_ok=True)
            (db_dir / "bowtie").mkdir(exist_ok=True)
            raise PreflightError(
                STATUS_DB_MISSING,
                "DB/ was missing and has been created as an empty placeholder. Populate it manually before analysis.",
            )

        report = build_report(
            STATUS_SUCCESS,
            workdir,
            repo_dir,
            sample_sheet,
            unmatched_file,
            log_path,
            args.env_name,
            "Preflight completed successfully.",
        )
        write_json(output_path, report)
        print(f"Success! Data written to: {output_path}")
        return 0
    except PreflightError as exc:
        report = build_report(
            exc.status,
            workdir,
            repo_dir,
            sample_sheet,
            unmatched_file,
            log_path,
            args.env_name,
            exc.message,
        )
        write_json(output_path, report)
        print(f"Success! Data written to: {output_path}")
        return 1


def build_parser():
    parser = argparse.ArgumentParser(description="Hantavirus preflight utilities")
    subparsers = parser.add_subparsers(dest="command", required=True)

    check_parser = subparsers.add_parser("check", help="Run preflight checks")
    check_parser.add_argument("--workdir", required=True)
    check_parser.add_argument("--repo-url", required=True)
    check_parser.add_argument("--env-name", required=True)
    check_parser.add_argument("--output", required=True)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "check":
        raise SystemExit(run_check(args))

    parser.error(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    main()
