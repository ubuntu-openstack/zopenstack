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

BASE_OS="${BASE_OS:-}"
release="$(openstack_release)"
release_base=""
case "${OPENSTACK_SERIES}" in
    hibiscus) release_base="ubuntu@26.04" ;;
    gazpacho) release_base="ubuntu@24.04" ;;
esac
effective_machine_base="${MACHINE_BASE:-${BASE_OS:-${release_base:-ubuntu@24.04}}}"
machine_base="${effective_machine_base}"
machine_base_channel="${machine_base#ubuntu@}"

check_local_charm_base() {
    local charm="$1" expected_base="$2"
    python3 - "${charm}" "${expected_base}" <<'PY'
import sys
import zipfile
import yaml

path = sys.argv[1]
expected_base = sys.argv[2]
with zipfile.ZipFile(path) as charm:
    manifest = yaml.safe_load(charm.read("manifest.yaml"))
bases = manifest.get("bases", [])
valid = any(
    base.get("name") == "ubuntu"
    and base.get("channel") == expected_base
    and "s390x" in base.get("architectures", [])
    for base in bases
)
if not valid:
    raise SystemExit(f"{path}: expected an Ubuntu {expected_base}/s390x charm")
print(f"{path}: Ubuntu {expected_base}/s390x OK")
PY
}

if [[ "${CHARM_SOURCE:-charmhub}" == "hybrid" ]]; then
    # RabbitMQ and the token distributor have no s390x Charmhub revision, so
    # hybrid mode must supply them locally. Other charms are used locally when
    # staged and otherwise fall back to their published s390x revisions.
    required_hybrid_charms=(
        rabbitmq-k8s_s390x.charm
        microcluster-token-distributor_s390x.charm
    )
    for filename in "${required_hybrid_charms[@]}"; do
        charm="${REPO_ROOT}/charms/${filename}"
        expected_base="24.04"
        [[ "${filename}" == "microcluster-token-distributor_s390x.charm" ]] \
            && expected_base="${machine_base_channel}"
        if [[ ! -s "${charm}" ]]; then
            log "FATAL: hybrid mode requires ${charm}"
            exit 1
        fi
        check_local_charm_base "${charm}" "${expected_base}"
    done
    # Validate optional local charms when staged; missing files fall back to
    # Charmhub in the renderer.
    for filename in microceph_s390x.charm cinder-volume-ceph_s390x.charm \
            sunbeam-machine_s390x.charm openstack-hypervisor_s390x.charm \
            cinder-volume_s390x.charm microovn_s390x.charm \
            sunbeam-ovn-proxy_s390x.charm; do
        charm="${REPO_ROOT}/charms/${filename}"
        [[ -s "${charm}" ]] || continue
        check_local_charm_base "${charm}" "${machine_base_channel}"
    done

    rabbitmq_image="${RABBITMQ_IMAGE:-}"
    if [[ -z "${rabbitmq_image}" ]]; then
        log "FATAL: hybrid mode requires RABBITMQ_IMAGE paired with the RabbitMQ charm"
        exit 1
    fi
    if [[ "$("${SCRIPT_DIR}/check_oci_arch.sh" "${rabbitmq_image}" "${ARCH}" 2>/dev/null || true)" == "no" ]]; then
        log "FATAL: ${rabbitmq_image} has no ${ARCH} manifest; set RABBITMQ_IMAGE to an s390x RabbitMQ image"
        exit 1
    fi
fi

if [[ "${CHARM_SOURCE:-charmhub}" == "local" ]]; then
    token_distributor_charm="${REPO_ROOT}/charms/microcluster-token-distributor_s390x.charm"
    if [[ ! -s "${token_distributor_charm}" ]]; then
        log "FATAL: local mode requires ${token_distributor_charm}"
        log "microovn needs the token distributor, and charmhub has no s390x revision for it."
        exit 1
    fi
    check_local_charm_base "${token_distributor_charm}" "${machine_base_channel}"
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    legacy_machine_profile=0
    case "${OPENSTACK_SERIES}" in
        gazpacho) legacy_machine_profile=1 ;;
    esac
    if [[ "${CHARM_SOURCE:-charmhub}" == "charmhub" \
          && "${legacy_machine_profile}" == "1" \
          && "${VERSION_ID:-}" != "24.04" \
          && "${effective_machine_base}" != "ubuntu@26.04" \
          && "${ALLOW_UNSUPPORTED_HOST_BASE:-0}" != "1" ]]; then
        log "FATAL: the published 2026.1 machine-plane charms currently require Ubuntu 24.04; host is ${VERSION_ID:-unknown}"
        log "For Resolute, set OPENSTACK_SERIES=hibiscus (or MACHINE_BASE=ubuntu@26.04 for the legacy profile); set ALLOW_UNSUPPORTED_HOST_BASE=1 only for control-plane/tooling diagnostics that will not deploy phase 03b."
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

cp_bundle="${REPO_ROOT}/manifests/control-plane-k8s-s390x.yaml"
m_bundle="${REPO_ROOT}/manifests/machine-lpar-s390x.yaml"

