#!/usr/bin/env bash
# Re-run a single tempest test (or pattern) against an already-set-up tempest
# tox env. Mirrors the zopenstack workflow:
#   . .tox/tempest/bin/activate
#   tempest run --serial --regex <pattern>
#
# Usage:
#   ./tools/run_tempest_test.sh '<test-regex>' [--run-id <id>]
# Example:
#   ./tools/run_tempest_test.sh 'test_dashboard_basic_ops.TestDashboardBasicOps.test_basic_scenario'
#
# Defaults to the most recent run-id under artifacts/. Phase 06 must have run
# at least once so that ${ARTIFACT_DIR}/tempest/tempest is populated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    sed -n '2,11p' "$0"
}

if (( $# < 1 )); then
    usage; exit 2
fi

pattern="$1"; shift

RUN_ID=""
while (( $# > 0 )); do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID=$(ls -1t "${REPO_ROOT}/artifacts" 2>/dev/null | head -1 || true)
fi
if [[ -z "${RUN_ID}" ]]; then
    echo "FATAL: no run-id given and no artifacts/<run-id>/ found" >&2
    exit 1
fi

TEMPEST_REPO="${REPO_ROOT}/artifacts/${RUN_ID}/tempest/tempest"
if [[ ! -d "${TEMPEST_REPO}" ]]; then
    echo "FATAL: ${TEMPEST_REPO} not found. Has phase 06 run for this run-id?" >&2
    exit 1
fi

# Reuse tempest's own tox-managed venv (created by `tox -e smoke --notest`).
tempest_venv="${TEMPEST_REPO}/.tox/tempest"
if [[ ! -x "${tempest_venv}/bin/tempest" ]]; then
    # Some tempest tox envs are named smoke not tempest; fall back.
    if [[ -x "${TEMPEST_REPO}/.tox/smoke/bin/tempest" ]]; then
        tempest_venv="${TEMPEST_REPO}/.tox/smoke"
    else
        echo "FATAL: no tempest tox venv found under ${TEMPEST_REPO}/.tox/" >&2
        echo "Run phase 06 first to set it up." >&2
        exit 1
    fi
fi

echo "run-id: ${RUN_ID}"
echo "tempest venv: ${tempest_venv}"
echo "pattern: ${pattern}"

cd "${TEMPEST_REPO}"
exec "${tempest_venv}/bin/tempest" run --serial --regex "${pattern}"
