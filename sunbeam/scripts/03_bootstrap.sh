#!/usr/bin/env bash
# Phase 03: register the running Canonical K8s with Juju, bootstrap a controller,
# and deploy the CORE control-plane bundle into the `openstack` model.
#
# Replaces the old `sunbeam cluster bootstrap`. No Sunbeam CLI: we drive plain
# `juju` against the K8s cluster phase 02b brought up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=03_bootstrap
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

K8S_CLOUD="${K8S_CLOUD:-sunbeam-k8s}"
CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
# Charm source: 'charmhub' (default) deploys published charms; 'local' deploys our
# s390x .charm builds from ./charms with s390x rock images pinned, via the
# *-local.yaml bundle. An explicit BUNDLE=... override still wins.
CHARM_SOURCE="${CHARM_SOURCE:-charmhub}"
case "${CHARM_SOURCE}" in
    charmhub) _cp_bundle="control-plane-k8s-s390x.yaml" ;;
    local)    _cp_bundle="control-plane-k8s-s390x-local.yaml" ;;
    hybrid)
        python3 "${REPO_ROOT}/tools/render_hybrid_bundles.py" \
            --repo "${REPO_ROOT}" --output-dir "${ARTIFACT_DIR}"
        _cp_bundle="${ARTIFACT_DIR}/control-plane-k8s-s390x-hybrid.yaml"
        ;;
    *) log "FATAL: CHARM_SOURCE must be 'charmhub', 'hybrid', or 'local' (got '${CHARM_SOURCE}')"; exit 2 ;;