if [[ -n "${OPENSTACK_SERIES}" || -n "${BASE_OS}" || -n "${MACHINE_BASE:-}" \
      || -n "${MACHINE_CHANNEL:-}" || -n "${MICROCEPH_CHARM_CHANNEL:-}" \
      || -n "${MICROOVN_CHANNEL:-}" || -n "${OVN_PROXY_CHANNEL:-}" \
      || -n "${TOKEN_DISTRIBUTOR_CHANNEL:-}" ]]; then
    cp_render="${ARTIFACT_DIR}/preflight-control-plane.yaml"
    cp_args=(
        --source "${cp_bundle}"
        --output "${cp_render}"
        --kind control-plane
        --release "${release}"
    )
    [[ -n "${BASE_OS}" ]] && cp_args+=(--base "${BASE_OS}")
    run_python_tool "${SCRIPT_DIR}/render_release_bundles.py" "${cp_args[@]}"
    cp_bundle="${cp_render}"

    m_render="${ARTIFACT_DIR}/preflight-machine.yaml"
    m_args=(
        --source "${m_bundle}"
        --output "${m_render}"
        --kind machine
        --release "${release}"
        --base "${effective_machine_base}"
    )
    [[ -n "${MACHINE_CHANNEL:-}" ]] && m_args+=(--machine-channel "${MACHINE_CHANNEL}")
    [[ -n "${MICROCEPH_CHARM_CHANNEL:-}" ]] && m_args+=(--microceph-channel "${MICROCEPH_CHARM_CHANNEL}")
    [[ -n "${MICROOVN_CHANNEL:-}" ]] && m_args+=(--microovn-channel "${MICROOVN_CHANNEL}")
    [[ -n "${OVN_PROXY_CHANNEL:-}" ]] && m_args+=(--ovn-proxy-channel "${OVN_PROXY_CHANNEL}")
    [[ -n "${TOKEN_DISTRIBUTOR_CHANNEL:-}" ]] && m_args+=(--token-distributor-channel "${TOKEN_DISTRIBUTOR_CHANNEL}")
    run_python_tool "${SCRIPT_DIR}/render_release_bundles.py" "${m_args[@]}"
    m_bundle="${m_render}"
fi

python3 - "${cp_bundle}" "${m_bundle}" <<'PY'
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

# Charmhub availability sweep. `juju info` is a store query and does not need a
# controller. This is warning-only: CHARM_SOURCE=charmhub is the diagnostic
# mode and must still reach phases 03/05 so the failure is recorded.
if command -v juju >/dev/null 2>&1; then
    skip_apps=()
    if [[ "${CHARM_SOURCE:-charmhub}" == "hybrid" ]]; then
        skip_apps=(rabbitmq tls-operator traefik microceph cinder-microceph \
            microcluster-token-distributor)
        for app in sunbeam-machine hypervisor cinder-volume microovn sunbeam-ovn-proxy; do
            case "${app}" in
                sunbeam-machine) charm_file="sunbeam-machine_s390x.charm" ;;
                hypervisor) charm_file="openstack-hypervisor_s390x.charm" ;;
                cinder-volume) charm_file="cinder-volume_s390x.charm" ;;
                microovn) charm_file="microovn_s390x.charm" ;;
                sunbeam-ovn-proxy) charm_file="sunbeam-ovn-proxy_s390x.charm" ;;
            esac
            [[ -s "${REPO_ROOT}/charms/${charm_file}" ]] && skip_apps+=("${app}")
        done
    elif [[ "${CHARM_SOURCE:-charmhub}" == "local" \
            && -s "${REPO_ROOT}/charms/microcluster-token-distributor_s390x.charm" ]]; then
        skip_apps=(microcluster-token-distributor)
    fi
    charm_rows=$(python3 - "${cp_bundle}" "${m_bundle}" <<'PY'
import sys
import yaml

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as stream:
        docs = list(yaml.safe_load_all(stream))
    applications = (docs[0].get("applications") or {}) if docs else {}
    for app, spec in applications.items():
        if not isinstance(spec, dict):
            continue
        charm = spec.get("charm", "")
        if not isinstance(charm, str) or charm.startswith(("./", "/")):
            continue
        channel = spec.get("channel", "")
        if not channel:
            continue
        print(f"{app}\t{charm}\t{channel}\t{spec.get('base', '')}")
PY
)
    charm_missing=0
    while IFS=$'\t' read -r app charm channel base; do
        [[ -z "${app}" ]] && continue
        skip=0
        for skipped in "${skip_apps[@]}"; do
            [[ "${app}" == "${skipped}" ]] && skip=1
        done
        (( skip )) && continue
        result=$("${SCRIPT_DIR}/check_charm_arch.sh" "${charm}" "${channel}" "${base}" "${ARCH}" 2>/dev/null || true)
        if [[ "${result}" == "no" ]]; then
            charm_missing=$((charm_missing + 1))
        fi
    done <<<"${charm_rows}"
    if (( charm_missing > 0 )); then
        log "WARN: ${charm_missing} Charmhub application(s) have no ${ARCH} revision for the requested channel/base; see ${ARCH_REPORT}"
        log "WARN: deploy will fail unless a local charm or an s390x-published revision is supplied"
    fi
fi

if [[ ! -e /dev/kvm ]]; then
    log "WARN: /dev/kvm is absent; deployment checks can run, but guest and Tempest compute tests cannot pass"
fi

log_step "preflight complete"
