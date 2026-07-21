#!/usr/bin/env bash
# Phase 03b: deploy the MACHINE plane (hypervisor + cinder-volume + microceph +
# sunbeam-machine) into a second Juju model on a MANUAL cloud whose only machine
# is this LPAR, and wire it to the control plane via cross-model offers.
#
# Runs after phase 03 (control-plane bundle + its offers must already exist).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=03b_deploy_machine_plane
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

# Manual-machine provisioning downloads the Juju agent stream from the client
# shell before the machine exists. Keep that request off a proxy which rejects
# streams.canonical.com.
if [[ -n "${PROXY_URL:-}" && -n "${NO_PROXY_DEFAULT:-}" ]]; then
    export NO_PROXY="${NO_PROXY_DEFAULT}"
    export no_proxy="${NO_PROXY_DEFAULT}"
    log "using NO_PROXY=${NO_PROXY_DEFAULT} for Juju agent stream access"
fi

CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
MACHINE_MODEL="${MACHINE_MODEL:-machines}"
MANUAL_CLOUD="${MANUAL_CLOUD:-lpar-manual}"
# Charm source: 'charmhub' (default) or 'local' (our s390x .charm builds from
# ./charms, via the *-local.yaml bundle). Explicit BUNDLE=... override still wins.
CHARM_SOURCE="${CHARM_SOURCE:-charmhub}"
case "${CHARM_SOURCE}" in
    charmhub) _m_bundle="machine-lpar-s390x.yaml" ;;
    local)    _m_bundle="machine-lpar-s390x-local.yaml" ;;
    hybrid)
        python3 "${REPO_ROOT}/tools/render_hybrid_bundles.py" \
            --repo "${REPO_ROOT}" --output-dir "${ARTIFACT_DIR}"
        _m_bundle="${ARTIFACT_DIR}/machine-lpar-s390x-hybrid.yaml"
        ;;
    *) log "FATAL: CHARM_SOURCE must be 'charmhub', 'hybrid', or 'local' (got '${CHARM_SOURCE}')"; exit 2 ;;
