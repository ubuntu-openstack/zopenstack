#!/usr/bin/env bash
# Phase 03b: deploy the MACHINE plane (hypervisor + cinder-volume + microceph +
# sunbeam-machine + openstack-network-agents) into a second Juju model on a
# MANUAL cloud whose only machine is this LPAR, and wire it to the control plane
# via cross-model offers.
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
# streams.canonical.com. NO_PROXY_DEFAULT is always defined by tools/lib.sh.
export NO_PROXY="${NO_PROXY_DEFAULT}"
export no_proxy="${NO_PROXY_DEFAULT}"
log "using NO_PROXY=${NO_PROXY_DEFAULT} for Juju agent stream access"

CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
MACHINE_MODEL="${MACHINE_MODEL:-machines}"
MANUAL_CLOUD="${MANUAL_CLOUD:-lpar-manual}"
# Charm source: 'charmhub' (default) or 'local' (our s390x .charm builds from
# ./charms, via the *-local.yaml bundle). Explicit BUNDLE=... override still wins.
CHARM_SOURCE="${CHARM_SOURCE:-charmhub}"
# Release/OS profile. OPENSTACK_SERIES selects the machine charm channels and
# release base; it defaults to hibiscus (2026.2) in tools/release_env.sh.
# BASE_OS can override the base for both models; MACHINE_BASE overrides it for
# this model.
BASE_OS="${BASE_OS:-}"
release="$(openstack_release)"
case "${CHARM_SOURCE}" in
    charmhub) _m_bundle="machine-lpar-s390x.yaml" ;;
    local)    _m_bundle="machine-lpar-s390x-local.yaml" ;;
    hybrid)
        run_python_tool "${REPO_ROOT}/tools/render_hybrid_bundles.py" \
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
# Optional channel overrides for the release renderer. The defaults come from
# tools/render_release_bundles.py; set these only for a custom publication
# track or a locally built charm with a different channel.
MACHINE_CHANNEL="${MACHINE_CHANNEL:-}"
MICROCEPH_CHARM_CHANNEL="${MICROCEPH_CHARM_CHANNEL:-}"
MICROOVN_CHANNEL="${MICROOVN_CHANNEL:-}"
OVN_PROXY_CHANNEL="${OVN_PROXY_CHANNEL:-}"
TOKEN_DISTRIBUTOR_CHANNEL="${TOKEN_DISTRIBUTOR_CHANNEL:-}"
ARCH="$(target_arch)"
HYPERVISOR_SKIP_CEPH_SECRET_CONFIG="${HYPERVISOR_SKIP_CEPH_SECRET_CONFIG:-auto}"
HYPERVISOR_DISABLE_SPICE="${HYPERVISOR_DISABLE_SPICE:-auto}"
HYPERVISOR_DISABLE_VTPM="${HYPERVISOR_DISABLE_VTPM:-auto}"
HYPERVISOR_SNAP_PATH="${HYPERVISOR_SNAP_PATH:-}"
CINDER_VOLUME_SNAP_PATH="${CINDER_VOLUME_SNAP_PATH:-}"
HYPERVISOR_EXPECT_NOVA_ACPI_PATCH="${HYPERVISOR_EXPECT_NOVA_ACPI_PATCH:-auto}"
MICROOVN_EXPORTER_RISK="${MICROOVN_EXPORTER_RISK:-}"
BUILD_LOCAL_SNAPS="${BUILD_LOCAL_SNAPS:-1}"
# External provider network NIC. When unset, phase 03b auto-discovers the only
# safe unconfigured physical NIC. The selected NIC is mapped into the
# openstack-network-agents provider bridge; no internal bridge or dummy
# interface is created. Use EXT_BRIDGE/EXT_PHYSNET to match the Neutron provider
# network created by phase 04.
EXT_NIC="${EXT_NIC:-}"
EXT_BRIDGE="${EXT_BRIDGE:-br-ex}"
EXT_PHYSNET="${EXT_PHYSNET:-physnet1}"
NETWORK_AGENTS_CHANNEL="${NETWORK_AGENTS_CHANNEL:-}"
NETWORK_AGENTS_SNAP_CHANNEL="${NETWORK_AGENTS_SNAP_CHANNEL:-${NETWORK_AGENTS_CHANNEL}}"

