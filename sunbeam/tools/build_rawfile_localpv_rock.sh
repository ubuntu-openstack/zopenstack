#!/usr/bin/env bash
# Build the rawfile-localpv rock natively on an s390x host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${1:-${HOME}/builds/rawfile-localpv-rocks-s390x}"
UPSTREAM_URL="${RAWFILE_LOCALPV_REPO:-https://github.com/canonical/rawfile-localpv-rocks.git}"
PATCH_FILE="${REPO_ROOT}/patches/rawfile-localpv-s390x.patch"

if [[ "$(dpkg --print-architecture)" != "s390x" ]]; then
    echo "FATAL: this helper must run natively on an s390x host" >&2
    exit 1
fi

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone "${UPSTREAM_URL}" "${SOURCE_DIR}"
fi

if git -C "${SOURCE_DIR}" apply --check "${PATCH_FILE}" 2>/dev/null; then
    git -C "${SOURCE_DIR}" apply "${PATCH_FILE}"
elif git -C "${SOURCE_DIR}" apply --reverse --check "${PATCH_FILE}" 2>/dev/null; then
    echo "s390x patch already applied"
else
    echo "FATAL: s390x patch no longer applies to ${SOURCE_DIR}; inspect upstream changes" >&2
    exit 1
fi

cd "${SOURCE_DIR}"
sudo --preserve-env=HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy \
    rockcraft pack --use-lxd --platform s390x

rock="$(find "${SOURCE_DIR}" -maxdepth 1 -type f -name '*.rock' -print -quit)"
echo "Built rock:"
echo "${rock}"

ctr=/snap/k8s/current/bin/ctr
socket=/run/containerd/containerd.sock
if [[ -x "${ctr}" && -S "${socket}" ]]; then
    echo "Importing rock into Canonical K8s containerd"
    sudo "${ctr}" --address "${socket}" --namespace k8s.io images import \
        --base-name docker.io/library/rawfile-localpv "${rock}"
    sudo "${ctr}" --address "${socket}" --namespace k8s.io images tag --force \
        docker.io/library/rawfile-localpv:0.8.3 \
        docker.io/library/rawfile-localpv:0.8.3-s390x
    echo "Imported as docker.io/library/rawfile-localpv:0.8.3-s390x"
fi
