#!/usr/bin/env bash
# Build the s390x openstack-hypervisor snap used by the machine plane:
#
#   openstack-hypervisor_s390x.snap
#
# cinder-volume is consumed from its published snap; its old local patch is
# already upstream. The source branch defaults to stable/<release from
# OPENSTACK_SERIES>. If that branch does not exist yet, feat/<release> and then
# main are tried on the upstream and fork repositories. The hypervisor patches
# are applied after the fresh clone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${SCRIPT_DIR}/proxy_env.sh" ]]; then
    # Pass an empty argument so this script's own CLI args are not interpreted
    # as a proxy manifest path.
    source "${SCRIPT_DIR}/proxy_env.sh" ""
fi

# shellcheck source=release_env.sh
source "${SCRIPT_DIR}/release_env.sh"
release="$(openstack_release)"
SNAP_BRANCH="${SNAP_BRANCH:-stable/${release}}"
SNAP_HYPERVISOR_BRANCH="${SNAP_HYPERVISOR_BRANCH:-${SNAP_BRANCH}}"
SNAP_HYPERVISOR_REPO="${SNAP_HYPERVISOR_REPO:-https://github.com/canonical/snap-openstack-hypervisor.git}"
SNAP_HYPERVISOR_FALLBACK_REPO="${SNAP_HYPERVISOR_FALLBACK_REPO:-https://github.com/himax16/snap-openstack-hypervisor.git}"
SNAP_CINDER_REPO="${SNAP_CINDER_REPO:-https://github.com/canonical/snap-cinder-volume.git}"
SNAP_CINDER_FALLBACK_REPO="${SNAP_CINDER_FALLBACK_REPO:-}"
SNAP_CINDER_BRANCH="${SNAP_CINDER_BRANCH:-main}"
SNAP_BUILD_DIR="${SNAP_BUILD_DIR:-${REPO_ROOT}/.snap-build}"
SNAP_OUT_DIR="${SNAP_OUT_DIR:-${REPO_ROOT}/snaps}"
SNAP_PATCH_ROOT="${SNAP_PATCH_ROOT:-${REPO_ROOT}/patches/snaps}"
CHECK_ONLY=0

# UCA is reachable directly but is denied by the Squid allowlist.
for host in ubuntu-cloud.archive.canonical.com; do
    case ",${NO_PROXY:-}," in
        *",${host},"*) ;;
        *) NO_PROXY="${NO_PROXY:+${NO_PROXY},}${host}" ;;
    esac
    case ",${no_proxy:-}," in
        *",${host},"*) ;;
        *) no_proxy="${no_proxy:+${no_proxy},}${host}" ;;
    esac
done
export NO_PROXY no_proxy

log() { printf '[snap-build] %s\n' "$*" >&2; }
fatal() { log "FATAL: $*"; exit 1; }