if [[ "${BUILD_LOCAL_SNAPS}" == "1" ]]; then
    log_step "building local s390x snaps"
    "${REPO_ROOT}/tools/build_snaps.sh"
    HYPERVISOR_SNAP_PATH="${REPO_ROOT}/snaps/openstack-hypervisor_s390x.snap"
    if [[ -r "${REPO_ROOT}/snaps/cinder-volume_s390x.snap" ]]; then
        CINDER_VOLUME_SNAP_PATH="${REPO_ROOT}/snaps/cinder-volume_s390x.snap"
    fi
fi

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

    msg="installed openstack-hypervisor snap does not appear to stage Nova from ppa:himax16/s390x-nova-acpi (LP #2043987). s390x guest boot may fail with unsupported ACPI."
    if [[ "${HYPERVISOR_EXPECT_NOVA_ACPI_PATCH}" == "warn" ]]; then
        log "WARN: ${msg}"
    else
        log "FATAL: ${msg}"
        exit 1
    fi
}

install_local_snap() {
    local name="$1" path="$2"
    [[ -n "${path}" ]] || return 0
    if [[ ! -r "${path}" ]]; then
        log "FATAL: ${name} snap is not readable: ${path}"
        exit 1
    fi

    if snap list "${name}" >/dev/null 2>&1; then
        run_logged "remove existing ${name} snap" -- \
            sudo snap remove --purge "${name}"
    fi
    log_step "installing local ${name} snap: ${path}"
    # Local validation snaps are not store-declared, so snapd has no
    # auto-connection policy for hardware-observe/system-files before the
    # configure hook runs. Devmode lets the hook configure; the charm then
    # connects the declared interfaces.
    run_logged "snap install local ${name}" -- \
        sudo snap install --dangerous --devmode "${path}"
    # Prevent snapd from replacing the validation snap with a store revision
    # before the charm has a chance to configure it.
    run_logged "hold ${name} snap refreshes" -- \
        sudo snap refresh --hold "${name}" || true
}

connect_hypervisor_plugs() {
    local plug
    local plugs=(
        hardware-observe system-observe mount-observe block-devices
        network-control network-observe process-control
        kernel-module-control kernel-module-observe hugepages-control
        kvm libvirt iscsi-initiator nvme-control raw-usb firewall-control
        dm-multipath microstack-support etc-driverctl mdevctl-config
    )
    for plug in "${plugs[@]}"; do
        sudo snap connect "openstack-hypervisor:${plug}" >/dev/null 2>&1 || true
    done
}

sideload_hypervisor_snap() {
    install_local_snap openstack-hypervisor "${HYPERVISOR_SNAP_PATH}"
    [[ -n "${HYPERVISOR_SNAP_PATH}" ]] || return 0
    connect_hypervisor_plugs
    check_hypervisor_nova_acpi_patch
}

configure_local_hypervisor_devmode() {
    [[ -n "${HYPERVISOR_SNAP_PATH}" ]] || return 0
    if ! snap list openstack-hypervisor 2>/dev/null | grep -q 'devmode'; then
        return 0
    fi
    log_step "allowing devmode openstack-hypervisor snap in the charm"
    run_logged "enable hypervisor experimental-devmode" -- \
        juju config -m "${CONTROLLER}:${MACHINE_MODEL}" hypervisor \
            experimental-devmode=true
}

connect_cinder_volume_plugs() {
    local plug
    local plugs=(
        hardware-observe block-devices network-observe network-control
        mount-observe process-control system-observe
    )
    # The charm installs cinder-volume from the store during deployment. Its
    # configure hook runs before the manually connected interfaces exist, so
    # connect them and restart the service once the snap is present.
    for _ in $(seq 1 60); do
        snap list cinder-volume >/dev/null 2>&1 && break
        sleep 2
    done
    snap list cinder-volume >/dev/null 2>&1 || return 0
    log_step "connecting cinder-volume snap interfaces"
    for plug in "${plugs[@]}"; do
        sudo snap connect "cinder-volume:${plug}" >/dev/null 2>&1 || true
    done
    run_logged "restart cinder-volume after connecting interfaces" -- \
        sudo snap restart cinder-volume || true
}

