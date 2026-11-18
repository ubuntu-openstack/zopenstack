#!/usr/bin/env bash
# Package the LPAR working tree and build inputs before a wipe.
#
# Usage:
#   tools/package_s390x_artifacts.sh [options]
#
# Options:
#   --output PATH       archive path (default: ~/zopenstack-artifacts.tar.zst)
#   --repo PATH         repo root (default: ~/zopenstack/sunbeam)
#   --no-artifacts      exclude the repo's artifacts/ directory
#   --no-builds         exclude ~/builds
#   --no-charms-src     exclude ~/sunbeam-charms-src
#   --no-gitconfig      exclude ~/.gitconfig
#   --force             overwrite an existing archive
#   --dry-run           print the tar command without creating the archive
#   --help
#
# The default archive name has no date or run ID, so the same name can be
# copied to a workstation and restored on a fresh LPAR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${HOME}/zopenstack/sunbeam}"
OUTPUT="${HOME}/zopenstack-artifacts.tar.zst"
include_artifacts=1
include_builds=1
include_charms_src=1
include_gitconfig=1
force=0
dry_run=0

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "FATAL: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="${2:?--output needs a value}"; shift 2 ;;
        --repo) REPO_ROOT="${2:?--repo needs a value}"; shift 2 ;;
        --no-artifacts) include_artifacts=0; shift ;;
        --no-builds) include_builds=0; shift ;;
        --no-charms-src) include_charms_src=0; shift ;;
        --no-gitconfig) include_gitconfig=0; shift ;;
        --force) force=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -d "${REPO_ROOT}" ]] || die "repo not found: ${REPO_ROOT}"
[[ "${REPO_ROOT}" == "${HOME}/"* ]] || die "repo must be under ${HOME}: ${REPO_ROOT}"

repo_rel="${REPO_ROOT#"${HOME}/"}"
paths=("${repo_rel}")
[[ "${include_builds}" == "1" && -d "${HOME}/builds" ]] && paths+=("builds")
[[ "${include_charms_src}" == "1" && -d "${HOME}/sunbeam-charms-src" ]] && paths+=("sunbeam-charms-src")
[[ "${include_gitconfig}" == "1" && -f "${HOME}/.gitconfig" ]] && paths+=(".gitconfig")

excludes=(
    "--exclude=${repo_rel}/.charm-build"
    "--exclude=${repo_rel}/.snap-build"
    "--exclude=${repo_rel}/.rock-build"
)
if [[ "${include_artifacts}" == "0" ]]; then
    excludes+=("--exclude=${repo_rel}/artifacts")
fi

if [[ -e "${OUTPUT}" && "${force}" == "0" ]]; then
    die "output exists: ${OUTPUT} (use --force to overwrite)"
fi

tmp="${OUTPUT}.tmp"
cmd=(tar --zstd "${excludes[@]}" -cf "${tmp}" -C "${HOME}" "${paths[@]}")

if [[ "${dry_run}" == "1" ]]; then
    printf '%q ' "${cmd[@]}"
    printf '\n'
    exit 0
fi

mkdir -p "$(dirname "${OUTPUT}")"
"${cmd[@]}"
mv "${tmp}" "${OUTPUT}"
sha256sum "${OUTPUT}" > "${OUTPUT}.sha256"

echo "created ${OUTPUT}"
echo "created ${OUTPUT}.sha256"
echo
echo "Copy to the workstation:"
echo "  scp ${OUTPUT} ${OUTPUT}.sha256 <user>@<workstation>:"
