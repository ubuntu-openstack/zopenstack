#!/usr/bin/env bash
# Source this file to export proxy settings into the current shell:
#
#   source tools/proxy_env.sh [env-file]
#
# The env file is a simple shell manifest (copy proxy.env.example to
# proxy.env). If no file is supplied, $PROXY_ENV_FILE is used, then
# <repo>/proxy.env if it exists. Existing environment variables remain the
# fallback.
#
# This is the interactive-shell counterpart to tools/setup_proxy.sh, which
# configures /etc/environment, APT, snapd, and the Kubernetes snap services.
# Co-maintain the default bypass list with tools/lib.sh.
#
# shellcheck shell=bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This helper must be sourced: source tools/proxy_env.sh [env-file]" >&2
    exit 2
fi

_proxy_repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
_proxy_env_file="${1:-${PROXY_ENV_FILE:-}}"
if [[ -z "${_proxy_env_file}" && -r "${_proxy_repo_root}/proxy.env" ]]; then
    _proxy_env_file="${_proxy_repo_root}/proxy.env"
fi
if [[ -n "${_proxy_env_file}" ]]; then
    if [[ ! -r "${_proxy_env_file}" ]]; then
        echo "proxy_env: cannot read ${_proxy_env_file}" >&2
        return 1
    fi
    _proxy_allexport=0
    [[ $- == *a* ]] && _proxy_allexport=1
    set -a
    # shellcheck disable=SC1090
    . "${_proxy_env_file}"
    (( _proxy_allexport )) || set +a
fi

PROXY_URL="${PROXY_URL:-${http_proxy:-${https_proxy:-${HTTPS_PROXY:-${HTTP_PROXY:-}}}}}"
# Keep in sync with tools/lib.sh and tools/setup_proxy.sh.
NO_PROXY_DEFAULT="${NO_PROXY_DEFAULT:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.charmhub.io,charmhub.io,.jujucharms.com,registry.jujucharms.com,streams.canonical.com,ubuntu-cloud.archive.canonical.com}"

# Interactive `juju status` talks to the host's Kubernetes API to proxy the
# controller service. Include the host IP even when the caller's list only has
# private CIDRs.
_proxy_host_ip="$(
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
)"
if [[ -n "${_proxy_host_ip}" ]]; then
    case ",${NO_PROXY_DEFAULT}," in
        *",${_proxy_host_ip},"*) ;;
        *) NO_PROXY_DEFAULT="${NO_PROXY_DEFAULT},${_proxy_host_ip}" ;;
    esac
fi

export PROXY_URL NO_PROXY_DEFAULT
if [[ -n "${PROXY_URL}" ]]; then
    export http_proxy="${PROXY_URL}"
    export https_proxy="${PROXY_URL}"
    export HTTP_PROXY="${PROXY_URL}"
    export HTTPS_PROXY="${PROXY_URL}"
fi
export NO_PROXY="${NO_PROXY_DEFAULT}"
export no_proxy="${NO_PROXY_DEFAULT}"

unset _proxy_repo_root _proxy_env_file _proxy_allexport _proxy_host_ip
