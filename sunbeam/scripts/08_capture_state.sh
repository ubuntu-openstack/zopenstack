#!/usr/bin/env bash
# Phase 08: state capture. Always exits 0 so collection finishes even on partial deploy.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=08_capture_state
init_phase "${PHASE}"

# Intentionally do NOT phase_skip_if_done: re-running this should always refresh.

k8s_yaml="${ARTIFACT_DIR}/k8s_resources.yaml"
k8s_events="${ARTIFACT_DIR}/k8s_events.txt"
k8s_nodes="${ARTIFACT_DIR}/k8s_nodes_describe.txt"
snaps_file="${ARTIFACT_DIR}/snaps.txt"
bundle="${ARTIFACT_DIR}/juju_bundle.yaml"   # primary (openstack) bundle, for OCI sweep

CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
MACHINE_MODEL="${MACHINE_MODEL:-machines}"
# Capture every model on the controller (openstack control plane + machines).
mapfile -t MODELS < <(juju models -c "${CONTROLLER}" --format=json 2>/dev/null \
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
{
    echo "=== ${CONTROLLER}:openstack ==="
    juju offers -m "${CONTROLLER}:openstack" 2>&1 || true
    echo
    echo "=== ${CONTROLLER}:${MACHINE_MODEL} ==="
    juju offers -m "${CONTROLLER}:${MACHINE_MODEL}" 2>&1 || true
} > "${ARTIFACT_DIR}/juju_offers.txt" 2>> "${PHASE_LOG}"
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

# Record source provenance for locally built charms/snaps/rocks. The built
# artifacts alone do not contain their upstream checkout or commit history.
source_file="${ARTIFACT_DIR}/source_provenance.txt"
{
    echo "=== repository ==="
    if command -v git >/dev/null 2>&1; then
        git -C "${REPO_ROOT}" remote -v 2>&1 || true
        echo "HEAD=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "STATUS:"
        git -C "${REPO_ROOT}" status --porcelain 2>&1 || true
    else
        echo "git unavailable"
    fi
    for d in \
        .charm-build/sunbeam-charms \
        .charm-build/charm-rabbitmq-k8s \
        .charm-build/charm-microceph \
        .charm-build/microcluster-token-distributor-operator \
        .snap-build/snap-openstack-hypervisor \
        .snap-build/snap-cinder-volume \
        .rock-build/rawfile-localpv-rocks-s390x
    do
        [[ -d "${REPO_ROOT}/${d}/.git" ]] || continue
        echo
        echo "=== ${d} ==="
        git -C "${REPO_ROOT}/${d}" remote -v 2>&1 || true
        echo "HEAD=$(git -C "${REPO_ROOT}/${d}" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "STATUS:"
        git -C "${REPO_ROOT}/${d}" status --porcelain 2>&1 || true
    done
    echo
    echo "=== artifact checksums ==="
    find "${REPO_ROOT}/charms" -maxdepth 1 -type f -name '*.charm' -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum
    find "${REPO_ROOT}/snaps" -maxdepth 1 -type f -name '*.snap' -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum
    find "${HOME}/builds/rawfile-localpv-rocks-s390x" -maxdepth 1 -type f -name '*.rock' -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum
} > "${source_file}"

# Best-effort package inventory from the running workload images. Image
# metadata alone does not expose package versions; query the containers.
image_pkg_file="${ARTIFACT_DIR}/image_package_versions.txt"
{
    echo "=== image package versions ==="
    if command -v k8s >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        sudo k8s kubectl get pods -A -o json 2>/dev/null \
            | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $pod
                     | .spec.containers[] | [$ns, $pod, .name, .image] | @tsv' \
            | while IFS=$'\t' read -r ns pod container image; do
                echo
                echo "### ${ns}/${pod} [${container}] ${image}"
                sudo k8s kubectl exec -n "${ns}" "${pod}" -c "${container}" -- sh -c '
                    if command -v dpkg-query >/dev/null 2>&1; then
                        dpkg-query -W -f="\${Package}\t\${Version}\n" 2>/dev/null || true
                    fi
                ' 2>&1 || true
            done
    else
        echo "k8s CLI or jq unavailable"
    fi
} > "${image_pkg_file}"

# `juju export-bundle` records charm resource revisions, not OCI image refs, so
# the exported bundle alone is not enough. Sweep both the bundle (which may
# contain explicit resources for local deployments) and the images actually
# running in the cluster.
log_step "OCI arch introspection across bundle refs and running pods"
images=()
if [[ -s "${bundle}" ]]; then
    mapfile -t bundle_images < <("${SCRIPT_DIR}/../tools/extract_oci_images.sh" "${bundle}")
    images+=("${bundle_images[@]}")
fi
declare -A image_context=()
if command -v k8s >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # Use the pod spec, not `kubectl get all -o yaml`: the latter also contains
    # status.containerStatuses[].image, which is a bare local image ID
    # (sha256:...) rather than a pullable registry reference. Record the
    # namespace/pod and Juju application so the report says what uses each image.
    while IFS=$'\t' read -r img ctx; do
        [[ -n "${img}" ]] || continue
        if [[ -n "${image_context[$img]:-}" ]]; then
            image_context[$img]="${image_context[$img]}, ${ctx}"
        else
            image_context[$img]="${ctx}"
        fi
    done < <(
        sudo k8s kubectl get pods -A -o json 2>/dev/null \
            | jq -r '
                .items[] as $p
                | ($p.metadata.labels["juju-application"]
                   // $p.metadata.labels["app.kubernetes.io/name"]
                   // "") as $app
                | ($p.metadata.namespace + "/" + $p.metadata.name
                   + (if $app != "" then " (" + $app + ")" else "" end)) as $ctx
                | (($p.spec.containers[]?.image), ($p.spec.initContainers[]?.image)) as $img
                | [$img, $ctx] | @tsv
            ' \
            | sort -u || true
    )
    if (( ${#image_context[@]} > 0 )); then
        images+=("${!image_context[@]}")
    fi
else
    log "WARN: k8s CLI or jq missing; skipping running-pod image sweep"
fi
mapfile -t images < <(printf '%s\n' "${images[@]}" | sed '/^$/d' | sort -u)
log_step "found ${#images[@]} unique OCI image refs"
printf '  %-7s %s\n' "RESULT" "IMAGE"
declare -A oci_counts=([yes]=0 [no]=0 [unknown]=0)
for img in "${images[@]}"; do
    result=$("${SCRIPT_DIR}/../tools/check_oci_arch.sh" "${img}" "${TARGET_ARCH:-s390x}" "${image_context[$img]:-}" || true)
    result="${result:-unknown}"
    oci_counts["${result}"]=$(( ${oci_counts["${result}"]:-0} + 1 ))
    printf '  %-7s %s\n' "${result}" "${img}"
done
printf '  OCI arch summary: yes=%d no=%d unknown=%d (target=%s)\n' \
    "${oci_counts[yes]}" "${oci_counts[no]}" "${oci_counts[unknown]}" \
    "${TARGET_ARCH:-s390x}"

# Always succeed: collection-of-failure is itself the artifact.
phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
exit 0