network_agents_snap_channel() {
    if [[ -n "${NETWORK_AGENTS_SNAP_CHANNEL}" ]]; then
        printf '%s\n' "${NETWORK_AGENTS_SNAP_CHANNEL}"
    elif [[ -n "${MACHINE_CHANNEL}" ]]; then
        printf '%s\n' "${MACHINE_CHANNEL}"
    else
        printf '%s/edge\n' "$(openstack_release)"
    fi
}

install_network_agents_snap() {
    if snap list openstack-network-agents >/dev/null 2>&1; then
        log "openstack-network-agents snap already installed"
        return 0
    fi

    local channel
    channel="$(network_agents_snap_channel)"
    log_step "pre-installing openstack-network-agents snap from ${channel}"
    # Install before the subordinate charm's first configure hook runs. The
    # charm otherwise races snapd: it calls `snap connect` immediately after
    # `snap install`, before the new snap is visible, and blocks.
    run_logged "install openstack-network-agents snap" -- \
        sudo snap install openstack-network-agents --channel "${channel}" || \
        log "WARN: openstack-network-agents snap pre-install failed; the charm will retry"
}

discover_external_nic() {
    if [[ -n "${EXT_NIC}" ]]; then
        printf '%s\n' "${EXT_NIC}" > "${ARTIFACT_DIR}/external_nic.txt"
        return 0
    fi

    local cli
    cli="$(command -v openstack-network-agents 2>/dev/null || true)"
    if [[ -z "${cli}" ]] || ! command -v jq >/dev/null 2>&1; then
        log "WARN: cannot auto-discover EXT_NIC (openstack-network-agents CLI or jq missing)"
        return 0
    fi

    local nics
    if ! nics="$(sudo "${cli}" list-nics 2>>"${PHASE_LOG}")" \
            || ! jq -e . >/dev/null 2>&1 <<<"${nics}"; then
        log "WARN: openstack-network-agents list-nics failed; set EXT_NIC explicitly"
        return 0
    fi

    local default_route_dev default_route_base
    default_route_dev="$(ip -4 route show default 2>/dev/null \
        | awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
    default_route_base="${default_route_dev%%.*}"

    local -a candidates=()
    local nic skip
    while IFS= read -r nic; do
        [[ -n "${nic}" ]] || continue
        skip=0
        case "${nic}" in
            lo|cali*|vxlan*|tun*|tailscale*|br-*|ovs-*|docker*|veth*|virbr*|mpqemu*|workshop*|lxd*|ext[0-9]*|dummy*|ifb*|macvlan*|ipvlan*|vlan*)
                skip=1
                ;;
        esac
        if [[ "${nic}" == "${default_route_dev}" || "${nic}" == "${default_route_base}" ]]; then
            skip=1
        fi
        # A management NIC (or a parent carrying a management VLAN) must not be
        # claimed by OVS. Only unconfigured interfaces are safe candidates.
        if ip -4 -o addr show dev "${nic}" scope global 2>/dev/null | grep -q 'inet '; then
            skip=1
        fi
        (( skip == 0 )) && candidates+=("${nic}")
    done < <(
        jq -r '.nics[] | select(.configured == false and .up == true and .connected == true) | .name' \
            <<<"${nics}"
    )

    if (( ${#candidates[@]} == 1 )); then
        EXT_NIC="${candidates[0]}"
        log "auto-discovered external NIC: ${EXT_NIC}"
        printf '%s\n' "${EXT_NIC}" > "${ARTIFACT_DIR}/external_nic.txt"
    elif (( ${#candidates[@]} == 0 )); then
        log "WARN: no unconfigured candidate external NIC found; set EXT_NIC explicitly"
    else
        log "FATAL: multiple candidate external NICs found (${candidates[*]}); set EXT_NIC explicitly"
        exit 1
    fi
}

refresh_microovn_content_interfaces() {
    [[ "${ARCH}" == "s390x" ]] || return 0
    command -v snap >/dev/null 2>&1 || return 0
    snap list microovn >/dev/null 2>&1 || return 0

    # The OVN/OVS switch socket is created when microovn bootstraps, which can
    # happen after the charms have already connected their content interfaces.
    # snapd then leaves those mounts empty. Reconnect once the socket exists so
    # ovn-exporter and openstack-network-agents see microovn's run/switch.
    local socket="/var/snap/microovn/common/run/switch/db.sock"
    for _ in $(seq 1 60); do
        [[ -S "${socket}" ]] && break
        sleep 2
    done
    if [[ ! -S "${socket}" ]]; then
        log "WARN: ${socket} is not ready; microovn content mounts may be stale"
        return 0
    fi

    log_step "refreshing microovn content-interface mounts"
    if snap list openstack-network-agents >/dev/null 2>&1; then
        sudo snap disconnect openstack-network-agents:ovn-chassis microovn:ovn-chassis \
            >/dev/null 2>&1 || true
        run_logged "reconnect openstack-network-agents:ovn-chassis" -- \
            sudo snap connect openstack-network-agents:ovn-chassis microovn:ovn-chassis || \
            log "WARN: could not reconnect openstack-network-agents:ovn-chassis"
    fi
    if snap list ovn-exporter >/dev/null 2>&1; then
        sudo snap disconnect ovn-exporter:ovn-chassis microovn:ovn-chassis \
            >/dev/null 2>&1 || true
        run_logged "reconnect ovn-exporter:ovn-chassis" -- \
            sudo snap connect ovn-exporter:ovn-chassis microovn:ovn-chassis || \
            log "WARN: could not reconnect ovn-exporter:ovn-chassis"
        run_logged "restart ovn-exporter after content reconnect" -- \
            sudo snap restart ovn-exporter || true
    fi
}

configure_external_nic() {
    [[ -n "${EXT_NIC}" ]] || return 0

    log_step "mapping external NIC ${EXT_NIC} to ${EXT_BRIDGE}/${EXT_PHYSNET}"
    if ! ip link show "${EXT_NIC}" >/dev/null 2>&1; then
        log "FATAL: EXT_NIC=${EXT_NIC} does not exist on this host"
        exit 1
    fi
    if ip -4 addr show dev "${EXT_NIC}" 2>/dev/null | grep -q 'inet '; then
        log "WARN: ${EXT_NIC} already has an IPv4 address; attaching it to OVS may disrupt that network"
    fi
    local mgmt_nic
    mgmt_nic="$(ip -4 route show default 2>/dev/null \
        | awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
    if [[ -n "${mgmt_nic}" && "${mgmt_nic}" == "${EXT_NIC}" ]]; then
        log "FATAL: EXT_NIC=${EXT_NIC} is the default-route interface; use a dedicated external NIC"
        exit 1
    fi

    local unit
    unit="$(
        juju status -m "${CONTROLLER}:${MACHINE_MODEL}" --format=json 2>/dev/null \
            | jq -r '[.applications[] | .units? // {} | to_entries[] | .value.subordinates? // {} | keys[] | select(startswith("openstack-network-agents/"))] | first // empty'
    )"
    if [[ -z "${unit}" ]]; then
        log "FATAL: openstack-network-agents has no unit in ${CONTROLLER}:${MACHINE_MODEL}"
        exit 1
    fi

    local mapping="${EXT_BRIDGE}:${EXT_PHYSNET}:${EXT_NIC}"
    run_logged "configure provider bridge mapping ${mapping}" -- \
        juju run -m "${CONTROLLER}:${MACHINE_MODEL}" --wait=5m "${unit}" \
            set-network-agents-local-settings \
            "bridge-mapping=${mapping}" "enable-chassis-as-gw=true" || {
        log "FATAL: failed to configure openstack-network-agents bridge mapping"
        exit 1
    }
    run_logged "show provider bridge mappings" -- \
        sudo snap get openstack-network-agents network.bridge-mapping ||
        log "WARN: could not read back network.bridge-mapping"
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
    if snap list microovn >/dev/null 2>&1; then
        run_logged "connect openstack-hypervisor:ovn-chassis" -- \
            sudo snap connect openstack-hypervisor:ovn-chassis microovn:ovn-chassis || true
        run_logged "connect openstack-hypervisor:ovn-env" -- \
            sudo snap connect openstack-hypervisor:ovn-env microovn:ovn-env || true
        run_logged "link microovn OVSDB socket for hypervisor" -- \
            sudo mkdir -p /var/snap/openstack-hypervisor/current/microovn/chassis || true
        run_logged "link microovn switch directory" -- \
            sudo ln -sfn /var/snap/microovn/common/run/switch \
                /var/snap/openstack-hypervisor/current/microovn/chassis/switch || true
        run_logged "restart openstack-hypervisor after OVN socket connection" -- \
            sudo snap restart openstack-hypervisor || true
    fi

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

    if [[ "${HYPERVISOR_DISABLE_VTPM}" == "auto" ]]; then
        HYPERVISOR_DISABLE_VTPM=1
    fi
    if [[ "${HYPERVISOR_DISABLE_VTPM}" == "1" ]]; then
        # This build's libvirt reports no vTPM support on s390x; Nova otherwise
        # refuses to start with "vTPM support is configured but not supported".
        run_logged "disable unsupported vTPM for s390x Nova" -- \
            sudo install -d -m 0755 /var/snap/openstack-hypervisor/common/etc/nova/nova.conf.d
        tmp_vtpm="$(mktemp)"
        cat > "${tmp_vtpm}" <<'EOF'
[libvirt]
swtpm_enabled = False
EOF
        sudo install -m 0644 "${tmp_vtpm}" \
            /var/snap/openstack-hypervisor/common/etc/nova/nova.conf.d/99-s390x-no-vtpm.conf
        rm -f "${tmp_vtpm}"
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

if [[ ! -r "${BUNDLE}" ]]; then
    log "FATAL: machine bundle missing at ${BUNDLE}"
    exit 1
fi

# Manual-provider machine units must match the host base. OPENSTACK_SERIES
# selects the release base; MACHINE_BASE can pin a different base explicitly.
# The renderer also selects the matching machine/microovn/proxy channels.
release_base=""
case "${OPENSTACK_SERIES}" in
    hibiscus) release_base="ubuntu@26.04" ;;
    gazpacho) release_base="ubuntu@24.04" ;;
esac
effective_machine_base="${MACHINE_BASE:-${BASE_OS:-${release_base}}}"
if [[ -n "${effective_machine_base}" || -n "${OPENSTACK_SERIES}" \
        || -n "${MACHINE_CHANNEL}" || -n "${MICROCEPH_CHARM_CHANNEL}" \
        || -n "${MICROOVN_CHANNEL}" || -n "${OVN_PROXY_CHANNEL}" \
        || -n "${TOKEN_DISTRIBUTOR_CHANNEL}" ]]; then
    rendered_bundle="${ARTIFACT_DIR}/$(basename "${BUNDLE}" .yaml)-profile.yaml"
    render_args=(
        --source "${BUNDLE}"
        --output "${rendered_bundle}"
        --kind machine
        --release "${release}"
    )
    [[ -n "${effective_machine_base}" ]] && render_args+=(--base "${effective_machine_base}")
    [[ -n "${MACHINE_CHANNEL}" ]] && render_args+=(--machine-channel "${MACHINE_CHANNEL}")
    [[ -n "${MICROCEPH_CHARM_CHANNEL}" ]] && render_args+=(--microceph-channel "${MICROCEPH_CHARM_CHANNEL}")
    [[ -n "${MICROOVN_CHANNEL}" ]] && render_args+=(--microovn-channel "${MICROOVN_CHANNEL}")
    [[ -n "${OVN_PROXY_CHANNEL}" ]] && render_args+=(--ovn-proxy-channel "${OVN_PROXY_CHANNEL}")
    [[ -n "${TOKEN_DISTRIBUTOR_CHANNEL}" ]] && render_args+=(--token-distributor-channel "${TOKEN_DISTRIBUTOR_CHANNEL}")
    run_logged "render machine release profile" -- \
        run_python_tool "${REPO_ROOT}/tools/render_release_bundles.py" "${render_args[@]}"
    log "using machine profile series=${OPENSTACK_SERIES} release=${release} base=${effective_machine_base:-bundle default}: ${rendered_bundle}"
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
if juju models -c "${CONTROLLER}" --format=json 2>/dev/null | jq -e ".models[] | select(.\"short-name\"==\"${MACHINE_MODEL}\")" >/dev/null 2>&1; then
    log "model ${MACHINE_MODEL} already exists"
else
    run_logged "juju add-model ${MACHINE_MODEL}" -- \
        juju add-model -c "${CONTROLLER}" "${MACHINE_MODEL}" "${MANUAL_CLOUD}"
fi

run_logged "set ${MACHINE_MODEL} architecture constraint" -- \
    juju set-model-constraints -m "${CONTROLLER}:${MACHINE_MODEL}" "arch=${ARCH}"

if [[ -n "${PROXY_URL:-}" ]]; then
    NO_PROXY_VAL="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,ubuntu-cloud.archive.canonical.com}"
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
if [[ -n "${CINDER_VOLUME_SNAP_PATH}" ]]; then
    install_local_snap cinder-volume "${CINDER_VOLUME_SNAP_PATH}"
fi
install_network_agents_snap
discover_external_nic

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

# The ovn-exporter content interface must match microovn's slot. The stable
# exporter advertises `content: microovn-run-switch`, which the microovn slot
# does not provide; the edge exporter advertises `content: ovn-chassis` and
# connects successfully. Keep the charm's default edge risk on s390x.
if [[ "${ARCH}" == "s390x" && -z "${MICROOVN_EXPORTER_RISK}" ]]; then
    MICROOVN_EXPORTER_RISK=edge
fi
if [[ -n "${MICROOVN_EXPORTER_RISK}" ]]; then
    run_logged "set microovn ovn-exporter risk" -- \
        juju config -m "${CONTROLLER}:${MACHINE_MODEL}" microovn \
            "ovn_exporter_risk=${MICROOVN_EXPORTER_RISK}" || \
        log "WARN: could not set microovn ovn_exporter_risk=${MICROOVN_EXPORTER_RISK}"
fi

configure_local_hypervisor_devmode

if [[ -n "${EXTERNAL_BRIDGE_ADDRESS:-}" ]]; then
    if [[ -n "${EXT_NIC}" ]]; then
        log_step "configuring network-agents bridge address ${EXTERNAL_BRIDGE_ADDRESS}"
        run_logged "configure openstack-network-agents external bridge address" -- \
            juju config -m "${CONTROLLER}:${MACHINE_MODEL}" openstack-network-agents \
                "external-bridge-address=${EXTERNAL_BRIDGE_ADDRESS}" || \
            log "WARN: could not set openstack-network-agents external-bridge-address"
    else
        log_step "configuring routed provider bridge address ${EXTERNAL_BRIDGE_ADDRESS}"
        run_logged "configure hypervisor external bridge" -- \
            juju config -m "${CONTROLLER}:${MACHINE_MODEL}" hypervisor \
                "external-bridge-address=${EXTERNAL_BRIDGE_ADDRESS}"
    fi
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

# 5b. sunbeam-ovn-proxy (machine model) provides ovsdb-cms; neutron-k8s
#     (control plane) consumes it. The control-plane bundle cannot declare this
#     saas because the machine model and its offer only exist in this phase.
log_step "consuming ovsdb-cms offer into ${K8S_MODEL} and integrating with neutron"
if ! juju status -m "${CONTROLLER}:${K8S_MODEL}" --format=json 2>/dev/null \
        | jq -e '.["application-endpoints"]["ovsdb-cms"] // .applications["ovsdb-cms"]' >/dev/null 2>&1; then
    run_logged "juju consume ovsdb-cms" -- \
        juju consume -m "${CONTROLLER}:${K8S_MODEL}" "admin/${MACHINE_MODEL}.ovsdb-cms" ovsdb-cms || \
        log "WARN: consume ovsdb-cms failed (offer not ready yet?)"
fi
run_logged "juju integrate neutron:ovsdb-cms" -- \
    juju integrate -m "${CONTROLLER}:${K8S_MODEL}" neutron:ovsdb-cms ovsdb-cms || \
    log "WARN: integrate neutron:ovsdb-cms failed (will need a manual retry once sunbeam-ovn-proxy is up)"

# 6. Wait for the machine plane to settle (blocks on missing s390x snaps are
#    expected and captured by phase 05).
log_step "waiting up to ${DEPLOY_TIMEOUT}s for ${MACHINE_MODEL} to settle"
juju_wait_settle "${CONTROLLER}:${MACHINE_MODEL}" "${DEPLOY_TIMEOUT}" || true

refresh_microovn_content_interfaces
configure_external_nic
connect_cinder_volume_plugs
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
