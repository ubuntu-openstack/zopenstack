#!/usr/bin/env bash
# Phase 01: install Juju + helper tools. Diagnose s390x snap availability for
# every snap the bundle deployment touches.
#
# NOTE: this is the bundle-based workflow. We do NOT install the `openstack`
# (Sunbeam CLI) snap any more -- the whole point is to deploy plain Juju bundles
# (manifests/control-plane-k8s-s390x.yaml + machine-lpar-s390x.yaml) instead of
# driving `sunbeam cluster bootstrap`/`sunbeam configure`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=01_install_prereqs
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

# Configure proxy first (no-op if PROXY_URL/http_proxy unset). This must run
# before any snap install or apt-get so those operations go through the
# proxy on restricted-egress hosts (e.g. ps6 LPARs).
"${SCRIPT_DIR}/../tools/setup_proxy.sh"

# Channels for the snaps we actually install here + the machine-side snaps whose
# s390x availability we want recorded in arch_report.md before deploying.
JUJU_CHANNEL="${JUJU_CHANNEL:-3/stable}"
# NOTE: 1.32-classic/stable etc. do NOT publish for s390x as of 2026-06.
# Only latest/edge is published for s390x (v1.35.3+). Override if a more
# stable s390x track appears.
K8S_CHANNEL="${K8S_CHANNEL:-latest/edge}"
HYPERVISOR_CHANNEL="${HYPERVISOR_CHANNEL:-2026.1/edge}"
MICROCEPH_CHANNEL="${MICROCEPH_CHANNEL:-squid/stable}"
CINDER_VOLUME_CHANNEL="${CINDER_VOLUME_CHANNEL:-2026.1/edge}"

ARCH="$(target_arch)"
log_step "diagnosing ${ARCH} availability for required snaps (records appended to ${ARCH_REPORT})"
# Installed on the host:
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" juju "${JUJU_CHANNEL}" "${ARCH}" || true
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" k8s  "${K8S_CHANNEL}"  "${ARCH}" || true
# Pulled by the machine-plane charms (phase 03b) -- record availability now even
# though Juju installs them later via the charm:
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" openstack-hypervisor "${HYPERVISOR_CHANNEL}"     "${ARCH}" || true
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" microceph            "${MICROCEPH_CHANNEL}"      "${ARCH}" || true
"${SCRIPT_DIR}/../tools/check_snap_arch.sh" cinder-volume        "${CINDER_VOLUME_CHANNEL}"  "${ARCH}" || true

log_step "refreshing apt package metadata"
run_logged "apt update" -- sudo apt-get update || \
    log "WARN: apt-get update failed; package installs may fail"

log_step "installing workflow prerequisites"
prereq_packages=(
    ca-certificates curl git jq openssh-client openssh-server
    python3 python3-openstackclient python3-venv python3-yaml skopeo tox zstd
)
if ! run_logged "apt install workflow prerequisites" -- \
        sudo apt-get install -y "${prereq_packages[@]}"; then
    log "FATAL: failed to install one or more workflow prerequisites"
    exit 1
fi

log_step "installing juju snap from ${JUJU_CHANNEL}"
if snap list juju >/dev/null 2>&1; then
    log "juju snap already installed; refreshing to ${JUJU_CHANNEL}"
    run_logged "snap refresh juju" -- sudo snap refresh juju --channel="${JUJU_CHANNEL}" || \
        log "WARN: snap refresh juju failed (may be no s390x revision in ${JUJU_CHANNEL})"
else
    if ! run_logged "snap install juju" -- sudo snap install juju --channel="${JUJU_CHANNEL}"; then
        log "FATAL: snap install juju failed (no s390x revision in ${JUJU_CHANNEL}?). Cannot deploy bundles without juju."
        exit 1
    fi
fi

"${SCRIPT_DIR}/../tools/preflight.sh"

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
