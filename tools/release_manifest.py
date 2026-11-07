#!/usr/bin/env python3
"""Build manifest of the DE1-SoC SD image (M8).

  release_manifest.py image <stage>   JSON for /usr/share/chess-npu/manifest.json, written while the
                                      rootfs is built: identity of every input that ends up on the card
  release_manifest.py release <dir>   adds the hashes of the finished outputs in <dir> (rootfs.tar,
                                      the SD image) and writes <dir>/manifest.json

Paths come from tools/env.sh variables passed in the environment (REPO_ROOT, BUILD_ROOT, NET_PATH,
RBF). Nothing here measures or tests anything; it records what was built from what.
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(os.environ["REPO_ROOT"])
BUILD = Path(os.environ["BUILD_ROOT"])


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def run(*cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def first_line(*cmd):
    out = run(*cmd)
    return out.splitlines()[0] if out else None


def git_state(path):
    commit = run("git", "-C", str(path), "rev-parse", "HEAD")
    dirty = run("git", "-C", str(path), "status", "--porcelain", "--untracked-files=no")
    return {"commit": commit, "dirty": bool(dirty)}


def file_entry(path):
    p = Path(path)
    return {"sha256": sha(p), "bytes": p.stat().st_size} if p.is_file() else None


def image_manifest(stage):
    stage = Path(stage)
    sf_lock = json.loads((REPO / "config/stockfish.lock.json").read_text())
    boot_lock = json.loads((REPO / "config/boot.lock.json").read_text())
    project = git_state(REPO)
    image_id = (project["commit"] or "unknown")[:12] + ("-dirty" if project["dirty"] else "")
    rbf = os.environ.get("RBF", "")
    rbf_info = Path(rbf + ".json")
    out = BUILD / "boot/out"
    files = {}
    for rel in ["usr/local/bin/stockfish", "usr/local/bin/stockfish-fpga", "usr/local/bin/nnue_board",
                "usr/local/bin/probe", "usr/local/bin/arm_replay", "usr/share/chess-npu/weights.bin",
                "usr/share/chess-npu/regress/stim.bin", "usr/share/chess-npu/regress/search.ev",
                "usr/share/chess-npu/regress/bench.ops", f"usr/share/stockfish/{sf_lock['default_network']}"]:
        e = file_entry(stage / rel)
        if e:
            files["/" + rel] = e
    boot = {name: file_entry(out / name) for name in
            ["u-boot-with-spl.sfp", "zImage", "socfpga_cyclone5_de1_soc.dtb"]}
    boot["/boot/fpga/board.rbf"] = file_entry(rbf) if rbf else None
    return {
        "image_id": image_id,
        "project": project,
        "stockfish": {k: sf_lock[k] for k in ["tag", "commit", "default_network", "network_sha256",
                                              "official_bench_nodes"]},
        "official_bench_nodes": sf_lock["official_bench_nodes"],
        "boot_lock": {k: {kk: v for kk, v in boot_lock[k].items() if kk in ("tag", "commit", "snapshot", "suite")}
                      for k in ("u_boot", "linux", "debian")},
        "source_date_epoch": int(os.environ.get("SOURCE_DATE_EPOCH", "0")),
        "fpga_image": json.loads(rbf_info.read_text()) if rbf_info.is_file() else None,
        "toolchain": {
            "host": first_line("uname", "-srm"),
            "os": next((l.split("=", 1)[1].strip('"') for l in Path("/etc/os-release").read_text().splitlines()
                        if l.startswith("PRETTY_NAME=")), None),
            "g++": first_line("g++", "--version"),
            "arm-linux-gnueabihf-g++": first_line("arm-linux-gnueabihf-g++", "--version"),
            "mmdebstrap": first_line("mmdebstrap", "--version"),
            "e2fsprogs": first_line("sh", "-c", "mke2fs -V 2>&1"),
        },
        "boot_files": boot,
        "files": files,
        "selftest": "chess-npu-selftest.service runs /usr/lib/chess-npu/selftest.sh once per boot",
        "regression": "/usr/lib/chess-npu/regress.sh [--rounds N]",
    }


def release_manifest(d):
    d = Path(d)
    m = json.loads((d / "image-manifest.json").read_text())
    m["outputs"] = {p.name: file_entry(p) for p in sorted(d.iterdir())
                    if p.is_file() and p.name not in ("manifest.json", "SHA256SUMS", "image-manifest.json")}
    (d / "manifest.json").write_text(json.dumps(m, indent=2) + "\n")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "image":
        print(json.dumps(image_manifest(sys.argv[2]), indent=2))
    elif len(sys.argv) == 3 and sys.argv[1] == "release":
        release_manifest(sys.argv[2])
    else:
        sys.exit(__doc__)
