#!/usr/bin/env bash
# Phase 04b: prove the configured cloud can boot a guest and attach a volume.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=04b_smoke_cloud
init_phase "${PHASE}"
phase_skip_if_done "${PHASE}" && exit 0

OPENRC="${ARTIFACT_DIR}/cloud-admin-openrc"
OSC="$(command -v openstack 2>/dev/null || true)"
if [[ ! -r "${OPENRC}" || ! -x "${OSC}" ]]; then
    log "FATAL: phase 04 must produce ${OPENRC} and the OpenStack client first"
    exit 1
fi

# shellcheck disable=SC1090
source "${OPENRC}"

prefix="${SMOKE_PREFIX:-$(target_arch)-verify}"
network="${prefix}-net"
subnet="${prefix}-subnet"
router="${prefix}-router"
server="${prefix}-server"
volume="${prefix}-volume"
keypair="${prefix}-key"
security_group="${prefix}-sg"
cidr="${SMOKE_CIDR:-192.168.222.0/24}"
cleanup="${SMOKE_CLEANUP:-1}"
validate_ssh="${SMOKE_VALIDATE_SSH:-1}"
ssh_user="${SMOKE_SSH_USER:-ubuntu}"
config_drive="${SMOKE_CONFIG_DRIVE:-true}"
ssh_initial_sleep="${SMOKE_SSH_INITIAL_SLEEP:-90}"
ssh_attempts="${SMOKE_SSH_ATTEMPTS:-30}"
ssh_interval="${SMOKE_SSH_INTERVAL:-10}"
launch_log="${ARTIFACT_DIR}/smoke_instance_launch.txt"
fault_log="${ARTIFACT_DIR}/smoke_instance_fault.yaml"
ssh_log="${ARTIFACT_DIR}/smoke_instance_ssh.txt"
ssh_key="$(mktemp "${TMPDIR:-/tmp}/${prefix}-key.XXXXXX")"
rm -f "${ssh_key}"

cleanup_resources() {
    [[ "${cleanup}" == "1" ]] || return 0
    if [[ -n "${floating_ip:-}" ]]; then
        "${OSC}" server remove floating ip "${server}" "${floating_ip}" >/dev/null 2>&1 || true
        "${OSC}" floating ip delete "${floating_ip}" >/dev/null 2>&1 || true
    fi
    "${OSC}" server remove volume "${server}" "${volume}" >/dev/null 2>&1 || true
    "${OSC}" server delete --wait "${server}" >/dev/null 2>&1 || true
    "${OSC}" volume delete "${volume}" >/dev/null 2>&1 || true
    "${OSC}" security group delete "${security_group}" >/dev/null 2>&1 || true
    "${OSC}" keypair delete "${keypair}" >/dev/null 2>&1 || true
    "${OSC}" router remove subnet "${router}" "${subnet}" >/dev/null 2>&1 || true
    "${OSC}" router delete "${router}" >/dev/null 2>&1 || true
    "${OSC}" network delete "${network}" >/dev/null 2>&1 || true
    rm -f "${ssh_key}" "${ssh_key}.pub"
}
trap cleanup_resources EXIT

wait_for_status() {
    local resource="$1" name="$2" wanted="$3" timeout="$4"
    local deadline status
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        status=$("${OSC}" "${resource}" show "${name}" -f value -c status 2>/dev/null || true)
        if [[ "${status,,}" == "${wanted,,}" ]]; then
            return 0
        fi
        case "${status,,}" in
            error|error_*) return 1 ;;
        esac
        sleep 5
    done
    return 1
}

log_step "checking cloud prerequisites"
run_logged "openstack catalog list" -- "${OSC}" catalog list
run_logged "openstack hypervisor list" -- "${OSC}" hypervisor list
run_logged "openstack volume service list" -- "${OSC}" volume service list

if [[ "$("${OSC}" hypervisor list -f value -c "Hypervisor Hostname" | wc -l)" -lt 1 ]]; then
    log "FATAL: no Nova hypervisor is registered"
    exit 1
fi
if ! "${OSC}" image show ubuntu >/dev/null 2>&1; then
    log "FATAL: image 'ubuntu' is missing"
    exit 1
fi

log_step "creating isolated smoke-test network"
"${OSC}" network show "${network}" >/dev/null 2>&1 || "${OSC}" network create "${network}"
"${OSC}" subnet show "${subnet}" >/dev/null 2>&1 || \
    "${OSC}" subnet create --network "${network}" --subnet-range "${cidr}" "${subnet}"
"${OSC}" router show "${router}" >/dev/null 2>&1 || "${OSC}" router create "${router}"
"${OSC}" router set --external-gateway external-network "${router}"
"${OSC}" router add subnet "${router}" "${subnet}" 2>/dev/null || true

log_step "creating smoke-test keypair and security group"
ssh-keygen -q -t ed25519 -N "" -f "${ssh_key}"
"${OSC}" keypair show "${keypair}" >/dev/null 2>&1 || \
    "${OSC}" keypair create --public-key "${ssh_key}.pub" "${keypair}"
"${OSC}" security group show "${security_group}" >/dev/null 2>&1 || \
    "${OSC}" security group create "${security_group}"
