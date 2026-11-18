#!/usr/bin/env bash
# Unpack the opendev mirror archive and configure Git URL rewrites.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARCHIVE=""
DEST="${MIRROR_DEST:-${REPO_ROOT}/artifacts/local-mirrors}"
CONFIGURE_GIT=1

log() {
    printf '[mirror-unpack] %s\n' "$*" >&2
}

fatal() {
    log "FATAL: $*"
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: tools/unpack_local_mirrors.sh <archive> [options]

Extract a local-mirror archive and configure Git insteadOf rewrites for the
current user and root. Run this on the LPAR after copying the archive.

Options:
  --dest DIR          extraction directory (default artifacts/local-mirrors)
  --no-git-config     extract only; do not modify Git configuration
  --help              show this help

The archive must contain:
  mirrors/<name>.git/
  manifest.tsv
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --dest)
            [[ $# -ge 2 ]] || fatal "--dest needs a path"
            DEST="$2"
            shift 2
            ;;
        --no-git-config)
            CONFIGURE_GIT=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            fatal "unknown option: $1 (try --help)"
            ;;
        *)
            [[ -z "${ARCHIVE}" ]] || fatal "only one archive may be specified"
            ARCHIVE="$1"
            shift
            ;;
    esac
done

[[ -n "${ARCHIVE}" ]] || { usage; exit 2; }
[[ -r "${ARCHIVE}" ]] || fatal "archive is not readable: ${ARCHIVE}"
command -v tar >/dev/null 2>&1 || fatal "tar is required"
command -v zstd >/dev/null 2>&1 || fatal "zstd is required"

mkdir -p "${DEST}"
tar --zstd -xf "${ARCHIVE}" -C "${DEST}"
manifest="${DEST}/manifest.tsv"
[[ -r "${manifest}" ]] || fatal "missing ${manifest}"

configure_git() {
    local mirror="$1" url="$2"
    local base="${url%.git}"

    git config --global --add url."${mirror}".insteadOf "${base}"
    git config --global --add url."${mirror}".insteadOf "${base}.git"

    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo git config --global --add url."${mirror}".insteadOf "${base}"
        sudo git config --global --add url."${mirror}".insteadOf "${base}.git"
    else
        log "WARN: passwordless sudo unavailable; root Git config not updated"
    fi
}

while IFS=$'\t' read -r name url head; do
    [[ "${name}" == "name" ]] && continue
    [[ -n "${name}" && -n "${url}" ]] || continue

    mirror="${DEST}/mirrors/${name}.git"
    [[ -d "${mirror}" ]] || fatal "missing mirror: ${mirror}"
    if [[ -n "${head}" ]] && ! git -C "${mirror}" cat-file -e "${head}^{commit}" 2>/dev/null; then
        log "WARN: ${name}: manifest commit ${head} is missing from the mirror"
    fi

    if (( CONFIGURE_GIT )); then
        configure_git "${mirror}" "${url}"
        log "configured ${url} -> ${mirror}"
    fi
done < "${manifest}"

# Keep the historical path used by the runbook and local build notes.
if [[ -d "${DEST}/mirrors/sunbeam-charms.git" && ! -e "${HOME}/sunbeam-charms-src" ]]; then
    ln -s "${DEST}/mirrors/sunbeam-charms.git" "${HOME}/sunbeam-charms-src"
    log "linked ${HOME}/sunbeam-charms-src"
fi

log "extracted ${ARCHIVE} into ${DEST}"
