#!/usr/bin/env bash
# Stage a phase-99 local-artifacts archive/directory on a fresh LPAR.
#
# Usage:
#   tools/install_local_artifacts.sh <local-artifacts-dir-or-tar.zst> [options]
#
# Options:
#   --stage-only     Copy charms/snaps/rocks into the repo (default)
#   --install-snaps  Also install staged snaps with snap install --dangerous --devmode
#   --import-rocks   Also import staged rocks into Canonical Kubernetes containerd
#   --all            --install-snaps + --import-rocks
#   --help
#
# The default is intentionally stage-only: a fresh LPAR may not have Juju,
# snapd, or Canonical Kubernetes ready yet. Phase 03/05 consume the staged
# files from ./rocks, ./snaps, and ./charms.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

src=""
stage_only=1
install_snaps=0
import_rocks=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-only) stage_only=1; install_snaps=0; import_rocks=0; shift ;;
        --install-snaps) install_snaps=1; stage_only=0; shift ;;
        --import-rocks) import_rocks=1; stage_only=0; shift ;;
        --all) install_snaps=1; import_rocks=1; stage_only=0; shift ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            [[ -z "${src}" ]] || { echo "only one source is supported" >&2; exit 2; }
            src="$1"; shift ;;
    esac
done

[[ -n "${src}" ]] || { usage >&2; exit 2; }
[[ -e "${src}" ]] || { echo "source not found: ${src}" >&2; exit 1; }

tmp_dir=""
cleanup() {
    if [[ -n "${tmp_dir}" ]]; then
        rm -rf "${tmp_dir}"
    fi
}
trap cleanup EXIT

if [[ -d "${src}" ]]; then
    artifacts_dir="$(cd "${src}" && pwd)"
elif [[ -f "${src}" ]]; then
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-artifacts.XXXXXX")"
    tar --zstd -xf "${src}" -C "${tmp_dir}"
    artifacts_dir="${tmp_dir}/local-artifacts"
    [[ -d "${artifacts_dir}" ]] || {
        echo "archive does not contain local-artifacts/: ${src}" >&2
        exit 1
    }
else
    echo "source is neither a directory nor a file: ${src}" >&2
    exit 1
fi

if [[ -f "${artifacts_dir}/SHA256SUMS" ]]; then
    (cd "${artifacts_dir}" && sha256sum -c SHA256SUMS)
else
    echo "WARN: ${artifacts_dir}/SHA256SUMS missing; skipping checksum verification" >&2
fi

mkdir -p "${REPO_ROOT}/charms" "${REPO_ROOT}/snaps" "${REPO_ROOT}/rocks"

staged=0
for kind in charms snaps rocks; do
    [[ -d "${artifacts_dir}/${kind}" ]] || continue
    while IFS= read -r -d '' f; do
        cp -a "${f}" "${REPO_ROOT}/${kind}/"
        staged=$((staged + 1))
    done < <(find "${artifacts_dir}/${kind}" -maxdepth 1 -type f -print0)
done

echo "staged ${staged} file(s) into ${REPO_ROOT}/{charms,snaps,rocks}"

if (( install_snaps )); then
    shopt -s nullglob
    snaps=("${artifacts_dir}"/snaps/*.snap)
    if (( ${#snaps[@]} == 0 )); then
        echo "no snaps to install"
    else
        for snap_file in "${snaps[@]}"; do
            echo "installing snap: ${snap_file}"
            sudo snap install --dangerous --devmode "${snap_file}"
        done
    fi
fi

if (( import_rocks )); then
    shopt -s nullglob
    rocks=("${artifacts_dir}"/rocks/*.rock)
    if (( ${#rocks[@]} == 0 )); then
        echo "no rocks to import"
    else
        ctr_bin="${CTR_BIN:-/snap/k8s/current/bin/ctr}"
        sock="${CONTAINERD_SOCK:-/run/containerd/containerd.sock}"
        [[ -x "${ctr_bin}" && -S "${sock}" ]] || {
            echo "containerd not available at ${sock}; cannot import rocks" >&2
            exit 1
        }
        for rock in "${rocks[@]}"; do
            echo "importing rock: ${rock}"
            sudo "${ctr_bin}" --address "${sock}" --namespace k8s.io images import "${rock}"
        done
    fi
fi

cat <<EOF

Next steps:
  CHARM_SOURCE=local BUILD_LOCAL_SNAPS=0 \\
  HYPERVISOR_SNAP_PATH=${REPO_ROOT}/snaps/openstack-hypervisor_s390x.snap \\
  CINDER_VOLUME_SNAP_PATH=${REPO_ROOT}/snaps/cinder-volume_s390x.snap \\
  ./run.sh all

  # If the snap filenames differ, set the two *_SNAP_PATH variables to the
  # staged files. Phase 03 discovers rocks/rawfile-localpv*.rock automatically.
EOF
