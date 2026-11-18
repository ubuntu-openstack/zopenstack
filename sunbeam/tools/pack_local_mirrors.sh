#!/usr/bin/env bash
# Pack the opendev repositories needed by the charm build into one archive.
# Run this on a host that can reach opendev.org.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_REPOS=(
    "sunbeam-charms=https://opendev.org/openstack/sunbeam-charms"
    "charm-ops-interface-ceph-client=https://opendev.org/openstack/charm-ops-interface-ceph-client"
    "charm-ops-interface-tls-certificates=https://opendev.org/openstack/charm-ops-interface-tls-certificates"
)

OUTPUT="${MIRROR_BUNDLE:-${REPO_ROOT}/artifacts/local-mirrors-$(date -u +%Y%m%dT%H%M%SZ).tar.zst}"
USE_DEFAULTS=1
REPOS=()

log() {
    printf '[mirror-pack] %s\n' "$*" >&2
}

fatal() {
    log "FATAL: $*"
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: tools/pack_local_mirrors.sh [options]

Create a compressed archive of bare Git mirrors for the opendev repositories
used by the local charm build. Run this on a host with opendev.org access.

Options:
  --output FILE          archive path (default artifacts/local-mirrors-<UTC>.tar.zst)
  --repo NAME=URL        add a repository (repeatable)
  --no-default-repos     do not include the built-in repository list
  --help                 show this help

Default repositories:
  sunbeam-charms
  charm-ops-interface-ceph-client
  charm-ops-interface-tls-certificates

The archive contains:
  mirrors/<name>.git/    bare Git repositories
  manifest.tsv           name, URL, and HEAD commit for each mirror
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || fatal "--output needs a path"
            OUTPUT="$2"
            shift 2
            ;;
        --repo)
            [[ $# -ge 2 && "$2" == *=* ]] || fatal "--repo needs NAME=URL"
            REPOS+=("$2")
            shift 2
            ;;
        --no-default-repos)
            USE_DEFAULTS=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fatal "unknown argument: $1 (try --help)"
            ;;
    esac
done

if (( USE_DEFAULTS )); then
    REPOS=("${DEFAULT_REPOS[@]}" "${REPOS[@]}")
fi
(( ${#REPOS[@]} > 0 )) || fatal "no repositories selected"

command -v git >/dev/null 2>&1 || fatal "git is required"
command -v tar >/dev/null 2>&1 || fatal "tar is required"
command -v zstd >/dev/null 2>&1 || fatal "zstd is required"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/mirrors" "$(dirname "${OUTPUT}")"
manifest="${work}/manifest.tsv"
printf 'name\turl\theader\n' > "${manifest}"

for spec in "${REPOS[@]}"; do
    name="${spec%%=*}"
    url="${spec#*=}"
    [[ -n "${name}" && -n "${url}" ]] || fatal "invalid repository spec: ${spec}"
    [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "invalid repository name: ${name}"

    dest="${work}/mirrors/${name}.git"
    log "mirroring ${url}"
    if [[ -d "${dest}" ]]; then
        git -C "${dest}" remote set-url origin "${url}"
        git -C "${dest}" fetch --prune --tags
    else
        git clone --mirror "${url}" "${dest}"
    fi

    head="$(git -C "${dest}" rev-parse HEAD 2>/dev/null || true)"
    [[ -n "${head}" ]] || fatal "${name}: mirror has no HEAD"
    printf '%s\t%s\t%s\n' "${name}" "${url}" "${head}" >> "${manifest}"
done

tar --zstd -cf "${OUTPUT}" -C "${work}" mirrors manifest.tsv
sha256sum "${OUTPUT}" > "${OUTPUT}.sha256"

log "wrote ${OUTPUT}"
log "wrote ${OUTPUT}.sha256"
