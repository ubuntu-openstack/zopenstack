#!/usr/bin/env bash
# Phase 02: host preparation for the bundle-based workflow.
#
# Replaces the old `sunbeam prepare-node-script` step. Without the Sunbeam CLI we
# only need: (1) the juju/k8s CLIs present, (2) kernel modules + /dev/kvm facts
# for the hypervisor, and (3) passwordless SSH back to this host so phase 03b can
# enrol the LPAR as machine 0 of a Juju MANUAL cloud (where the hypervisor runs on
# bare metal).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=02_prepare_node
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

"${SCRIPT_DIR}/../tools/setup_proxy.sh"

if ! command -v juju >/dev/null 2>&1; then
    log "FATAL: juju CLI not on PATH. Did phase 01 install the juju snap successfully?"
    exit 1
fi

# 1. Kernel modules useful for OVN/OVS data plane + KVM, and /dev/kvm presence
#    (nova can't launch instances without it). Non-fatal: record the facts.
ARCH="$(target_arch)"
# kvm is the generic base module. modprobe is best-effort -- missing/builtin
# modules are fine.
log_step "loading kernel modules (containers, CNI/netfilter, KVM + vendor)"
for mod in overlay loop dm_mod bridge br_netfilter 8021q veth vxlan netlink_diag \
           nf_tables nf_nat nf_conntrack nf_conntrack_netlink \
           ip_tables iptable_nat iptable_filter ip_set ip_set_hash_ip \
           ip_set_hash_net ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh \
           xt_socket xt_mark xt_connmark xt_CT xfrm_user \
           sch_ingress cls_bpf act_bpf vhost_vsock kvm; do
    sudo modprobe "${mod}" 2>>"${PHASE_LOG}" || log "note: modprobe ${mod} skipped (builtin/unavailable on ${ARCH})"
done

if [[ -e /dev/kvm ]]; then
    log "OK: /dev/kvm present -- nova can launch instances on this host"
    arch_report_append host /dev/kvm n/a yes "present"
else
    log "WARN: /dev/kvm absent -- nova boot/scenario Tempest tests will fail. Enable SIE/KVM on s390x."
    arch_report_append host /dev/kvm n/a no "absent -- no hardware-accelerated instances"
fi

# 2. Passwordless SSH to this host for the manual-cloud enrolment in phase 03b.
#    juju add-machine ssh:<user>@<host> needs key-based login + passwordless sudo
#    (the latter is a documented prerequisite of this repo).
log_step "ensuring key-based SSH back to this host (for juju manual cloud)"
if ! dpkg -s openssh-server >/dev/null 2>&1; then
    run_logged "apt install openssh-server" -- sudo apt-get install -y openssh-server || \
        log "WARN: openssh-server install failed; phase 03b add-machine will fail"
fi
ssh_key="${HOME}/.ssh/id_ed25519"
if [[ ! -f "${ssh_key}" ]]; then
    log_step "generating ${ssh_key}"
    ssh-keygen -t ed25519 -N "" -f "${ssh_key}" -C "s390x-sunbeam-manual-cloud" 2>>"${PHASE_LOG}"
fi
auth_keys="${HOME}/.ssh/authorized_keys"
touch "${auth_keys}"; chmod 600 "${auth_keys}"
if ! grep -qF "$(cut -d' ' -f2 "${ssh_key}.pub")" "${auth_keys}" 2>/dev/null; then
    cat "${ssh_key}.pub" >> "${auth_keys}"
    log "added local pubkey to ${auth_keys}"
fi
# Record the address phase 03b should use to reach this host.
host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
host_ip="${host_ip:-127.0.0.1}"
echo "${host_ip}" > "${ARTIFACT_DIR}/manual_host_ip"
log "manual-cloud host address recorded: ${host_ip} (-> ${ARTIFACT_DIR}/manual_host_ip)"
# Best-effort: prime known_hosts so the non-interactive add-machine in 03b works.
ssh-keyscan -H "${host_ip}" >> "${HOME}/.ssh/known_hosts" 2>>"${PHASE_LOG}" || true

# 3. Re-introspect installed snap archs for the record.
log_step "post-install snap arch introspection"
for snap_name in juju k8s; do
    if snap list "${snap_name}" >/dev/null 2>&1; then
        installed_channel=$(snap list "${snap_name}" 2>/dev/null | awk 'NR==2 {print $4}')
        "${SCRIPT_DIR}/../tools/check_snap_arch.sh" "${snap_name}" "${installed_channel}" "${ARCH}" || true
    fi
done

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
log "NEXT: run phase 02b (./run.sh 02b) to bootstrap k8s with Calico before phase 03. The default cilium CNI does not run on s390x."
