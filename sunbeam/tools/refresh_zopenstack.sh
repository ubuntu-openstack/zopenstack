#!/usr/bin/env bash
# Refresh the vendored snapshot of selected ubuntu-openstack/zopenstack files
# under vendor/zopenstack/. Run manually when you want to pick up upstream
# changes; not invoked by run.sh.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/ubuntu-openstack/zopenstack.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/zopenstack"

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

# Files we vendor (and only these). zopenstack as a whole is charmed-OpenStack
# specific; we copy out only the pieces that are deployment-agnostic.
declare -A files=(
    [exclude-list.txt]="report/etc/exclude-list.txt"
)

missing=()
for dest in "${!files[@]}"; do
    src_rel="${files[${dest}]}"
    src_abs="${workdir}/src/${src_rel}"
    if [[ ! -e "${src_abs}" ]]; then
        missing+=("${src_rel} -> ${dest}")
        continue
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
echo ">>> done. Review with:  git diff vendor/zopenstack/"
echo "    Re-evaluate any new exclude-list entries for Sunbeam applicability."
