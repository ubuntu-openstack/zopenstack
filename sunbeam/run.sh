#!/usr/bin/env bash
# Driver for the s390x single-node Sunbeam reproducer.
# Usage:
#   ./run.sh all          # run all phases in order
#   ./run.sh 03           # run only phase 03 (prefix-match against script filenames)
#   ./run.sh --run-id <id> all   # resume into an existing artifacts/<id>/ dir
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# -------- parse args --------
RUN_ID=""
PHASE_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *) PHASE_ARG="$1"; shift ;;
    esac
done

if [[ -z "${PHASE_ARG}" ]]; then
    echo "usage: $0 [--run-id <id>] {all|<phase-prefix>}" >&2
    exit 2
fi

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
fi
export RUN_ID

ARTIFACT_ROOT="${ARTIFACT_ROOT:-${REPO_ROOT}/artifacts}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
mkdir -p "${ARTIFACT_DIR}/.status"
export ARTIFACT_DIR

echo "run_id=${RUN_ID}"
echo "artifact_dir=${ARTIFACT_DIR}"

# -------- phase dispatch --------
# Glob: any script starting with two digits. Force LC_ALL=C sort so `02_*`
# precedes `02b_*` -- some locales treat `_` as a non-letter and would reverse
# the order, which would run phase 02b before phase 02.
shopt -s nullglob
PHASES_DIR="${PHASES_DIR:-${REPO_ROOT}/scripts}"
mapfile -t all_phases < <(
    LC_ALL=C ls "${PHASES_DIR}"/[0-9][0-9]*.sh 2>/dev/null
)

select_phases=()
if [[ "${PHASE_ARG}" == "all" ]]; then
    select_phases=("${all_phases[@]}")
else
    # Prefer an exact script name or phase identifier (the filename portion
    # before the first underscore). Thus `04` selects 04_configure only, while
    # `04b` selects 04b_smoke_cloud.
    for p in "${all_phases[@]}"; do
        base=$(basename "$p")
        phase_id="${base%%_*}"
        if [[ "${base%.sh}" == "${PHASE_ARG}" || "${phase_id}" == "${PHASE_ARG}" ]]; then
            select_phases+=("$p")
        fi
    done
    if (( ${#select_phases[@]} == 0 )); then
        for p in "${all_phases[@]}"; do
            base=$(basename "$p")
            if [[ "${base}" == "${PHASE_ARG}"* ]]; then
                select_phases+=("$p")
            fi
        done
    fi
fi

if (( ${#select_phases[@]} == 0 )); then
    echo "no matching phase for '${PHASE_ARG}'. Available:" >&2
    for p in "${all_phases[@]}"; do echo "  $(basename "$p")" >&2; done
    exit 2
fi

# Phase 05 (capture) is special: if we're running 'all' and any earlier phase
# fails, we still want to run 05 + 99 for the post-mortem.
overall_rc=0
capture_only=0
for script in "${select_phases[@]}"; do
    base=$(basename "$script")
    if (( capture_only )); then
        case "${base}" in
            05_capture_state.sh|99_collect_artifacts.sh) ;;
            *)
                echo ">>> ${base} skipped after blocking phase failure"
                continue
                ;;
        esac
    fi
    echo "================================================================"
    echo ">>> ${base}"
    echo "================================================================"
    rc=0
    bash "$script" || rc=$?
    if (( rc != 0 )); then
        phase_name="${base%.sh}"
        if [[ ! -f "${ARTIFACT_DIR}/.status/${phase_name}.failed" ]]; then
            echo "${rc}" > "${ARTIFACT_DIR}/.status/${phase_name}.failed"
        fi
        overall_rc="${rc}"
        echo "!!! ${base} returned ${rc}"
        # For 'all', continue into capture+collect so we still get artifacts.
        if [[ "${PHASE_ARG}" == "all" ]]; then
            case "${base}" in
                05_capture_state.sh|99_collect_artifacts.sh) continue ;;
                *)
                    capture_only=1
                    echo "skipping dependent phases; continuing to 05/99 for post-mortem capture"
                    ;;
            esac
        else
            exit "${rc}"
        fi
    fi
done

exit "${overall_rc}"
