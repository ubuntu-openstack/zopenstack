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
# at least once so that ${ARTIFACT_DIR}/tempest/tempest is populated. The
# helper uses the tox/venv Tempest when present, otherwise /usr/bin/tempest
# from TEMPEST_PLUGIN_MODE=distro.
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

# Reuse the tox-managed venv when phase 06 was run with TEMPEST_USE_TOX=1.
# The upstream phase 06 path uses the venv at <artifact>/tempest/.venv, so fall
# back to that as well. Distro mode installs /usr/bin/tempest and has no venv.
tempest_bin=""
run_dir="${REPO_ROOT}/artifacts/${RUN_ID}"
for candidate in \
    "${TEMPEST_REPO}/.tox/tempest/bin/tempest" \
    "${TEMPEST_REPO}/.tox/smoke/bin/tempest" \
    "${run_dir}/tempest/.venv/bin/tempest" \
    /usr/bin/tempest; do
    if [[ -x "${candidate}" ]]; then
        tempest_bin="${candidate}"
        break
    fi
done
if [[ -z "${tempest_bin}" ]]; then
    echo "FATAL: no tempest binary found under ${TEMPEST_REPO}/.tox/, ${run_dir}/tempest/.venv, or /usr/bin" >&2
    echo "Run phase 06 first to set it up." >&2
    exit 1
fi

# Distro Tempest on Resolute needs the same testtools shim that phase 06 uses.
compat_dir="${run_dir}/tempest/python-compat"
if [[ -d "${compat_dir}" ]]; then
    export PYTHONPATH="${compat_dir}${PYTHONPATH:+:${PYTHONPATH}}"
fi

echo "run-id: ${RUN_ID}"
echo "tempest binary: ${tempest_bin}"
echo "pattern: ${pattern}"

cd "${TEMPEST_REPO}"
tempest_args=(run --serial --regex "${pattern}")
if [[ -f "${TEMPEST_REPO}/etc/tempest.conf" ]]; then
    tempest_args+=(--config-file "${TEMPEST_REPO}/etc/tempest.conf")
fi
if [[ -s "${TEMPEST_REPO}/exclude-list.txt" ]]; then
    tempest_args+=(--exclude-list "${TEMPEST_REPO}/exclude-list.txt")
fi
exec "${tempest_bin}" "${tempest_args[@]}"
