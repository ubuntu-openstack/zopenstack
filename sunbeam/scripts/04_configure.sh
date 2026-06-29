#!/usr/bin/env bash
# Phase 04: configure the deployed cloud with the `openstack` CLI (no `sunbeam
# configure`). Produces cloud-admin-openrc and the minimum demo resources
# (external network, flavors, s390x guest image) so phase 06's python-tempestconf
# can generate a working tempest.conf and Tempest can boot/volume test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=04_configure
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

"${SCRIPT_DIR}/../tools/setup_proxy.sh"

CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
TARGET="${CONTROLLER}:${K8S_MODEL}"
openrc="${ARTIFACT_DIR}/cloud-admin-openrc"
ca_bundle="${ARTIFACT_DIR}/ca_bundle.pem"

EXT_NET_NAME="${EXT_NET_NAME:-external-network}"
EXT_SUBNET_RANGE="${EXT_SUBNET_RANGE:-172.16.2.0/24}"
EXT_SUBNET_GW="${EXT_SUBNET_GW:-172.16.2.1}"
EXT_SUBNET_POOL="${EXT_SUBNET_POOL:-start=172.16.2.50,end=172.16.2.200}"
EXT_PHYSNET="${EXT_PHYSNET:-physnet1}"
ARCH="$(target_arch)"
GLANCE_ARCH="$(glance_arch "${ARCH}")"
# Ubuntu cloud images are named by Debian arch; glance's `architecture`
# property uses the matching OpenStack architecture value.
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ARCH}.img}"

# 1. openrc from keystone-k8s get-admin-account (the charm returns a ready-made
#    `openrc` field; see keystone-k8s/src/charm.py:1442).
log_step "fetching admin openrc via 'juju run keystone/leader get-admin-account'"
acct_json="${ARTIFACT_DIR}/get-admin-account.json"
if ! juju run -m "${TARGET}" keystone/leader get-admin-account --format=json > "${acct_json}" 2>>"${PHASE_LOG}"; then
    log "FATAL: get-admin-account action failed. Is keystone up in ${TARGET}?"
    exit 1
fi
if ! jq -r '.[].results.openrc' "${acct_json}" > "${openrc}" 2>>"${PHASE_LOG}" || [[ ! -s "${openrc}" ]]; then
    log "FATAL: could not extract openrc from action output (${acct_json})"
    exit 1
fi
log "wrote ${openrc}"

# 2. CA bundle from list-ca-certs (self-signed internal CA). Extract every PEM
#    block found anywhere in the action result; append OS_CACERT to the openrc.
log_step "fetching CA bundle via 'juju run keystone/leader list-ca-certs'"
if juju run -m "${TARGET}" keystone/leader list-ca-certs --format=json 2>>"${PHASE_LOG}" \
        | jq -r '..|strings|select(test("BEGIN CERTIFICATE"))' > "${ca_bundle}" 2>>"${PHASE_LOG}" \
        && [[ -s "${ca_bundle}" ]]; then
    echo "export OS_CACERT=${ca_bundle}" >> "${openrc}"
    log "wrote ${ca_bundle} and appended OS_CACERT"
else
    log "WARN: no CA certs extracted; TLS verification may fail. Consider --insecure for the openstack client."
fi

# 3. OpenStack client. Use Ubuntu's architecture-native package: PyPI does not
# publish wheels for every python-openstackclient dependency on s390x (notably
# cryptography), which otherwise makes pip attempt an unnecessary Rust build.
if ! command -v openstack >/dev/null 2>&1; then
    run_logged "apt install python3-openstackclient" -- \
        sudo apt-get install -y python3-openstackclient
fi
OSC="$(command -v openstack)"

# 4. Demo resources (minimal replica of cloud/etc/demo-setup/main.tf). Each step
#    is best-effort: a partial cloud is still worth capturing + tempest-probing.
log_step "creating demo resources (external network, flavors, ${ARCH} guest image)"
(
    # shellcheck disable=SC1090
    source "${openrc}"
    set +e

    "${OSC}" project create --or-show demo                                   2>&1
    "${OSC}" network show "${EXT_NET_NAME}" >/dev/null 2>&1 || \
        "${OSC}" network create --external \
            --provider-network-type flat --provider-physical-network "${EXT_PHYSNET}" \
            "${EXT_NET_NAME}"                                                 2>&1
    "${OSC}" network set --share "${EXT_NET_NAME}"                            2>&1
    "${OSC}" subnet show external-subnet >/dev/null 2>&1 || \
        "${OSC}" subnet create --network "${EXT_NET_NAME}" \
            --subnet-range "${EXT_SUBNET_RANGE}" --no-dhcp \
            --gateway "${EXT_SUBNET_GW}" --allocation-pool "${EXT_SUBNET_POOL}" \
            external-subnet                                                   2>&1

    # Flavors (sizes from demo-setup/main.tf).
    "${OSC}" flavor show m1.tiny   >/dev/null 2>&1 || "${OSC}" flavor create --public --ram 512  --disk 4  --vcpus 1 m1.tiny    2>&1
    "${OSC}" flavor show m1.small  >/dev/null 2>&1 || "${OSC}" flavor create --public --ram 2048 --disk 30 --vcpus 1 m1.small   2>&1
    "${OSC}" flavor show m1.medium >/dev/null 2>&1 || "${OSC}" flavor create --public --ram 4096 --disk 60 --vcpus 2 m1.medium  2>&1
    "${OSC}" flavor show m1.large  >/dev/null 2>&1 || "${OSC}" flavor create --public --ram 8192 --disk 90 --vcpus 4 m1.large   2>&1

    # s390x guest image.
    if ! "${OSC}" image show ubuntu >/dev/null 2>&1; then
        img="${ARTIFACT_DIR}/$(basename "${IMAGE_URL}")"
        if [[ ! -s "${img}" ]]; then
            echo "downloading ${IMAGE_URL}"
            curl -fL --retry 3 -o "${img}" "${IMAGE_URL}" 2>&1 || echo "WARN: image download failed"
        fi
        if [[ -s "${img}" ]]; then
            "${OSC}" image create --file "${img}" --disk-format qcow2 --container-format bare \
                --public --property architecture="${GLANCE_ARCH}" --property hypervisor_type=qemu ubuntu 2>&1
        fi
    fi
) 2>&1 | tee -a "${PHASE_LOG}"

if [[ -r "${openrc}" ]]; then
    log_step "openrc ready: ${openrc}"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
