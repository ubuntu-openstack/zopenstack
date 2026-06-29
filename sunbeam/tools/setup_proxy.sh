#!/usr/bin/env bash
# Configure HTTP proxy across all the places that matter for a Sunbeam/K8s
# deploy: shell env, /etc/environment, apt, snap, and (if installed) the
# K8s snap's k8sd systemd unit. Idempotent.
#
# Driven by $PROXY_URL (preferred) or $http_proxy. If neither is set the
# script logs that and exits 0 so it's safe to call unconditionally from
# phase scripts on hosts that don't need a proxy.
#
# Usage: PROXY_URL=http://squid.ps6.internal:3128 ./tools/setup_proxy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export RUN_ID="${RUN_ID:-proxy-setup}"
export ARTIFACT_DIR="${ARTIFACT_DIR:-${REPO_ROOT}/artifacts/${RUN_ID}}"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROXY_URL="${PROXY_URL:-${http_proxy:-}}"
NO_PROXY_VAL="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"

if [[ -z "${PROXY_URL}" ]]; then
    log "no PROXY_URL or http_proxy set; nothing to configure"
    exit 0
fi

log_step "configuring proxy: ${PROXY_URL}"

# 1. /etc/environment -- so every new login + systemd unit picks it up.
# Replace existing values rather than only appending once: EnvironmentFile can
# override a systemd drop-in and leave a restarted daemon with stale NO_PROXY.
log_step "updating proxy env in /etc/environment"
sudo sed -i -E \
    '/^(http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY)=/d' \
    /etc/environment
sudo tee -a /etc/environment >/dev/null <<EOF
http_proxy=${PROXY_URL}
https_proxy=${PROXY_URL}
HTTP_PROXY=${PROXY_URL}
HTTPS_PROXY=${PROXY_URL}
no_proxy=${NO_PROXY_VAL}
NO_PROXY=${NO_PROXY_VAL}
EOF

# 2. apt -- needed for any apt-get install during phase 01.
apt_conf=/etc/apt/apt.conf.d/95proxy
if [[ ! -f "${apt_conf}" ]] || ! grep -qF "${PROXY_URL}" "${apt_conf}"; then
    log_step "writing apt proxy config to ${apt_conf}"
    sudo tee "${apt_conf}" >/dev/null <<EOF
Acquire::http::Proxy "${PROXY_URL}";
Acquire::https::Proxy "${PROXY_URL}";
EOF
fi

# 3. snap -- the Snap Store and snap downloads.
current_http=$(sudo snap get system proxy.http 2>/dev/null || true)
if [[ "${current_http}" != "${PROXY_URL}" ]]; then
    log_step "configuring snap proxy"
    sudo snap set system proxy.http="${PROXY_URL}"
    sudo snap set system proxy.https="${PROXY_URL}"
    sudo systemctl restart snapd
fi

# 4. K8s snap services. k8sd reconciles features, while containerd performs
# image pulls; both need the proxy.
#
# During the first Canonical K8s bootstrap, however, starting the snap's
# containerd service before `k8s bootstrap` causes bootstrap preflight to fail:
# it sees /run/containerd and assumes a conflicting runtime is already present.
# Callers that are preparing for first bootstrap can set
# SETUP_PROXY_RESTART_K8S=0 to install the drop-ins without starting/restarting
# the K8s daemons.
restart_k8s_services="${SETUP_PROXY_RESTART_K8S:-1}"
k8s_services=(snap.k8s.k8sd.service snap.k8s.containerd.service)
for service in "${k8s_services[@]}"; do
    if systemctl list-unit-files "${service}" 2>/dev/null | grep -q "${service}"; then
        drop_in_dir="/etc/systemd/system/${service}.d"
        drop_in="${drop_in_dir}/proxy.conf"
        if [[ ! -f "${drop_in}" ]] || ! grep -qF "${PROXY_URL}" "${drop_in}" \
                || ! grep -qF "${NO_PROXY_VAL}" "${drop_in}"; then
            log_step "writing ${service} proxy drop-in to ${drop_in}"
            sudo mkdir -p "${drop_in_dir}"
            sudo tee "${drop_in}" >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY_URL}"
Environment="HTTPS_PROXY=${PROXY_URL}"
Environment="NO_PROXY=${NO_PROXY_VAL}"
EOF
            sudo systemctl daemon-reload
            if [[ "${restart_k8s_services}" == "1" ]]; then
                sudo systemctl restart "${service}"
            else
                log "deferred ${service} restart until after k8s bootstrap"
            fi
        fi
    else
        log "${service} not installed yet; skipping systemd drop-in"
    fi
done

# snap.k8s.containerd uses EnvironmentFile=/etc/environment. On some systemd
# versions a normal restart can leave the existing main process alive, so
# verify its live environment and ask Restart=always to replace it if stale.
containerd_service=snap.k8s.containerd.service
if [[ "${restart_k8s_services}" == "1" ]] && systemctl is-active --quiet "${containerd_service}"; then
    main_pid="$(systemctl show "${containerd_service}" -p MainPID --value)"
    live_no_proxy="$(
        sudo sh -c "tr '\\0' '\\n' </proc/${main_pid}/environ" 2>/dev/null \
            | sed -n 's/^NO_PROXY=//p'
    )"
    if [[ "${live_no_proxy}" != "${NO_PROXY_VAL}" ]]; then
        log_step "restarting containerd main process to apply updated NO_PROXY"
        old_pid="${main_pid}"
        sudo systemctl kill --kill-who=main --signal=SIGTERM "${containerd_service}"
        for _ in $(seq 1 30); do
            main_pid="$(systemctl show "${containerd_service}" -p MainPID --value)"
            [[ "${main_pid}" != "0" && "${main_pid}" != "${old_pid}" ]] && break
            sleep 1
        done
    fi
fi

log_step "proxy setup complete"
