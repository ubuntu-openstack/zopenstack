#!/usr/bin/env bash
# Validate host/tooling assumptions and parse the live Charmhub bundles.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ARCH="$(target_arch)"
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

log_step "workflow preflight (${ARCH})"

if [[ "${ARCH}" != "${HOST_ARCH}" ]]; then
    log "FATAL: TARGET_ARCH=${ARCH} does not match host architecture ${HOST_ARCH}"
    exit 1
fi

if [[ "${ARCH}" != "s390x" ]]; then
    log "FATAL: unsupported target arch ${ARCH}; this workflow is s390x-only"
    exit 1
fi

if [[ "${CHARM_SOURCE:-charmhub}" == "hybrid" ]]; then
    hybrid_charms=(
        rabbitmq-k8s_s390x.charm
        microceph_s390x.charm
        cinder-volume-ceph_s390x.charm
    )
    for filename in "${hybrid_charms[@]}"; do
        charm="${REPO_ROOT}/charms/${filename}"
        if [[ ! -s "${charm}" ]]; then
            log "FATAL: hybrid mode requires ${charm}"
            exit 1
        fi
        python3 - "${charm}" <<'PY'
import sys
import zipfile
import yaml

path = sys.argv[1]
with zipfile.ZipFile(path) as charm:
    manifest = yaml.safe_load(charm.read("manifest.yaml"))
bases = manifest.get("bases", [])
valid = any(
    base.get("name") == "ubuntu"
    and base.get("channel") == "24.04"
    and "s390x" in base.get("architectures", [])
    for base in bases
)
if not valid:
    raise SystemExit(f"{path}: expected an Ubuntu 24.04/s390x charm")
print(f"{path}: Ubuntu 24.04/s390x OK")
PY
    done
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${CHARM_SOURCE:-charmhub}" == "charmhub" \
          && "${VERSION_ID:-}" != "24.04" \
          && "${ALLOW_UNSUPPORTED_HOST_BASE:-0}" != "1" ]]; then
        log "FATAL: the published 2026.1 machine-plane charms currently require Ubuntu 24.04; host is ${VERSION_ID:-unknown}"
        log "Set ALLOW_UNSUPPORTED_HOST_BASE=1 only for control-plane/tooling diagnostics that will not deploy phase 03b."
        exit 1
    fi
fi

if ! sudo -n true 2>/dev/null; then
    log "FATAL: passwordless sudo is required"
    exit 1
fi

required_commands=(
    curl git jq python3 skopeo snap ssh ssh-keygen tar tox zstd
)
if ! require_cmd "${required_commands[@]}"; then
    exit 1
fi

python3 - "${REPO_ROOT}/manifests/control-plane-k8s-s390x.yaml" \
    "${REPO_ROOT}/manifests/machine-lpar-s390x.yaml" <<'PY'
import pathlib
import sys
import yaml

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    docs = list(yaml.safe_load_all(path.read_text()))
    if not docs or not isinstance(docs[0], dict):
        raise SystemExit(f"{path}: missing bundle document")
    apps = docs[0].get("applications")
    if not isinstance(apps, dict) or not apps:
        raise SystemExit(f"{path}: missing applications")
    for index, doc in enumerate(docs[1:], start=2):
        if doc is not None and not isinstance(doc, dict):
            raise SystemExit(f"{path}: document {index} is not a mapping")
    print(f"{path}: YAML OK ({len(apps)} applications, {len(docs)} documents)")
PY

if [[ ! -e /dev/kvm ]]; then
    log "WARN: /dev/kvm is absent; deployment checks can run, but guest and Tempest compute tests cannot pass"
fi

log_step "preflight complete"