usage() {
    cat >&2 <<'EOF'
Usage: tools/build_snaps.sh [--check] [--help]

Builds every snap that has a patches/snaps/<snap>/ directory. Each snap is
cloned from its configured source, all *.patch files in its patch directory are
applied, and the resulting snap is staged in ./snaps/ as <snap>_s390x.snap.

Currently discovered: openstack-hypervisor, cinder-volume.

--check clones the sources and verifies patch application without building.

Environment overrides:
  OPENSTACK_SERIES                (hibiscus by default; release used to select stable/<release> for the hypervisor)
  SNAP_BRANCH                     hypervisor branch to try first (default stable/<release>)
  SNAP_HYPERVISOR_BRANCH          explicit hypervisor branch
  SNAP_CINDER_BRANCH              cinder-volume branch (default main)
  SNAP_HYPERVISOR_REPO            primary hypervisor repository
  SNAP_HYPERVISOR_FALLBACK_REPO   fallback hypervisor repository
  SNAP_CINDER_REPO                cinder-volume repository
  SNAP_CINDER_FALLBACK_REPO       fallback cinder-volume repository
  SNAP_PATCH_ROOT                 patch root (default patches/snaps)
  SNAP_BUILD_DIR, SNAP_OUT_DIR
  PROXY_ENV_FILE, PROXY_URL, NO_PROXY_DEFAULT

Requirements on the s390x LPAR:
  sudo snap install snapcraft --classic
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fatal "unknown argument: $1 (try --help)" ;;
    esac
done

ref_exists() {
    local repo="$1" ref="$2"
    git ls-remote --exit-code --heads "${repo}" "refs/heads/${ref}" >/dev/null 2>&1
}

resolve_source() {
    local primary="$1" fallback="$2" first_ref="$3" repo ref
    for ref in "${first_ref}" "feat/${release}"; do
        for repo in "${primary}" "${fallback}"; do
            if [[ -n "${repo}" ]] && ref_exists "${repo}" "${ref}"; then
                printf '%s %s\n' "${repo}" "${ref}"
                return 0
            fi
        done
    done
    for repo in "${primary}" "${fallback}"; do
        if [[ -n "${repo}" ]] && ref_exists "${repo}" main; then
            printf '%s %s\n' "${repo}" main
            return 0
        fi
    done
    return 1
}

clone_source() {
    local repo="$1" ref="$2" dest="$3"
    log "cloning ${repo} (${ref})"
    # A previous destructive build may have left root-owned parts/prime trees.
    if [[ -e "${dest}" ]]; then
        if [[ -O "${dest}" && -w "${dest}" ]]; then
            rm -rf "${dest}"
        else
            sudo rm -rf "${dest}"
        fi
    fi
    git clone --depth 1 --branch "${ref}" "${repo}" "${dest}"
}

apply_patch() {
    local src="$1" patch="$2"
    [[ -r "${patch}" ]] || fatal "patch missing: ${patch}"
    log "applying $(basename "${patch}")"
    git -C "${src}" apply "${patch}"
}

merge_ppa() {
    local src="$1" patch="$2"
    local yaml="${src}/snap/snapcraft.yaml"
    [[ -r "${patch}" ]] || fatal "patch missing: ${patch}"
    [[ -r "${yaml}" ]] || fatal "missing ${yaml}"
    if grep -q 'himax16/s390x-nova-acpi' "${yaml}"; then
        if ! grep -A2 'himax16/s390x-nova-acpi' "${yaml}" | grep -q 'priority:'; then
            python3 - "${yaml}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
for index, line in enumerate(lines):
    if "himax16/s390x-nova-acpi" in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines.insert(index + 1, f"{indent}priority: 1001\n")
        break
path.write_text("".join(lines), encoding="utf-8")
PY
        fi
        log "PPA already present in ${yaml}"
        return 0
    fi
    if ! grep -q '^package-repositories:' "${yaml}"; then
        apply_patch "${src}" "${patch}"
        return 0
    fi
    python3 - "${yaml}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
start = next(i for i, line in enumerate(lines) if line.startswith("package-repositories:"))
end = start + 1
while end < len(lines) and (not lines[end].strip() or lines[end].startswith(" ")):
    end += 1
entry = [
    "  - type: apt\n",
    "    ppa: himax16/s390x-nova-acpi\n",
    "    priority: 1001\n",
]
lines[end:end] = entry
path.write_text("".join(lines), encoding="utf-8")
PY
}

snap_repo() {
    case "$1" in
        openstack-hypervisor) printf '%s\n' "${SNAP_HYPERVISOR_REPO}" ;;
        cinder-volume) printf '%s\n' "${SNAP_CINDER_REPO}" ;;
        *) return 1 ;;
    esac
}

snap_fallback_repo() {
    case "$1" in
        openstack-hypervisor) printf '%s\n' "${SNAP_HYPERVISOR_FALLBACK_REPO}" ;;
        cinder-volume) printf '%s\n' "${SNAP_CINDER_FALLBACK_REPO}" ;;
        *) return 1 ;;
    esac
}

snap_branch() {
    case "$1" in
        openstack-hypervisor) printf '%s\n' "${SNAP_HYPERVISOR_BRANCH}" ;;
        cinder-volume) printf '%s\n' "${SNAP_CINDER_BRANCH}" ;;
        *) return 1 ;;
    esac
}

