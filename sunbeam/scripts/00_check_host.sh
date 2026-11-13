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
            log "host is Ubuntu ${VERSION_ID}. The default Sunbeam 2026.2/Hibiscus profile targets Resolute; Gazpacho supports Noble and Resolute bases."
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

# Deployment phases run apt/snap/Juju commands through sudo. A missing
# passwordless sudo is not fatal for an interactive shell, but it breaks the
# unattended phase driver and should be reported before phase 01.
log_step "checking passwordless sudo and network reachability"
sudo_passwordless=no
if command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
        sudo_passwordless=yes
        log "sudo: passwordless access available"
    else
        log "WARN: passwordless sudo is unavailable; phases 01+ will prompt for a password or fail in non-interactive runs"
    fi
else
    log "WARN: sudo is not installed"
fi

# Check the endpoints that phase 01-06 actually use. Direct checks always run;
# proxy checks also run when PROXY_URL (or https_proxy) is exported. 000 means
# no route; any HTTP response, including 4xx, proves network reachability.
proxy_url="${PROXY_URL:-${https_proxy:-${HTTPS_PROXY:-}}}"
proxy_host=""
if [[ -n "${proxy_url}" ]]; then
    proxy_host="${proxy_url#*://}"
    proxy_host="${proxy_host%%/*}"
    proxy_host="${proxy_host%%:*}"
    if timeout 5 getent hosts "${proxy_host}" >/dev/null 2>&1; then
        log "proxy: ${proxy_host} resolves"
    else
        log "WARN: proxy host '${proxy_host}' does not resolve"
    fi
else
    log "WARN: no PROXY_URL/https_proxy in the current environment; checking direct connectivity only"
fi

CHECK_NET_TIMEOUT="${CHECK_NET_TIMEOUT:-30}"
CHECK_NETWORK="${CHECK_NETWORK:-1}"
check_code=""
check_http() {
    local mode="$1" url="$2"
    check_code=""
    if [[ "${mode}" == "direct" ]]; then
        check_code="$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
            -u ALL_PROXY -u all_proxy curl -4 -sS -o /dev/null -w '%{http_code}' \
            --noproxy '*' --max-time "${CHECK_NET_TIMEOUT}" "${url}" 2>/dev/null || true)"
    else
        check_code="$(env -u NO_PROXY -u no_proxy curl -4 -sS -o /dev/null \
            -w '%{http_code}' --noproxy '' -x "${proxy_url}" \
            --max-time "${CHECK_NET_TIMEOUT}" "${url}" 2>/dev/null || true)"
    fi
    [[ -n "${check_code}" ]] || check_code=000
}

endpoints=(
    "charmhub|https://charmhub.io"
    "uca|http://ubuntu-cloud.archive.canonical.com/ubuntu/"
    "snap-store|https://api.snapcraft.io/v2/snaps/info/core"
    "github|https://github.com"
    "ghcr|https://ghcr.io/v2/"
    "docker|https://registry-1.docker.io/v2/"
)

direct_results=()
proxy_results=()
network_gaps=()
if [[ "${CHECK_NETWORK}" == "1" ]] && command -v curl >/dev/null 2>&1; then
    for endpoint in "${endpoints[@]}"; do
        name="${endpoint%%|*}"
        url="${endpoint#*|}"
        check_http direct "${url}"
        direct_results+=("${name}=${check_code}")
        direct_code="${check_code}"
        proxy_code=000
        if [[ -n "${proxy_url}" ]]; then
            check_http proxy "${url}"
            proxy_code="${check_code}"
            proxy_results+=("${name}=${proxy_code}")
        fi
        if [[ "${direct_code}" == "000" && "${proxy_code}" == "000" ]]; then
            network_gaps+=("${name}")
        fi
    done
    log "network direct: ${direct_results[*]}"
    if [[ -n "${proxy_url}" ]]; then
        log "network proxy (${proxy_host}): ${proxy_results[*]}"
    fi
    if (( ${#network_gaps[@]} > 0 )); then
        log "WARN: no route to: ${network_gaps[*]}"
    fi
elif [[ "${CHECK_NETWORK}" != "1" ]]; then
    log "network checks disabled by CHECK_NETWORK=${CHECK_NETWORK}"
else
    log "WARN: curl is missing; skipped network reachability checks"
fi

{
    echo
    echo "=== sudo ==="
    echo "passwordless=${sudo_passwordless}"
    echo
    echo "=== network direct ==="
    printf '%s\n' "${direct_results[@]}"
    if [[ -n "${proxy_url}" ]]; then
        echo
        echo "=== network proxy (${proxy_host}) ==="
        printf '%s\n' "${proxy_results[@]}"
    fi
    if (( ${#network_gaps[@]} > 0 )); then
        echo
        echo "=== network gaps ==="
        printf '%s\n' "${network_gaps[@]}"
    fi
} >> "${env_file}"

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