esac
if [[ "${_m_bundle}" = /* ]]; then
    BUNDLE="${BUNDLE:-${_m_bundle}}"
else
    BUNDLE="${BUNDLE:-${REPO_ROOT}/manifests/${_m_bundle}}"
fi
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-3600}"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-${DEPLOY_TIMEOUT}}"
ARCH="$(target_arch)"
HYPERVISOR_SKIP_CEPH_SECRET_CONFIG="${HYPERVISOR_SKIP_CEPH_SECRET_CONFIG:-auto}"
HYPERVISOR_DISABLE_SPICE="${HYPERVISOR_DISABLE_SPICE:-auto}"
HYPERVISOR_SNAP_PATH="${HYPERVISOR_SNAP_PATH:-}"
HYPERVISOR_EXPECT_NOVA_ACPI_PATCH="${HYPERVISOR_EXPECT_NOVA_ACPI_PATCH:-auto}"

check_hypervisor_nova_acpi_patch() {
    [[ "${ARCH}" == "s390x" ]] || return 0
    command -v snap >/dev/null 2>&1 || return 0
    snap list openstack-hypervisor >/dev/null 2>&1 || return 0

    if [[ "${HYPERVISOR_EXPECT_NOVA_ACPI_PATCH}" == "auto" ]]; then
        # Keep this warning-only by default: phase 04b has a hard guest-boot
        # gate, while phase 03b is still useful for published-artifact gap
        # discovery.
        HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=warn
    fi

    case "${HYPERVISOR_EXPECT_NOVA_ACPI_PATCH}" in
        0|false|no) return 0 ;;
        1|true|yes|warn) ;;
        *) log "FATAL: HYPERVISOR_EXPECT_NOVA_ACPI_PATCH must be 0, 1, warn, or auto"; exit 2 ;;
    esac

    nova_changelog="/snap/openstack-hypervisor/current/usr/share/doc/python3-nova/changelog.Debian.gz"
    if [[ -r "${nova_changelog}" ]] && zgrep -q 'lp2043987' "${nova_changelog}"; then
        log "openstack-hypervisor stages Nova with LP #2043987 ACPI workaround"
        return 0
    fi

    msg="installed openstack-hypervisor snap does not appear to stage Nova from ppa:mylesjp/nova-acpi-patch (LP #2043987). s390x guest boot may fail with unsupported ACPI."
    if [[ "${HYPERVISOR_EXPECT_NOVA_ACPI_PATCH}" == "warn" ]]; then
        log "WARN: ${msg}"
    else
        log "FATAL: ${msg}"
        exit 1
    fi
}

sideload_hypervisor_snap() {
    [[ -n "${HYPERVISOR_SNAP_PATH}" ]] || return 0
    if [[ ! -r "${HYPERVISOR_SNAP_PATH}" ]]; then
        log "FATAL: HYPERVISOR_SNAP_PATH is set but not readable: ${HYPERVISOR_SNAP_PATH}"
        exit 1
    fi

    log_step "installing local openstack-hypervisor snap: ${HYPERVISOR_SNAP_PATH}"
    run_logged "snap install local openstack-hypervisor" -- \
        sudo snap install --dangerous "${HYPERVISOR_SNAP_PATH}"
    # Prevent snapd from replacing the validation snap with a store revision
    # before the charm has a chance to configure it.
    run_logged "hold openstack-hypervisor snap refreshes" -- \
        sudo snap refresh --hold openstack-hypervisor || true
    check_hypervisor_nova_acpi_patch
}

apply_s390x_hypervisor_runtime_workarounds() {
    [[ "${ARCH}" == "s390x" ]] || return 0
    command -v snap >/dev/null 2>&1 || return 0
    if ! snap list openstack-hypervisor >/dev/null 2>&1; then
        log "openstack-hypervisor snap is not installed yet; skipping s390x runtime workarounds for now"
        return 0
    fi

    log_step "applying s390x openstack-hypervisor runtime workarounds"
    check_hypervisor_nova_acpi_patch
    run_logged "connect openstack-hypervisor:mdevctl-config" -- \
        sudo snap connect openstack-hypervisor:mdevctl-config || true

    if [[ "${HYPERVISOR_DISABLE_SPICE}" == "auto" ]]; then
        HYPERVISOR_DISABLE_SPICE=1
    fi
    if [[ "${HYPERVISOR_DISABLE_SPICE}" == "1" ]]; then
        run_logged "disable unsupported SPICE graphics for s390x QEMU" -- \
            sudo install -d -m 0755 /var/snap/openstack-hypervisor/common/etc/nova/nova.conf.d
        tmp_spice="$(mktemp)"
        cat > "${tmp_spice}" <<'EOF'
[spice]
enabled = False
agent_enabled = False
EOF
        sudo install -m 0644 "${tmp_spice}" \
            /var/snap/openstack-hypervisor/common/etc/nova/nova.conf.d/99-s390x-no-spice.conf
        rm -f "${tmp_spice}"
    fi

    if [[ "${HYPERVISOR_SKIP_CEPH_SECRET_CONFIG}" == "1" ]]; then
        # The sentinel lets the snap configure before libvirt exists; after
        # libvirt is running, seed the RBD secret explicitly so live volume
        # attach works.
        run_logged "define libvirt RBD secret for openstack-hypervisor" -- \
            sudo python3 - <<'PY'
import json
import os
import subprocess
import tempfile

try:
    cfg = json.loads(subprocess.check_output(["snap", "get", "-d", "openstack-hypervisor"]))
    compute = cfg["compute"]
    uuid = compute["rbd-secret-uuid"]
    key = compute["rbd-key"]
except Exception:
    raise SystemExit(0)

user = compute.get("rbd-user", "nova")
xml = f"""<secret ephemeral="no" private="no">
  <uuid>{uuid}</uuid>
  <usage type="ceph">
    <name>client.{user} secret</name>
  </usage>
</secret>
"""
with tempfile.NamedTemporaryFile("w", delete=False) as fh:
    fh.write(xml)
    path = fh.name
try:
    subprocess.run(
        ["/snap/openstack-hypervisor/current/usr/bin/virsh", "-c", "qemu:///system", "secret-define", path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    subprocess.run(
        ["/snap/openstack-hypervisor/current/usr/bin/virsh", "-c", "qemu:///system", "secret-set-value", "--secret", uuid, "--base64", key],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
finally:
    os.unlink(path)
PY
    fi

    run_logged "restart openstack-hypervisor libvirt/nova-compute" -- \
        sudo snap restart openstack-hypervisor.libvirtd openstack-hypervisor.nova-compute || true
}

# Manual-provider machine units must match the host base. The default bundle is
# Noble-oriented; on a Resolute LPAR, setting MACHINE_BASE=ubuntu@26.04 renders a
# temporary bundle that asks Juju for 26.04 machine units instead of failing with
# "base does not match".
if [[ -n "${MACHINE_BASE:-}" ]]; then
    rendered_bundle="${ARTIFACT_DIR}/$(basename "${BUNDLE}" .yaml)-${MACHINE_BASE//@/-}.yaml"
    python3 - "${BUNDLE}" "${rendered_bundle}" "${MACHINE_BASE}" <<'PY'
import sys
from pathlib import Path

import yaml

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
machine_base = sys.argv[3]
docs = list(yaml.safe_load_all(source.read_text()))
if not docs or not isinstance(docs[0], dict):
    raise SystemExit(f"{source}: invalid bundle")
for app in docs[0].get("applications", {}).values():
    if isinstance(app, dict):
        app["base"] = machine_base
dest.write_text(yaml.safe_dump_all(docs, sort_keys=False))
PY
    log "rendered machine bundle with MACHINE_BASE=${MACHINE_BASE}: ${rendered_bundle}"
    BUNDLE="${rendered_bundle}"
fi

if [[ ! -r "${BUNDLE}" ]]; then
    log "FATAL: machine bundle missing at ${BUNDLE}"
    exit 1
fi
command -v juju >/dev/null 2>&1 || { log "FATAL: juju CLI missing"; exit 1; }
if ! juju controllers --format=json 2>/dev/null | jq -e ".controllers | has(\"${CONTROLLER}\")" >/dev/null 2>&1; then
    log "FATAL: controller ${CONTROLLER} not found. Run phase 03 first."
    exit 1
fi

# SSH target for the manual machine = this LPAR (recorded by phase 02).
host_ip="$(cat "${ARTIFACT_DIR}/manual_host_ip" 2>/dev/null || true)"
if [[ -z "${host_ip}" ]]; then
    host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    host_ip="${host_ip:-127.0.0.1}"
    echo "${host_ip}" > "${ARTIFACT_DIR}/manual_host_ip"
fi
ssh_user="$(id -un)"
ssh_target="${ssh_user}@${host_ip}"
ssh-keyscan -H "${host_ip}" >> "${HOME}/.ssh/known_hosts" 2>>"${PHASE_LOG}" || true
cloud_yaml="${ARTIFACT_DIR}/manual-cloud.yaml"
cat > "${cloud_yaml}" <<EOF
clouds:
  ${MANUAL_CLOUD}:
    type: manual
    endpoint: ${ssh_target}
    regions:
      default: {}
EOF

# 1. Register a manual cloud pointing at this LPAR, on the existing controller.
if juju clouds --client 2>/dev/null | grep -qw "${MANUAL_CLOUD}"; then
    log "manual cloud ${MANUAL_CLOUD} already registered with juju client"
else
    log_step "adding manual cloud ${MANUAL_CLOUD} to client (endpoint ${ssh_target})"
    run_logged "juju add-cloud (client)" -- juju add-cloud --client "${MANUAL_CLOUD}" "${cloud_yaml}"
fi

if juju clouds --controller "${CONTROLLER}" 2>/dev/null | grep -qw "${MANUAL_CLOUD}"; then
    log "manual cloud ${MANUAL_CLOUD} already registered with controller ${CONTROLLER}"
else
    log_step "adding manual cloud ${MANUAL_CLOUD} to controller ${CONTROLLER}"
    run_logged "juju add-cloud (controller)" -- \
        juju add-cloud --controller "${CONTROLLER}" --force "${MANUAL_CLOUD}" "${cloud_yaml}" || \
        log "WARN: add-cloud to controller returned non-zero (may already be known)"
fi

# 2. Add the machine model on the manual cloud.
if juju models --format=json 2>/dev/null | jq -e ".models[] | select(.\"short-name\"==\"${MACHINE_MODEL}\")" >/dev/null 2>&1; then
    log "model ${MACHINE_MODEL} already exists"
else
    run_logged "juju add-model ${MACHINE_MODEL}" -- \
        juju add-model "${MACHINE_MODEL}" "${MANUAL_CLOUD}"
fi

run_logged "set ${MACHINE_MODEL} architecture constraint" -- \
    juju set-model-constraints -m "${CONTROLLER}:${MACHINE_MODEL}" "arch=${ARCH}"

if [[ -n "${PROXY_URL:-}" ]]; then
    NO_PROXY_VAL="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"
    run_logged "configure Juju proxy (${MACHINE_MODEL})" -- \
        juju model-config -m "${CONTROLLER}:${MACHINE_MODEL}" \
            "juju-http-proxy=${PROXY_URL}" "juju-https-proxy=${PROXY_URL}" \
            "apt-http-proxy=${PROXY_URL}" "apt-https-proxy=${PROXY_URL}" \
            "snap-http-proxy=${PROXY_URL}" "snap-https-proxy=${PROXY_URL}" \
            "juju-no-proxy=${NO_PROXY_VAL}" "apt-no-proxy=${NO_PROXY_VAL}"
fi

# 3. Enrol this LPAR (manual provisioning over SSH). Juju machine IDs are
#    monotonic and are not reused after a failed attempt, so do not assume the
#    enrolled machine will be machine 0.
machine_count=$(juju machines -m "${CONTROLLER}:${MACHINE_MODEL}" --format=json 2>/dev/null \
    | jq '.machines | length' 2>/dev/null || echo 0)
if [[ "${machine_count}" == "0" ]]; then
    log_step "enrolling ${ssh_target} into ${MACHINE_MODEL}"
    if ! run_logged "juju add-machine ssh" -- \
            juju add-machine -m "${CONTROLLER}:${MACHINE_MODEL}" "ssh:${ssh_target}"; then
        log "FATAL: juju add-machine ssh:${ssh_target} failed. Check key-based SSH + passwordless sudo (phase 02)."
        exit 1
    fi
else
    log "machine model already has ${machine_count} machine(s); skipping add-machine"
fi

machine_id="$(juju machines -m "${CONTROLLER}:${MACHINE_MODEL}" --format=json \
    | jq -r --arg instance "manual:${host_ip}" '
        .machines | to_entries
        | map(select(.value["instance-id"] == $instance))
        | sort_by(.key | tonumber)
        | last.key // empty
    ')"
if [[ -z "${machine_id}" ]]; then
    log "FATAL: could not find enrolled manual machine for ${host_ip}"
    juju machines -m "${CONTROLLER}:${MACHINE_MODEL}" 2>&1 | tee -a "${PHASE_LOG}" || true
    exit 1
fi
log "bundle machine 0 will map to enrolled Juju machine ${machine_id}"

# The s390x hypervisor snap can be asked to configure its Ceph libvirt secret
# before the snap-managed libvirt socket exists. Seed the snap's documented
# sentinel before the charm starts configuring the snap so the hook can complete
# and Nova can settle. Keep this overridable so a newly published snap can be
# tested without the workaround.
if [[ "${HYPERVISOR_SKIP_CEPH_SECRET_CONFIG}" == "auto" ]]; then
    if [[ "${ARCH}" == "s390x" ]]; then
        HYPERVISOR_SKIP_CEPH_SECRET_CONFIG=1
    else
        HYPERVISOR_SKIP_CEPH_SECRET_CONFIG=0
    fi
fi
if [[ "${HYPERVISOR_SKIP_CEPH_SECRET_CONFIG}" == "1" ]]; then
    log_step "seeding openstack-hypervisor skip-ceph-secret-config sentinel"
    run_logged "create skip-ceph-secret-config sentinel" -- \
        sudo install -d -m 0755 /var/snap/openstack-hypervisor/common
    run_logged "touch skip-ceph-secret-config sentinel" -- \
        sudo touch /var/snap/openstack-hypervisor/common/skip-ceph-secret-config
fi

sideload_hypervisor_snap

# 4. Deploy the machine bundle. Its saas: block consumes the control-plane offers
#    (admin/${K8S_MODEL}.*) created in phase 03.
log_step "deploying machine bundle (source=${CHARM_SOURCE}) into ${MACHINE_MODEL}: ${BUNDLE}"
# Deploy from the repo root so a 'local' bundle's `charm: ./charms/...` paths
# resolve (harmless for the charmhub bundle, which uses an absolute path).
cd "${REPO_ROOT}"
rc=0
run_logged "juju deploy machine bundle" -- \
    juju deploy -m "${CONTROLLER}:${MACHINE_MODEL}" "${BUNDLE}" \
        --map-machines="existing,0=${machine_id}" || rc=$?
if (( rc != 0 )); then
    log "WARN: juju deploy (machine) returned ${rc}. Phase 05 will still capture state."
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
    exit "${rc}"
fi

if [[ -n "${EXTERNAL_BRIDGE_ADDRESS:-}" ]]; then
    log_step "configuring routed provider bridge address ${EXTERNAL_BRIDGE_ADDRESS}"
    run_logged "configure hypervisor external bridge" -- \
        juju config -m "${CONTROLLER}:${MACHINE_MODEL}" hypervisor \
            "external-bridge-address=${EXTERNAL_BRIDGE_ADDRESS}"
fi

# 5. Wire the reverse offer: cinder-volume (machine model) exports
#    `storage-backend`; cinder-k8s (control plane) consumes it. The control-plane
#    bundle couldn't declare this saas because the offer didn't exist at phase 03.
log_step "consuming storage-backend offer into ${K8S_MODEL} and integrating with cinder"
if ! juju status -m "${CONTROLLER}:${K8S_MODEL}" --format=json 2>/dev/null \
        | jq -e '.["application-endpoints"]["storage-backend"] // .applications["storage-backend"]' >/dev/null 2>&1; then
    run_logged "juju consume storage-backend" -- \
        juju consume -m "${CONTROLLER}:${K8S_MODEL}" "admin/${MACHINE_MODEL}.storage-backend" storage-backend || \
        log "WARN: consume storage-backend failed (offer not ready yet?)"
fi
run_logged "juju integrate cinder:storage-backend" -- \
    juju integrate -m "${CONTROLLER}:${K8S_MODEL}" cinder:storage-backend storage-backend || \
    log "WARN: integrate cinder:storage-backend failed (will need a manual retry once cinder-volume is up)"

# 6. Wait for the machine plane to settle (blocks on missing s390x snaps are
#    expected and captured by phase 05).
log_step "waiting up to ${DEPLOY_TIMEOUT}s for ${MACHINE_MODEL} to settle"
juju_wait_settle "${CONTROLLER}:${MACHINE_MODEL}" "${DEPLOY_TIMEOUT}" || true

apply_s390x_hypervisor_runtime_workarounds

log_step "gating both models on active workloads (timeout ${READINESS_TIMEOUT}s each)"
readiness_rc=0
juju_wait_units_active "${CONTROLLER}:${MACHINE_MODEL}" "${READINESS_TIMEOUT}" || readiness_rc=1
juju_wait_units_active "${CONTROLLER}:${K8S_MODEL}" "${READINESS_TIMEOUT}" || readiness_rc=1
if (( readiness_rc != 0 )); then
    if snap services openstack-hypervisor.libvirtd 2>/dev/null \
            | awk 'NR > 1 && $3 != "active" { found=1 } END { exit !found }'; then
        log "ERROR: openstack-hypervisor.libvirtd is not active"
        if sudo journalctl -u snap.openstack-hypervisor.libvirtd.service -n 50 --no-pager 2>/dev/null \
                | grep -q "/etc/mdevctl.d.*Permission denied"; then
            log "ERROR: installed openstack-hypervisor snap cannot read /etc/mdevctl.d under strict confinement."
            log "This is a snap packaging defect; use a fixed revision with a read-only system-files plug for /etc/mdevctl.d."
        fi
    fi
    echo 1 > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
    exit 1
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
log "NEXT: ./run.sh 04 to configure the cloud (openrc + external network + image + flavors)."
