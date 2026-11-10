#!/usr/bin/env python3
"""Single entry point for the s390x build artifacts.

This is intentionally a thin orchestrator: the existing shell builders still
own cloning, patching, and packing. Run it on the s390x builder host.
"""
from __future__ import annotations

import argparse
import os
import platform
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOOLS = ROOT / "tools"


def log(message: str) -> None:
    print(f"[build] {message}", file=sys.stderr)


def fatal(message: str) -> "NoReturn":
    log(f"FATAL: {message}")
    raise SystemExit(2)


def run_step(label: str, command: list[str], dry_run: bool, keep_going: bool,
             failures: list[str]) -> None:
    if dry_run:
        print(f"+ {shlex.join(command)}", file=sys.stderr)
        return

    log(f"==> {label}")
    try:
        result = subprocess.run(command, cwd=ROOT)
    except FileNotFoundError as exc:
        result = None
        rc = 127
        log(f"FAILED {label}: {exc}")
    else:
        rc = result.returncode

    if result is not None and rc == 0:
        log(f"ok {label}")
        return

    if result is not None:
        log(f"FAILED {label} (exit {rc})")
    if keep_going:
        failures.append(label)
        return
    raise SystemExit(rc)


def build_charms(dry_run: bool, keep_going: bool, failures: list[str]) -> None:
    run_step("charms", [str(TOOLS / "build_local_charms.sh")],
             dry_run, keep_going, failures)


def build_snaps(dry_run: bool, keep_going: bool, failures: list[str]) -> None:
    run_step("snaps", [str(TOOLS / "build_snaps.sh")],
             dry_run, keep_going, failures)


def build_rocks(names: list[str], dry_run: bool, keep_going: bool,
                failures: list[str]) -> None:
    if not names:
        raise SystemExit("rocks selected without names")

    if len(names) > 1:
        for variable in ("ROCK_SOURCE_DIR", "PUSH_IMAGE", "OUTPUT_IMAGE"):
            if os.environ.get(variable):
                fatal(f"{variable} can only be used with one rock")

    build_root = Path(os.environ.get("ROCK_BUILD_DIR", ROOT / ".rock-build"))
    source_override = os.environ.get("ROCK_SOURCE_DIR")
    builder = str(TOOLS / "build_rock.sh")

    for rock in names:
        source_dir = Path(source_override) if source_override else build_root / rock
        run_step(
            f"rock:{rock}",
            [builder, rock, "--source-dir", str(source_dir)],
            dry_run, keep_going, failures,
        )


def build_csi(dry_run: bool, keep_going: bool, failures: list[str]) -> None:
    repo = os.environ.get(
        "CSI_ROCK_REPO",
        "https://github.com/canonical/rawfile-localpv-rocks.git",
    )
    ref = os.environ.get("CSI_ROCK_REF", "main")
    source_dir = Path(os.environ.get(
        "CSI_ROCK_SOURCE_DIR",
        Path.home() / "builds" / "rawfile-localpv-rocks-s390x",
    ))
    image = os.environ.get(
        "CSI_ROCK_IMAGE",
        "docker.io/library/rawfile-localpv:0.8.3-s390x",
    )
    command = [
        str(TOOLS / "build_rock.sh"),
        "rawfile-localpv",
        "--repo", repo,
        "--ref", ref,
        "--source-dir", str(source_dir),
        "--subdir", ".",
        "--tag", image,
    ]
    push_image = os.environ.get("CSI_ROCK_PUSH_IMAGE")
    if push_image:
        command.extend(["--push", push_image])

    run_step("csi:rawfile-localpv", command, dry_run, keep_going, failures)
    log(f"CSI rock source: {source_dir}")
    log(f"staged rock: {ROOT / 'rocks' / 'rawfile-localpv_s390x.rock'}")
    log(f"phase 02b imports that rock as {image}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the s390x charms, snaps, rocks, and rawfile CSI rock.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  ./build.py
  ./build.py charms
  ./build.py all --rock rabbitmq
  ./build.py rocks --rock rabbitmq --rock cinder-consolidated
  ROCKS="rabbitmq cinder-consolidated" ./build.py rocks

Environment:
  OPENSTACK_SERIES          hibiscus (2026.2) by default; gazpacho selects 2026.1
  CHARM_OUT_DIR             default ./charms
  SNAP_OUT_DIR              default ./snaps
  ROCK_BUILD_DIR            default ./.rock-build
  ROCK_OUT_DIR              default ./rocks
  ROCK_SOURCE_DIR           explicit ubuntu-openstack-rocks checkout (one rock only)
  ROCK_REF                  rock source ref (default main)
  PUSH_IMAGE, OUTPUT_IMAGE  forwarded to build_rock.sh (one generic rock only)
  CSI_ROCK_REPO             default canonical/rawfile-localpv-rocks
  CSI_ROCK_REF              default main
  CSI_ROCK_SOURCE_DIR       default $HOME/builds/rawfile-localpv-rocks-s390x
  CSI_ROCK_IMAGE            default docker.io/library/rawfile-localpv:0.8.3-s390x
  CSI_ROCK_PUSH_IMAGE       optional registry ref for build_rock.sh --push

With no argument, builds "all": charms + snaps + csi. Generic rocks are built
only when named with --rock/--rocks or ROCKS.
""",
    )
    parser.add_argument(
        "component",
        nargs="?",
        default="all",
        choices=("all", "charms", "snaps", "rocks", "csi"),
    )
    parser.add_argument("--rock", action="append", default=[], metavar="NAME",
                        help="build one ubuntu-openstack rock (repeatable)")
    parser.add_argument("--rocks", metavar="LIST",
                        help="whitespace-separated rock names")
    parser.add_argument("--keep-going", action="store_true",
                        help="continue after a failed component")
    parser.add_argument("--dry-run", action="store_true",
                        help="print commands without executing them")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    names = list(os.environ.get("ROCKS", "").split())
    names.extend(args.rock)
    if args.rocks:
        names.extend(shlex.split(args.rocks))
    names = list(dict.fromkeys(names))

    if args.component not in ("all", "rocks") and (args.rock or args.rocks):
        fatal("--rock/--rocks requires the rocks or all component")
    if args.component == "rocks" and not names:
        fatal("rocks selected but none named; use --rock NAME or ROCKS='NAME ...'")

    if not args.dry_run and platform.machine() != "s390x":
        fatal("build on s390x; this workflow installs native wheels and uses native snapcraft")

    series = os.environ.get("OPENSTACK_SERIES", "hibiscus")
    log(f"repo={ROOT} series={series} arch={platform.machine()}")

    failures: list[str] = []
    components = ["charms", "snaps", "csi"] if args.component == "all" else [args.component]
    if names and args.component == "all":
        components.append("rocks")

    if args.component == "all" and not names:
        log("no generic rocks requested; skipping ubuntu-openstack rocks")

    for component in components:
        if component == "charms":
            build_charms(args.dry_run, args.keep_going, failures)
        elif component == "snaps":
            build_snaps(args.dry_run, args.keep_going, failures)
        elif component == "rocks":
            build_rocks(names, args.dry_run, args.keep_going, failures)
        elif component == "csi":
            build_csi(args.dry_run, args.keep_going, failures)

    if failures:
        log(f"failed components: {' '.join(failures)}")
        raise SystemExit(1)
    log("build complete")


if __name__ == "__main__":
    main()