snap_patch_dir() {
    printf '%s/%s\n' "${SNAP_PATCH_ROOT}" "$1"
}

apply_snap_patches() {
    local name="$1" src="$2" dir patch
    dir="$(snap_patch_dir "${name}")"
    [[ -d "${dir}" ]] || fatal "no patch directory for ${name}: ${dir}"
    while IFS= read -r patch; do
        case "$(basename "${patch}")" in
            nova-acpi-ppa.patch)
                merge_ppa "${src}" "${patch}"
                ;;
            *)
                apply_patch "${src}" "${patch}"
                ;;
        esac
    done < <(find "${dir}" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
}

build_snap() {
    local name="$1" src="$2"
    local snapcraft_bin
    snapcraft_bin="$(command -v snapcraft 2>/dev/null || true)"
    [[ -n "${snapcraft_bin}" ]] || fatal "snapcraft is required: sudo snap install snapcraft --classic"
    log "building ${name} from ${src}"
    # Destructive mode needs root to install the snapcraft build packages.
    (cd "${src}" && sudo --preserve-env=http_proxy,https_proxy,HTTP_PROXY,HTTPS_PROXY,no_proxy,NO_PROXY \
        env PATH="${PATH}" "${snapcraft_bin}" pack --destructive-mode)
    local snapfile
    snapfile="$(find "${src}" -maxdepth 1 -type f -name '*.snap' -printf '%T@ %p\n' \
        | sort -n | tail -1 | cut -d' ' -f2-)"
    [[ -n "${snapfile}" && -s "${snapfile}" ]] || fatal "snapcraft produced no .snap for ${name}"
    cp -f "${snapfile}" "${SNAP_OUT_DIR}/${name}_s390x.snap"
    log "staged ${SNAP_OUT_DIR}/${name}_s390x.snap"
    if [[ "${name}" == "openstack-hypervisor" ]]; then
        verify_staged_nova_ppa "${SNAP_OUT_DIR}/${name}_s390x.snap"
    fi
}

verify_staged_nova_ppa() {
    local snapfile="$1" changelog
    command -v unsquashfs >/dev/null 2>&1 || {
        log "WARN: unsquashfs missing; cannot verify the staged Nova package"
        return 0
    }
    changelog="$(unsquashfs -cat "${snapfile}" \
        usr/share/doc/python3-nova/changelog.Debian.gz 2>/dev/null \
        | gzip -dc 2>/dev/null | head -1 || true)"
    case "${changelog}" in
        *+s390x~ppa*)
            log "staged Nova: ${changelog}"
            ;;
        *)
            fatal "snap staged Nova without the ACPI PPA: ${changelog:-unknown}"
            ;;
    esac
}

mkdir -p "${SNAP_BUILD_DIR}" "${SNAP_OUT_DIR}"

mapfile -t snap_names < <(
    find "${SNAP_PATCH_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | LC_ALL=C sort
)
(( ${#snap_names[@]} > 0 )) || fatal "no snap patch directories under ${SNAP_PATCH_ROOT}"

for snap in "${snap_names[@]}"; do
    primary="$(snap_repo "${snap}")" || fatal "no source mapping for snap ${snap}"
    fallback="$(snap_fallback_repo "${snap}")" || fallback=""
    branch="$(snap_branch "${snap}")" || fatal "no branch mapping for snap ${snap}"
    read -r repo ref < <(resolve_source "${primary}" "${fallback}" "${branch}") || \
        fatal "could not resolve source for ${snap} (${branch})"
    log "${snap} source: ${repo} (${ref})"
    dest="${SNAP_BUILD_DIR}/${snap}"
    clone_source "${repo}" "${ref}" "${dest}"
    apply_snap_patches "${snap}" "${dest}"
    if (( CHECK_ONLY )); then
        continue
    fi
    build_snap "${snap}" "${dest}"
done

if (( CHECK_ONLY )); then
    log "patch/source check complete"
    exit 0
fi

log "built:"
find "${SNAP_OUT_DIR}" -maxdepth 1 -type f \
    -name '*_s390x.snap' \
    -printf '  %p\n' | sort