"${OSC}" security group rule create --protocol icmp "${security_group}" >/dev/null 2>&1 || true
"${OSC}" security group rule create --protocol tcp --dst-port 22 "${security_group}" >/dev/null 2>&1 || true

log_step "booting smoke-test guest"
server_create_rc=0
if "${OSC}" server show "${server}" >/dev/null 2>&1; then
    "${OSC}" server show "${server}" > "${launch_log}" 2>&1
else
    {
        echo "+ openstack server create --flavor m1.tiny --image ubuntu --network ${network} --key-name ${keypair} --security-group ${security_group} --config-drive ${config_drive} --wait ${server}"
        "${OSC}" server create --flavor m1.tiny --image ubuntu \
            --network "${network}" --key-name "${keypair}" \
            --security-group "${security_group}" \
            --config-drive "${config_drive}" --wait "${server}"
    } > "${launch_log}" 2>&1 || server_create_rc=$?
fi
if (( server_create_rc != 0 )); then
    "${OSC}" server show "${server}" -f yaml > "${fault_log}" 2>&1 || true
    cat "${fault_log}" >> "${PHASE_LOG}" || true
    if grep -qi "does not support ACPI" "${fault_log}" "${launch_log}"; then
        log "FATAL: Nova/libvirt emitted ACPI for an s390x guest; see LP #2043987. Rebuild openstack-hypervisor with ppa:mylesjp/nova-acpi-patch and rerun phase 03b with HYPERVISOR_SNAP_PATH=<snap> HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1."
    else
        log "FATAL: smoke-test guest create failed; see ${launch_log} and ${fault_log}"
    fi
    exit 1
fi
if ! wait_for_status server "${server}" ACTIVE 600; then
    "${OSC}" server show "${server}" -f yaml 2>&1 | tee "${fault_log}" | tee -a "${PHASE_LOG}" || true
    if grep -qi "does not support ACPI" "${fault_log}" "${launch_log}"; then
        log "FATAL: Nova/libvirt emitted ACPI for an s390x guest; see LP #2043987. Rebuild openstack-hypervisor with ppa:mylesjp/nova-acpi-patch and rerun phase 03b with HYPERVISOR_SNAP_PATH=<snap> HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1."
        exit 1
    fi
    log "FATAL: smoke-test guest did not become ACTIVE"
    exit 1
fi
"${OSC}" server show "${server}" >> "${launch_log}" 2>&1

log_step "creating and attaching smoke-test volume"
"${OSC}" volume show "${volume}" >/dev/null 2>&1 || "${OSC}" volume create --size 1 "${volume}"
wait_for_status volume "${volume}" available 300
"${OSC}" server add volume "${server}" "${volume}"
wait_for_status volume "${volume}" in-use 300

"${OSC}" server show "${server}" -f yaml > "${ARTIFACT_DIR}/smoke_server.yaml"
"${OSC}" volume show "${volume}" -f yaml > "${ARTIFACT_DIR}/smoke_volume.yaml"

if [[ "${validate_ssh}" == "1" ]]; then
    log_step "assigning a floating IP and proving SSH access"
    {
        echo "++ openstack floating ip create external-network"
        floating_ip=$("${OSC}" floating ip create external-network -f value -c floating_ip_address)
        echo "++ grep floating_ip_address"
        echo "++ awk '{print \$4}'"
        echo "+ ip_addr=${floating_ip}"
        echo "+ ssh-keygen -f ${HOME}/.ssh/known_hosts -R ${floating_ip}"
        ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${floating_ip}" || true
        echo "+ openstack server add floating ip ${server} ${floating_ip}"
        "${OSC}" server add floating ip "${server}" "${floating_ip}"
        echo "+ sleep ${ssh_initial_sleep}"
        sleep "${ssh_initial_sleep}"
        echo "+ ssh ${ssh_user}@${floating_ip} -i ${ssh_key} -oStrictHostKeyChecking=accept-new echo SSH works"
    } > "${ssh_log}"
    ssh_ok=0
    for _ in $(seq 1 "${ssh_attempts}"); do
        if ssh -i "${ssh_key}" -o BatchMode=yes -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=accept-new \
                "${ssh_user}@${floating_ip}" \
                'echo "SSH works"; uname -m; sed -n "1,6p" /etc/os-release' \
                >> "${ssh_log}" 2>&1; then
            ssh_ok=1
            break
        fi
        sleep "${ssh_interval}"
    done
    if (( ! ssh_ok )); then
        log "FATAL: smoke guest is ACTIVE but SSH to ${floating_ip} failed"
        exit 1
    fi
    {
        echo "+ openstack server remove floating ip ${server} ${floating_ip}"
        "${OSC}" server remove floating ip "${server}" "${floating_ip}"
    } >> "${ssh_log}" 2>&1 || true
else
    echo "SSH validation disabled with SMOKE_VALIDATE_SSH=${validate_ssh}" > "${ssh_log}"
fi

arch_report_append openstack-smoke guest+volume+ssh "${prefix}" "yes ($(target_arch))" \
    "server ACTIVE; volume attached; SSH ${ssh_ok:-disabled}"

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
