#!/usr/bin/env python3
"""Manage s390x local artifacts: package, verify, upload, fetch, CSI."""

from __future__ import annotations

import argparse
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SIDELOAD = ROOT / "tools" / "sideload_s390x_artifacts.sh"
MIRROR_PACK = ROOT / "tools" / "pack_local_mirrors.sh"
MIRROR_UNPACK = ROOT / "tools" / "unpack_local_mirrors.sh"
DEFAULT_REMOTE_REPO = "/home/ubuntu/zopenstack/sunbeam"
DEFAULT_REMOTE_CSI = "/home/ubuntu/builds/s390x-k8s-images"
ALL_COMPONENTS = (
    "local-artifacts",
    "test-share",
    "diagnostic",
    "csi",
    "arch-report",
    "logs",
    "image-inventory",
)
DEFAULT_COMPONENTS = ("local-artifacts", "csi")


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+", " ".join(shlex.quote(c) for c in cmd), file=sys.stderr)
    return subprocess.run(cmd, check=True, **kwargs)


def copy_remote(source: str, dest: str) -> None:
    """Copy over SSH, preferring rsync's checksum comparison."""
    if shutil.which("rsync"):
        try:
            run(["rsync", "-av", "--partial", "--checksum", source, dest])
            return
        except subprocess.CalledProcessError:
            print("WARN: rsync failed; falling back to scp", file=sys.stderr)
    run(["scp", source, dest])


