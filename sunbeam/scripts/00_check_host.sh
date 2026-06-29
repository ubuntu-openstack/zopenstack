#!/usr/bin/env bash
# Phase 00: assert host suitability and capture environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=00_check_host
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

env_file="${ARTIFACT_DIR}/env.txt"
{
    echo "=== uname -a ==="
    uname -a
    echo
    echo "=== /etc/os-release ==="
    cat /etc/os-release 2>/dev/null || echo "missing"
    echo
    echo "=== lscpu ==="
    lscpu 2>/dev/null || echo "lscpu missing"
    echo
    echo "=== free -h ==="
    free -h
    echo
    echo "=== lsblk ==="
    lsblk 2>/dev/null || true
    echo
    echo "=== df -h ==="
    df -h
    echo
    echo "=== ip a ==="
    ip a
    echo
    echo "=== ip r ==="
    ip r
    echo
    echo "=== /dev/kvm ==="
    ls -l /dev/kvm 2>&1 || true
    echo
    echo "=== kvm modules ==="
    lsmod 2>/dev/null | grep -i kvm || echo "no kvm modules loaded"
    echo
    echo "=== /proc/cmdline ==="
    cat /proc/cmdline 2>/dev/null || true
} > "${env_file}"

log_step "wrote ${env_file}"

arch=$(uname -m)
target="$(target_arch)"
log "host arch: ${arch} (deploy target arch: ${target})"
case "${target}" in
    s390x)
        log "s390x: target supported. Expect K8s s390x prep (phase 02b) + possible artifact gaps."
        ;;
    *)
        log "FATAL: unsupported target arch '${target}'. This repository is s390x-only."
        exit 1
        ;;
esac

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log "WARN: expected Ubuntu, got ID=${ID:-unknown}"
    fi
    case "${VERSION_ID:-}" in
        24.04|26.04)
            log "host is Ubuntu ${VERSION_ID}. Sunbeam 2026.1 supports both Noble and Resolute bases."
            ;;
        *)
            log "WARN: expected Ubuntu 24.04 (Noble) or 26.04 (Resolute), got VERSION_ID=${VERSION_ID:-unknown}. K8s may still work; Sunbeam phases (01-04, 06) are not tested on other bases."
            ;;
    esac
fi

mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if (( mem_kb < 16 * 1024 * 1024 )); then
    log "WARN: only $((mem_kb / 1024 / 1024))GB RAM; single-node Sunbeam realistically wants 32GB+"
fi

if [[ ! -e /dev/kvm ]]; then
    log "WARN: /dev/kvm missing. Enable SIE/KVM on s390x; Nova will not be able to launch instances."
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
