#!/usr/bin/env bash
# Refresh the vendored snapshot of canonical/pe-ibm-microk8s-validation files
# under vendor/pe-ibm/. Run manually when you want to pick up upstream changes.
# Not invoked by run.sh -- deliberately explicit so vendored content only moves
# when a human decides to.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/canonical/pe-ibm-microk8s-validation.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-c-k8s-and-calico-experimental}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/pe-ibm"

if ! command -v git >/dev/null 2>&1; then
    echo "FATAL: git is required" >&2
    exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

echo ">>> cloning ${UPSTREAM_REPO} @ ${UPSTREAM_BRANCH}"
git clone --depth 1 --branch "${UPSTREAM_BRANCH}" "${UPSTREAM_REPO}" "${workdir}/src"

commit=$(git -C "${workdir}/src" rev-parse HEAD)
echo ">>> upstream commit: ${commit}"

# Files we vendor. Upstream is a flat layout at the repo root.
# Mapping is: <vendored-name>=<upstream-path>.
declare -A files=(
    [calico.yaml]="calico.yaml"
    [k8s-bootstrap.yaml]="k8s-bootstrap.yaml"
    [15-build-cluster-calico.sh]="15-build-cluster-calico.sh"
    [20-enable-dns.sh]="20-enable-dns.sh"
    [40-test-basic-workloads.sh]="40-test-basic-workloads.sh"
    [minimal-nginx-v2-no-storage.yaml]="minimal-nginx-v2-no-storage.yaml"
    [static-nginx-three-node-lb.yaml]="static-nginx-three-node-lb.yaml"
)

missing=()
for dest in "${!files[@]}"; do
    src_rel="${files[${dest}]}"
    src_abs="${workdir}/src/${src_rel}"
    if [[ ! -e "${src_abs}" ]]; then
        # Try a wider search; the branch is experimental and paths shift.
        found=$(find "${workdir}/src" -name "$(basename "${src_rel}")" -type f -print -quit 2>/dev/null || true)
        if [[ -n "${found}" ]]; then
            echo "    note: ${src_rel} not at expected path; using ${found#${workdir}/src/}"
            src_abs="${found}"
        else
            missing+=("${src_rel} -> ${dest}")
            continue
        fi
    fi
    cp "${src_abs}" "${VENDOR_DIR}/${dest}"
    echo "    vendored: ${dest}"
done

echo "${commit}" > "${VENDOR_DIR}/COMMIT"

if (( ${#missing[@]} > 0 )); then
    echo
    echo "WARN: could not locate the following upstream files:" >&2
    for m in "${missing[@]}"; do echo "  - ${m}" >&2; done
    echo "Edit the 'files' map in this script if the upstream layout has changed." >&2
fi

echo
echo ">>> done. Review with:"
echo "    git -C $(dirname "${REPO_ROOT}")/$(basename "${REPO_ROOT}") diff vendor/pe-ibm/"
