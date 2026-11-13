#!/usr/bin/env bash
# Regression test for the Squid/proxy failure mode: phase 03 inherited a proxy
# from http_proxy but no NO_PROXY, so `juju add-k8s` sent the Kubernetes API
# request through the proxy and failed with `Get "https://...": Forbidden`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/artifacts"

run_case() {
    local label="$1" expected_default="$2"
    (
        unset PROXY_URL NO_PROXY no_proxy NO_PROXY_DEFAULT
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        export http_proxy="http://squid.example:3128"
        export REPO_ROOT RUN_ID=test ARTIFACT_DIR="${tmp}/artifacts"
        # shellcheck source=../tools/lib.sh
        source "${REPO_ROOT}/tools/lib.sh"

        [[ "${PROXY_URL}" == "http://squid.example:3128" ]] || {
            echo "${label}: PROXY_URL was not derived from http_proxy" >&2
            exit 1
        }
        [[ "${NO_PROXY_DEFAULT}" == *"${expected_default}"* ]] || {
            echo "${label}: unexpected NO_PROXY_DEFAULT=${NO_PROXY_DEFAULT}" >&2
            exit 1
        }
        [[ "${NO_PROXY}" == "${NO_PROXY_DEFAULT}" ]] || {
            echo "${label}: NO_PROXY not initialized from NO_PROXY_DEFAULT" >&2
            exit 1
        }
        [[ "${no_proxy}" == "${NO_PROXY_DEFAULT}" ]] || {
            echo "${label}: no_proxy not initialized from NO_PROXY_DEFAULT" >&2
            exit 1
        }
    )
}

run_case "default" "10.0.0.0/8"

(
    unset PROXY_URL NO_PROXY no_proxy
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    export NO_PROXY_DEFAULT="example.test,10.103.192.219"
    export REPO_ROOT RUN_ID=test ARTIFACT_DIR="${tmp}/artifacts"
    # shellcheck source=../tools/lib.sh
    source "${REPO_ROOT}/tools/lib.sh"
    [[ "${NO_PROXY}" == "example.test,10.103.192.219" ]] || {
        echo "custom: NO_PROXY_DEFAULT was not preserved" >&2
        exit 1
    }
)

echo "proxy defaults: OK"
