#!/usr/bin/env python3
"""Generate a Markdown image inventory from run artifacts.

Remote OCI images are reference-only. Locally built OCI images include
package detail and local artifact checksums. Local charms/snaps/rocks are
listed separately.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
from collections import defaultdict
from pathlib import Path

DEFAULT_LOCAL_IMAGES = ("docker.io/library/rawfile-localpv:0.8.3-s390x",)
SECTION = re.compile(r"^###\s+(\S+)\s+\[([^\]]+)\]\s+(\S+)\s*$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_sections(path: Path):
    sections = []
    current = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = SECTION.match(line)
        if match:
            if current:
                sections.append(current)
            current = {
                "pod": match.group(1),
                "container": match.group(2),
                "image": match.group(3),
                "packages": set(),
            }
            continue
        if current and "\t" in line:
            name, version = line.split("\t", 1)
            current["packages"].add((name.strip(), version.strip()))
    if current:
        sections.append(current)
    return sections


def ctr_inventory(ctr_bin: str, sock: str) -> dict[str, dict[str, str]]:
    result = {}
    try:
        out = subprocess.check_output(
            [
                "sudo",
                ctr_bin,
                "--address",
                sock,
                "--namespace",
                "k8s.io",
                "images",
                "ls",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return result

    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 6:
            continue
        result[parts[0]] = {
            "type": parts[1],
            "digest": parts[2],
            "platforms": parts[5],
        }
    return result


def artifact_rows(local_artifacts: Path, kind: str, suffix: str):
    rows = []
    directory = local_artifacts / kind
    if not directory.is_dir():
        return rows
    for path in sorted(directory.glob(f"*{suffix}")):
        rows.append((path.name, sha256(path)))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact_dir", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        help="output Markdown (default <artifact_dir>/image_inventory.md)",
    )
    parser.add_argument(
        "--local-image",
        action="append",
        default=[],
        help="image reference produced locally (repeatable)",
    )
    parser.add_argument("--run-id")
    parser.add_argument("--ctr-bin", default="/snap/k8s/current/bin/ctr")
    parser.add_argument(
        "--containerd-sock", default="/run/containerd/containerd.sock"
    )
    args = parser.parse_args()

    artifact_dir = args.artifact_dir.resolve()
    inventory = artifact_dir / "image_package_versions.txt"
    if not inventory.is_file():
        raise SystemExit(f"missing {inventory}")

    local_artifacts = artifact_dir / "local-artifacts"
    local_images = set(args.local_image or DEFAULT_LOCAL_IMAGES)
    sections = parse_sections(inventory)
    if not sections:
        raise SystemExit(f"no image sections in {inventory}")

    ctr = ctr_inventory(args.ctr_bin, args.containerd_sock)
    by_image = defaultdict(list)
    for section in sections:
        by_image[section["image"]].append(section)

    run_id = args.run_id or artifact_dir.name
    output = args.output or artifact_dir / "image_inventory.md"
    lines = [
        "# Sunbeam s390x image inventory",
        "",
        f"Run ID: `{run_id}`",
        f"Architecture: `s390x`",
        "",
        "## Remote OCI images",
        "",
        "Reference-only entries. Package contents are not re-reported.",
        "",
        "| Image | Digest | Platform | Used by |",
        "|---|---|---|---|",
    ]

    for image in sorted(by_image):
        if image in local_images:
            continue
        info = ctr.get(image, {})
        digest = info.get("digest", "not captured")
        platform = info.get("platforms", "not captured")
        users = sorted({f"{s['pod']} [{s['container']}]" for s in by_image[image]})
        lines.append(
            f"| `{image}` | `{digest}` | `{platform}` | {', '.join(users)} |"
        )

    lines += [
        "",
        "## Locally built OCI images",
        "",
    ]
    for image in sorted(local_images):
        image_sections = by_image.get(image, [])
        packages = set()
        for section in image_sections:
            packages.update(section["packages"])
        info = ctr.get(image, {})
        users = sorted({f"{s['pod']} [{s['container']}]" for s in image_sections})
        package_line = (
            f"- Packages: `{len(packages)}`"
            if packages
            else "- Packages: not captured"
        )
        lines += [
            f"### `{image}`",
            "",
            f"- Digest: `{info.get('digest', 'not captured')}`",
            f"- Platform: `{info.get('platforms', 'not captured')}`",
            package_line,
            f"- Used by: {', '.join(users) if users else 'not captured'}",
            "",
        ]

    lines += [
        "## Local non-OCI artifacts",
        "",
        "### Charms",
        "",
        "| Charm | SHA256 |",
        "|---|---|",
    ]
    for name, digest in artifact_rows(local_artifacts, "charms", ".charm"):
        lines.append(f"| `{name}` | `{digest}` |")

    lines += [
        "",
        "### Snaps",
        "",
        "| Snap | SHA256 |",
        "|---|---|",
    ]
    for name, digest in artifact_rows(local_artifacts, "snaps", ".snap"):
        lines.append(f"| `{name}` | `{digest}` |")

    lines += [
        "",
        "### Rocks",
        "",
        "| Rock | SHA256 |",
        "|---|---|",
    ]
    for name, digest in artifact_rows(local_artifacts, "rocks", ".rock"):
        lines.append(f"| `{name}` | `{digest}` |")

    empty = [s for s in sections if not s["packages"]]
    lines += [
        "",
        "## Capture gaps",
        "",
        f"- Empty package sections: `{len(empty)}`",
    ]
    for section in empty:
        lines.append(
            f"- `{section['pod']} [{section['container']}]` "
            f"({section['image']})"
        )

    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