def newest_mirror_archive() -> Path | None:
    archives = sorted(
        (ROOT / "artifacts").glob("local-mirrors-*.tar.zst"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return archives[0] if archives else None


def newest_local_archive() -> Path | None:
    archives = sorted(
        (ROOT / "artifacts").glob("*/local-artifacts-*.tar.zst"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return archives[0] if archives else None


def cmd_list(_args: argparse.Namespace) -> int:
    archives = sorted(
        (ROOT / "artifacts").glob("*/local-artifacts-*.tar.zst"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not archives:
        print("no local-artifacts archives found")
        return 1
    for path in archives:
        print(f"{path.stat().st_size:>12}  {path}")
    csi = sorted((ROOT / "artifacts" / "lpar-builds" / "s390x-k8s-images").glob("*.tar"))
    if csi:
        print("\nCSI sidecars:")
        for path in csi:
            print(f"{path.stat().st_size:>12}  {path}")
    mirrors = sorted((ROOT / "artifacts").glob("local-mirrors-*.tar.zst"))
    if mirrors:
        print("\nLocal mirrors:")
        for path in mirrors:
            print(f"{path.stat().st_size:>12}  {path}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    archive = Path(args.archive) if args.archive else newest_local_archive()
    if archive is None:
        print("no local-artifacts archive found", file=sys.stderr)
        return 1
    if not archive.is_file():
        print(f"archive not found: {archive}", file=sys.stderr)
        return 1

    sha_file = archive.with_name(archive.name + ".sha256")
    if sha_file.is_file():
        run(["sha256sum", "-c", sha_file.name], cwd=archive.parent)

    with tempfile.TemporaryDirectory(prefix="artifacts-verify.") as tmp:
        run(["tar", "--zstd", "-xf", str(archive), "-C", tmp])
        root = Path(tmp) / "local-artifacts"
        sums = root / "SHA256SUMS"
        if sums.is_file():
            run(["sha256sum", "-c", "SHA256SUMS"], cwd=root)
        else:
            print(f"WARN: {sums} missing; only outer checksum verified", file=sys.stderr)
    print(f"verified {archive}")
    return 0


def cmd_package(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    output = Path(args.output).resolve()
    if output.exists() and not args.force:
        print(f"output exists: {output} (use --force)", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="local-artifacts.") as tmp:
        dest = Path(tmp) / "local-artifacts"
        for kind, ext in (("charms", ".charm"), ("snaps", ".snap"), ("rocks", ".rock")):
            src = repo / kind
            if not src.is_dir():
                continue
            out = dest / kind
            out.mkdir(parents=True, exist_ok=True)
            for path in sorted(src.glob(f"*{ext}")):
                shutil.copy2(path, out / path.name)

        if not any(dest.rglob("*.*")):
            print("no charms, snaps, or rocks found", file=sys.stderr)
            return 1

        (dest / "README.md").write_text(
            "# Local s390x artifacts\n\n"
            "Verify:\n\n"
            "    sha256sum -c SHA256SUMS\n\n"
            "## Charms\n\n"
            "    juju deploy ./charms/<name>_s390x.charm <application>\n\n"
            "## Snaps\n\n"
            "    sudo snap install --dangerous --devmode ./snaps/<name>_s390x.snap\n\n"
            "## Rocks\n\n"
            "    sudo k8s images import --base-name <repository> ./rocks/<name>_s390x.rock\n",
            encoding="utf-8",
        )
        files = sorted(p for p in dest.rglob("*") if p.is_file())
        with (dest / "SHA256SUMS").open("w", encoding="utf-8") as fh:
            for path in files:
                rel = path.relative_to(dest)
                digest = subprocess.check_output(["sha256sum", str(path)], text=True).split()[0]
                fh.write(f"{digest}  {rel}\n")

        output.parent.mkdir(parents=True, exist_ok=True)
        run(["tar", "--zstd", "-cf", str(output), "-C", tmp, "local-artifacts"])

    digest = subprocess.check_output(["sha256sum", str(output)], text=True).split()[0]
    output.with_name(output.name + ".sha256").write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    print(f"created {output}")
    print(f"created {output}.sha256")
    return 0


def sideload(args: argparse.Namespace, command: str) -> int:
    cmd = [str(SIDELOAD), command, args.target]
    if getattr(args, "archive", None):
        cmd += ["--archive", args.archive]
    if getattr(args, "upload_only", False):
        cmd += ["--upload-only"]
    if getattr(args, "no_csi", False):
        cmd += ["--no-csi"]
    return run(cmd).returncode


def cmd_upload(args: argparse.Namespace) -> int:
    return sideload(args, "upload")


def cmd_stage(args: argparse.Namespace) -> int:
    return sideload(args, "stage")


def cmd_install(args: argparse.Namespace) -> int:
    return sideload(args, "install")


def cmd_csi(args: argparse.Namespace) -> int:
    return sideload(args, "csi")


def cmd_all(args: argparse.Namespace) -> int:
    return sideload(args, "all")


def remote_newest_archive(target: str, remote_repo: str) -> str:
    pattern = f"{remote_repo}/artifacts/*/local-artifacts-*.tar.zst"
    cmd = ["ssh", target, f"ls -1t {pattern} 2>/dev/null | head -n1"]
    out = subprocess.check_output(cmd, text=True).strip()
    if not out:
        raise SystemExit(f"no remote local-artifacts archive under {remote_repo}/artifacts")
    return out


def cmd_mirrors_pack(args: argparse.Namespace) -> int:
    cmd = [str(MIRROR_PACK)]
    if args.output:
        cmd += ["--output", args.output]
    run(cmd)
    archive = Path(args.output) if args.output else newest_mirror_archive()
    if archive:
        print(f"created {archive}")
    return 0


def mirror_archive(args: argparse.Namespace) -> Path:
    archive = Path(args.archive) if args.archive else newest_mirror_archive()
    if archive is None:
        raise SystemExit("no local-mirrors archive found; run `artifacts.py mirrors pack`")
    if not archive.is_file():
        raise SystemExit(f"archive not found: {archive}")
    return archive


def cmd_mirrors_upload(args: argparse.Namespace) -> int:
    archive = mirror_archive(args)
    remote_dir = args.remote_dir.rstrip("/")
    run(["ssh", args.target, f"mkdir -p {shlex.quote(remote_dir)}"])
    run(["scp", str(archive), f"{args.target}:{remote_dir}/{archive.name}"])
    sha = archive.with_name(archive.name + ".sha256")
    if sha.is_file():
        run(["scp", str(sha), f"{args.target}:{remote_dir}/{sha.name}"])
    print(f"uploaded {archive.name} to {args.target}:{remote_dir}")
    return 0


def cmd_mirrors_unpack(args: argparse.Namespace) -> int:
    archive = mirror_archive(args)
    remote_dir = args.remote_dir.rstrip("/")
    remote_repo = args.remote_repo.rstrip("/")
    remote_archive = f"{remote_dir}/{archive.name}"
    run(["ssh", args.target, f"mkdir -p {shlex.quote(remote_repo + '/tools')}"])
    run(["scp", str(MIRROR_UNPACK), f"{args.target}:{remote_repo}/tools/"])
    run([
        "ssh", args.target,
        f"cd {shlex.quote(remote_repo)} && tools/unpack_local_mirrors.sh {shlex.quote(remote_archive)}",
    ])
    return 0


def cmd_mirrors_all(args: argparse.Namespace) -> int:
    cmd_mirrors_pack(args)
    cmd_mirrors_upload(args)
    return cmd_mirrors_unpack(args)


def parse_components(value: str | None) -> set[str]:
    if not value:
        return set(DEFAULT_COMPONENTS)
    parts = [p for p in re.split(r"[,\s]+", value.strip()) if p]
    unknown = set(parts) - set(ALL_COMPONENTS)
    if unknown:
        raise SystemExit(f"unknown fetch component(s): {', '.join(sorted(unknown))}")
    return set(parts)


def cmd_fetch(args: argparse.Namespace) -> int:
    remote_repo = args.remote_repo.rstrip("/")
    components = parse_components(args.only)
    if args.no_csi:
        components.discard("csi")
    if args.full:
        components = set(ALL_COMPONENTS)

    remote_archive = None
    if args.run_id:
        run_id = args.run_id
    else:
        remote_archive = remote_newest_archive(args.target, remote_repo)
        name = Path(remote_archive).name
        match = re.search(r"local-artifacts-[^-]+-(.+)\.tar\.zst$", name)
        run_id = match.group(1) if match else "lpar-fetch"

    dest = Path(args.dest).resolve() if args.dest else ROOT / "artifacts" / run_id
    dest.mkdir(parents=True, exist_ok=True)
    run_dir = f"{remote_repo}/artifacts/{run_id}"

    if "local-artifacts" in components:
        if remote_archive is None:
            pattern = f"{run_dir}/local-artifacts-*.tar.zst"
            cmd = ["ssh", args.target, f"ls -1t {pattern} 2>/dev/null | head -n1"]
            remote_archive = subprocess.check_output(cmd, text=True).strip()
            if not remote_archive:
                raise SystemExit(f"no local-artifacts archive for run {run_id}")
        archive_name = Path(remote_archive).name
        copy_remote(f"{args.target}:{remote_archive}", str(dest / archive_name))
        try:
            copy_remote(
                f"{args.target}:{remote_archive}.sha256",
                str(dest / (archive_name + ".sha256")),
            )
        except subprocess.CalledProcessError:
            print(
                f"WARN: remote checksum missing; run "
                f"`./artifacts.py verify {dest / archive_name}`",
                file=sys.stderr,
            )
        else:
            run(["sha256sum", "-c", archive_name + ".sha256"], cwd=dest)

    if "test-share" in components:
        copy_remote(f"{args.target}:{run_dir}/test-share-*.tar.zst*", str(dest) + "/")

    if "diagnostic" in components:
        copy_remote(f"{args.target}:{run_dir}/sunbeam-*.tar.zst*", str(dest) + "/")

    if "arch-report" in components:
        copy_remote(f"{args.target}:{run_dir}/arch_report.md", str(dest) + "/")

    if "logs" in components:
        copy_remote(f"{args.target}:{run_dir}/phase_*.log", str(dest) + "/")

    if "image-inventory" in components:
        copy_remote(f"{args.target}:{run_dir}/image_inventory.md", str(dest) + "/")

    if "csi" in components:
        csi_dest = dest / "s390x-k8s-images"
        csi_dest.mkdir(parents=True, exist_ok=True)
        copy_remote(f"{args.target}:{args.remote_csi_dir}/*.tar", str(csi_dest) + "/")

    if args.full:
        run([
            "rsync", "-av", "--partial", "--checksum",
            f"{args.target}:{run_dir}/",
            str(dest) + "/",
        ])

    print(f"fetched {', '.join(sorted(components))} for {run_id} into {dest}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("list", help="list local artifacts")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("verify", help="verify a local-artifacts archive")
    p.add_argument("archive", nargs="?")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("package", help="package charms/snaps/rocks")
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--output", default=str(ROOT / "artifacts" / "local-artifacts-s390x.tar.zst"))
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_package)

    for name, func in (
        ("upload", cmd_upload),
        ("stage", cmd_stage),
        ("install", cmd_install),
        ("csi", cmd_csi),
        ("all", cmd_all),
    ):
        p = sub.add_parser(name, help=f"{name} artifacts on an SSH target")
        p.add_argument("target")
        p.add_argument("--archive")
        if name == "csi":
            p.add_argument("--upload-only", action="store_true")
        if name == "all":
            p.add_argument("--no-csi", action="store_true")
        p.set_defaults(func=func)

    mirrors = sub.add_parser("mirrors", help="pack, upload, or unpack opendev mirrors")
    mirrors_sub = mirrors.add_subparsers(dest="mirrors_command", required=True)

    p = mirrors_sub.add_parser("pack", help="pack opendev mirrors")
    p.add_argument("--output")
    p.set_defaults(func=cmd_mirrors_pack)

    p = mirrors_sub.add_parser("upload", help="upload mirrors to an SSH target")
    p.add_argument("target")
    p.add_argument("--archive")
    p.add_argument("--remote-dir", default="/home/ubuntu")
    p.set_defaults(func=cmd_mirrors_upload)

    p = mirrors_sub.add_parser("unpack", help="unpack mirrors on an SSH target")
    p.add_argument("target")
    p.add_argument("--archive")
    p.add_argument("--remote-dir", default="/home/ubuntu")
    p.add_argument("--remote-repo", default=DEFAULT_REMOTE_REPO)
    p.set_defaults(func=cmd_mirrors_unpack)

    p = mirrors_sub.add_parser("all", help="pack, upload, and unpack mirrors")
    p.add_argument("target")
    p.add_argument("--output")
    p.add_argument("--remote-dir", default="/home/ubuntu")
    p.add_argument("--remote-repo", default=DEFAULT_REMOTE_REPO)
    p.set_defaults(func=cmd_mirrors_all)

    p = sub.add_parser("fetch", help="download artifacts from an SSH target")
    p.add_argument("target")
    p.add_argument("--run-id")
    p.add_argument("--dest")
    p.add_argument("--remote-repo", default=DEFAULT_REMOTE_REPO)
    p.add_argument("--remote-csi-dir", default=DEFAULT_REMOTE_CSI)
    p.add_argument("--no-csi", action="store_true")
    p.add_argument("--only", help="comma-separated components: "
                   "local-artifacts,test-share,diagnostic,csi,arch-report,logs,"
                   "image-inventory")
    p.add_argument("--full", action="store_true")
    p.set_defaults(func=cmd_fetch)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
