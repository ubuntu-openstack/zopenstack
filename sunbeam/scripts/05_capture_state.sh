#!/usr/bin/env bash
# Phase 05: state capture. Always exits 0 so collection finishes even on partial deploy.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=05_capture_state
init_phase "${PHASE}"

# Intentionally do NOT phase_skip_if_done: re-running this should always refresh.

k8s_yaml="${ARTIFACT_DIR}/k8s_resources.yaml"
k8s_events="${ARTIFACT_DIR}/k8s_events.txt"
k8s_nodes="${ARTIFACT_DIR}/k8s_nodes_describe.txt"
snaps_file="${ARTIFACT_DIR}/snaps.txt"
bundle="${ARTIFACT_DIR}/juju_bundle.yaml"   # primary (openstack) bundle, for OCI sweep

CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
# Capture every model on the controller (openstack control plane + machines).
mapfile -t MODELS < <(juju models --format=json 2>/dev/null \
    | jq -r '.models[]."short-name"' 2>/dev/null | grep -v '^controller$' || true)
[[ ${#MODELS[@]} -eq 0 ]] && MODELS=(openstack machines)

log_step "capturing juju state for models: ${MODELS[*]}"
for m in "${MODELS[@]}"; do
    tgt="${CONTROLLER}:${m}"
    juju export-bundle -m "${tgt}" > "${ARTIFACT_DIR}/juju_bundle_${m}.yaml" 2>> "${PHASE_LOG}" || \
        log "WARN: juju export bundle (${m}) failed"
    juju status -m "${tgt}" --format=yaml > "${ARTIFACT_DIR}/juju_status_${m}.txt" 2>> "${PHASE_LOG}" || \
        log "WARN: juju status (${m}) failed"
    juju status -m "${tgt}" --relations --color=false > "${ARTIFACT_DIR}/juju_status_relations_${m}.txt" 2>> "${PHASE_LOG}" || true
done
juju offers -m "${CONTROLLER}:openstack" > "${ARTIFACT_DIR}/juju_offers.txt" 2>> "${PHASE_LOG}" || true
# Primary bundle for the OCI arch sweep below = the control-plane (openstack) one.
cp -f "${ARTIFACT_DIR}/juju_bundle_openstack.yaml" "${bundle}" 2>/dev/null || true

log_step "k8s resources -> ${k8s_yaml}"
if command -v k8s >/dev/null 2>&1; then
    sudo k8s kubectl get all -A -o yaml > "${k8s_yaml}" 2>> "${PHASE_LOG}" || \
        log "WARN: k8s kubectl get all failed"
    sudo k8s kubectl get events -A --sort-by=.lastTimestamp > "${k8s_events}" 2>> "${PHASE_LOG}" || true
    sudo k8s kubectl describe nodes > "${k8s_nodes}" 2>> "${PHASE_LOG}" || true
else
    log "WARN: k8s CLI missing; skipping k8s captures"
fi

log_step "snap inventory -> ${snaps_file}"
{
    echo "=== snap list ==="
    snap list 2>&1 || true
    echo
    for s in juju k8s openstack-hypervisor microceph cinder-volume; do
        echo "=== snap info ${s} ==="
        snap info --verbose "${s}" 2>&1 || true
        echo
    done
} > "${snaps_file}"

log_step "OCI arch introspection across the resolved bundle"
if [[ -s "${bundle}" ]]; then
    mapfile -t images < <("${SCRIPT_DIR}/../tools/extract_oci_images.sh" "${bundle}")
    log_step "found ${#images[@]} OCI image refs in bundle"
    for img in "${images[@]}"; do
        "${SCRIPT_DIR}/../tools/check_oci_arch.sh" "${img}" || true
    done
else
    log "WARN: bundle empty, skipping OCI introspection"
fi

# Always succeed: collection-of-failure is itself the artifact.
phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
exit 0