esac
if [[ "${_cp_bundle}" = /* ]]; then
    BUNDLE="${BUNDLE:-${_cp_bundle}}"
else
    BUNDLE="${BUNDLE:-${REPO_ROOT}/manifests/${_cp_bundle}}"
fi
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-3600}"
ARCH="$(target_arch)"

if [[ ! -r "${BUNDLE}" ]]; then
    log "FATAL: control-plane bundle missing at ${BUNDLE}"
    exit 1
fi
command -v juju >/dev/null 2>&1 || { log "FATAL: juju CLI missing (phase 01)"; exit 1; }
command -v k8s  >/dev/null 2>&1 || { log "FATAL: k8s CLI missing (phase 02b)"; exit 1; }

# `juju add-k8s` talks directly to the API endpoint from `k8s config`.
# setup_proxy.sh runs as a subprocess and cannot export into this shell, so
# enforce the caller-provided bypass list here as well.
if [[ -n "${PROXY_URL:-}" && -n "${NO_PROXY_DEFAULT:-}" ]]; then
    export NO_PROXY="${NO_PROXY_DEFAULT}"
    export no_proxy="${NO_PROXY_DEFAULT}"
    log "using NO_PROXY=${NO_PROXY_DEFAULT} for Juju/Kubernetes API access"
fi

# Background juju status watcher so a wedge during deploy is visible in artifacts
# even if this phase times out.
status_log="${ARTIFACT_DIR}/juju_status_watch.log"
( while true; do
    {
        printf '\n=== [%s] juju status -m %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${K8S_MODEL}"
        juju status -m "${CONTROLLER}:${K8S_MODEL}" --color=false 2>&1 || true
    } >> "${status_log}"
    sleep 30
  done ) &
watcher_pid=$!
log_step "background juju status watcher started (pid ${watcher_pid}, log: ${status_log})"
trap '[[ -n "${watcher_pid:-}" ]] && kill "${watcher_pid}" 2>/dev/null || true' EXIT

# 1. Register the Canonical K8s cluster with the juju client.
if juju clouds --client 2>/dev/null | grep -qw "${K8S_CLOUD}"; then
    log "k8s cloud ${K8S_CLOUD} already registered with juju client"
else
    log_step "registering Canonical K8s with juju as cloud '${K8S_CLOUD}'"
    if ! sudo k8s config 2>>"${PHASE_LOG}" | juju add-k8s "${K8S_CLOUD}" --client 2>&1 | tee -a "${PHASE_LOG}"; then
        log "FATAL: juju add-k8s failed. Is the k8s cluster healthy (phase 02b)?"
        exit 1
    fi
fi

# 2. Bootstrap a controller. The controller runs as a pod -> needs an s390x
#    jujud-operator image. Failure here IS an arch signal worth recording.
if juju controllers --format=json 2>/dev/null | jq -e ".controllers | has(\"${CONTROLLER}\")" >/dev/null 2>&1; then
    log "controller ${CONTROLLER} already bootstrapped"
else
    log_step "bootstrapping controller ${CONTROLLER} on ${K8S_CLOUD}"
    if ! run_logged "juju bootstrap" -- juju bootstrap "${K8S_CLOUD}" "${CONTROLLER}" --debug; then
        log "FATAL: juju bootstrap failed (jujud-operator may have no s390x image)."
        arch_report_append oci jujud-operator controller no "juju bootstrap failed -- see phase log"
        exit 1
    fi
    arch_report_append oci jujud-operator controller yes "controller pod started"
fi

# 3. Add the control-plane model.
if juju models --format=json 2>/dev/null | jq -e ".models[] | select(.\"short-name\"==\"${K8S_MODEL}\")" >/dev/null 2>&1; then
    log "model ${K8S_MODEL} already exists"
else
    run_logged "juju add-model ${K8S_MODEL}" -- juju add-model "${K8S_MODEL}" "${K8S_CLOUD}"
fi

# Pin CAAS application constraints to s390x so Juju does not create pods with an
# impossible kubernetes.io/arch selector on the LPAR cluster.
run_logged "set ${K8S_MODEL} architecture constraint" -- \
    juju set-model-constraints -m "${CONTROLLER}:${K8S_MODEL}" "arch=${ARCH}"

# Juju resolves charms/resources from inside controller/model workers, so shell,
# apt, snapd and containerd proxy setup alone is not sufficient. Configure both
# the controller model and workload model when PROXY_URL is in use.
if [[ -n "${PROXY_URL:-}" ]]; then
    NO_PROXY_VAL="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"
    proxy_settings=(
        "juju-http-proxy=${PROXY_URL}" "juju-https-proxy=${PROXY_URL}"
        "apt-http-proxy=${PROXY_URL}" "apt-https-proxy=${PROXY_URL}"
        "snap-http-proxy=${PROXY_URL}" "snap-https-proxy=${PROXY_URL}"
        "juju-no-proxy=${NO_PROXY_VAL}" "apt-no-proxy=${NO_PROXY_VAL}"
    )
    for model in controller "${K8S_MODEL}"; do
        run_logged "configure Juju proxy (${model})" -- \
            juju model-config -m "${CONTROLLER}:${model}" "${proxy_settings[@]}"
    done
fi

# 4. Deploy the control-plane bundle (exports the cross-model offers).
log_step "deploying control-plane bundle (source=${CHARM_SOURCE}) into ${K8S_MODEL}: ${BUNDLE}"
# Hybrid bundles contain absolute local charm paths. Deploying from the repo
# root remains necessary for the static local bundle's ./charms references.
cd "${REPO_ROOT}"
rc=0
run_logged "juju deploy control-plane bundle" -- \
    juju deploy -m "${CONTROLLER}:${K8S_MODEL}" "${BUNDLE}" --trust || rc=$?
if (( rc != 0 )); then
    log "WARN: juju deploy returned ${rc}. Phase 05 will still capture state."
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
    exit "${rc}"
fi

# Traefik revision 341 (ubuntu@26.04/s390x) currently packages a protobuf UPB
# extension that segfaults under Python 3.14 while importing OpenTelemetry.
# Disabling the optional accelerator makes protobuf use its pure-Python
# implementation; Juju then retries the install hook automatically.
if [[ "${ARCH}" == "s390x" && "${TRAEFIK_DISABLE_BROKEN_UPB:-1}" == "1" ]]; then
    log_step "applying Traefik Python 3.14/s390x protobuf workaround"
    if sudo k8s kubectl -n "${K8S_MODEL}" wait --for=condition=PodScheduled \
            pod/traefik-0 --timeout=180s 2>&1 | tee -a "${PHASE_LOG}"; then
        sudo k8s kubectl -n "${K8S_MODEL}" exec traefik-0 -c charm -- sh -c '
            for so in /var/lib/juju/agents/unit-traefik-0/charm/venv/lib/python*/site-packages/google/_upb/_message.abi3.so; do
                [ -f "$so" ] || continue
                mv "$so" "$so.disabled"
                echo "disabled crashing UPB extension: $so"
            done
        ' 2>&1 | tee -a "${PHASE_LOG}" || \
            log "WARN: could not apply Traefik UPB workaround"
    else
        log "WARN: traefik-0 was not scheduled in time for the UPB workaround"
    fi
fi

# 5. Bounded wait: poll until every unit's agent is settled (idle/error) or
#    timeout. We do NOT require workload=active -- on s390x some apps are
#    expected to block on missing OCI images; that is the signal, captured by
#    phase 05. We just want the deploy to stop churning.
log_step "waiting up to ${DEPLOY_TIMEOUT}s for ${K8S_MODEL} to settle"
juju_wait_settle "${CONTROLLER}:${K8S_MODEL}" "${DEPLOY_TIMEOUT}" || true
juju offers -m "${CONTROLLER}:${K8S_MODEL}" 2>&1 | tee -a "${PHASE_LOG}" || true

image_pull_errors="$(sudo k8s kubectl -n "${K8S_MODEL}" get pods -o json 2>/dev/null \
    | jq '[.items[].status.containerStatuses[]? |
        .state.waiting.reason? |
        select(. == "ErrImagePull" or . == "ImagePullBackOff")] | length')"
if (( image_pull_errors > 0 )); then
    log "FATAL: ${image_pull_errors} control-plane container(s) still have image-pull errors"
    sudo k8s kubectl -n "${K8S_MODEL}" get pods -o wide 2>&1 | tee -a "${PHASE_LOG}" || true
    exit 1
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
log "NEXT: ./run.sh 03b to deploy the machine plane (hypervisor + cinder-volume + microceph)."
