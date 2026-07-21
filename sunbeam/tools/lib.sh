# Shared helpers for the s390x Sunbeam deploy scripts.
# Source me; do not execute.

set -o pipefail

: "${REPO_ROOT:?REPO_ROOT must be exported by run.sh}"
: "${RUN_ID:?RUN_ID must be exported by run.sh}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR must be exported by run.sh}"

ARCH_REPORT="${ARTIFACT_DIR}/arch_report.md"
PHASE_STATUS_DIR="${ARTIFACT_DIR}/.status"
mkdir -p "${PHASE_STATUS_DIR}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
    printf '[%s] %s\n' "$(ts)" "$*" >&2
}

log_step() {
    printf '\n=== [%s] %s ===\n' "$(ts)" "$*" | tee -a "${PHASE_LOG:-/dev/null}" >&2
}

# run_logged <human-readable description> -- <cmd> [args...]
# Streams stdout+stderr of cmd into the active phase log with timestamps,
# AND echoes to the terminal. Returns the command's exit status.
run_logged() {
    local desc="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    log_step "RUN: ${desc}"
    log_step "CMD: $*"
    set -o pipefail
    "$@" 2>&1 \
        | awk -v ts_cmd="date -u +%Y-%m-%dT%H:%M:%SZ" '{ ts_cmd | getline t; close(ts_cmd); printf "[%s] %s\n", t, $0; fflush() }' \
        | tee -a "${PHASE_LOG:-/dev/null}"
    local rc=${PIPESTATUS[0]}
    log_step "RC: ${rc}"
    return "${rc}"
}

require_cmd() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        log "missing required commands: ${missing[*]}"
        return 1
    fi
}

phase_done() {
    local phase="$1"
    rm -f "${PHASE_STATUS_DIR}/${phase}.failed"
    touch "${PHASE_STATUS_DIR}/${phase}.done"
}

phase_is_done() {
    local phase="$1"
    [[ -f "${PHASE_STATUS_DIR}/${phase}.done" ]]
}

phase_skip_if_done() {
    local phase="$1"
    if phase_is_done "${phase}"; then
        log "phase ${phase} already marked done in ${ARTIFACT_DIR}; skipping. Delete ${PHASE_STATUS_DIR}/${phase}.done to force."
        return 0
    fi
    return 1
}

# Initialize a phase log; call once at the top of each phase script.
init_phase() {
    local phase="$1"
    PHASE_LOG="${ARTIFACT_DIR}/phase_${phase}.log"
    export PHASE_LOG
    if phase_is_done "${phase}"; then
        return 0
    fi
    : > "${PHASE_LOG}"
    log_step "phase ${phase} start"
}

# Deployment target architecture in Debian naming. This repository supports
# s390x only; TARGET_ARCH remains as an internal override for tests and
# explicit validation, but preflight rejects non-s390x targets.
target_arch() {
    if [[ -n "${TARGET_ARCH:-}" ]]; then
        echo "${TARGET_ARCH}"
    elif command -v dpkg >/dev/null 2>&1; then
        dpkg --print-architecture
    else
        case "$(uname -m)" in
            *) uname -m ;;
        esac
    fi
}

# Map a Debian arch to the OpenStack/libosinfo image `architecture` property.
glance_arch() {
    case "$1" in
        *) echo "$1" ;;
    esac
}

# juju_wait_settle <controller:model> [timeout_seconds]
# Poll until every unit's juju (agent) status is settled (idle or error) or the
# timeout elapses. Deliberately does NOT require workload=active: on s390x some
# apps are expected to block on missing OCI images/snaps -- that is the signal we
# want to capture, not hang on. Returns 0 when settled, 1 on timeout.
juju_wait_settle() {
    local target="$1" timeout="${2:-3600}"
    local deadline busy
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        busy=$(juju status -m "${target}" --format=json 2>/dev/null \
            | jq '[.applications[].units // {} | .[] | .["juju-status"].current]
                  | map(select(. != "idle" and . != "error")) | length' 2>/dev/null || echo 1)
        if [[ "${busy}" == "0" ]]; then
            log "model ${target} settled (no busy agents)"
            return 0
        fi
        sleep 30
    done
    log "WARN: ${target} did not settle within ${timeout}s; continuing"
    return 1
}

# juju_wait_units_active <controller:model> [timeout_seconds]
# Wait until every unit reports workload=active. Unlike juju_wait_settle this is
# a final deployment gate: idle agents with blocked/waiting/error workloads are
# not a successful cloud.
juju_wait_units_active() {
    local target="$1" timeout="${2:-3600}"
    local deadline unhealthy
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        unhealthy=$(juju status -m "${target}" --format=json 2>/dev/null \
            | jq -r '
                [.applications | to_entries[] as $app
                 | ($app.value.units // {}) | to_entries[]
                 | select(.value["workload-status"].current != "active")
                 | "\($app.key)/\(.key | split("/")[-1])=\(.value["workload-status"].current)"]
                | join(",")
            ' 2>/dev/null || echo "status-unavailable")
        if [[ -z "${unhealthy}" ]]; then
            log "model ${target} ready (all unit workloads active)"
            return 0
        fi
        log "waiting for ${target} workloads: ${unhealthy}"
        sleep 30
    done

    log "ERROR: ${target} did not become ready within ${timeout}s"
    juju status -m "${target}" --color=false 2>&1 | tee -a "${PHASE_LOG:-/dev/null}" || true
    return 1
}

# Append a row to arch_report.md, creating the file/header if absent.
arch_report_append() {
    local kind="$1" name="$2" channel_or_tag="$3" available="$4" note="$5"
    if [[ ! -s "${ARCH_REPORT}" ]]; then
        cat > "${ARCH_REPORT}" <<'EOF'
# Architecture availability report

The `available` column reads `yes (<arch>)` / `no (<arch>)` for the deploy target
arch (TARGET_ARCH, default the host's dpkg arch).

| kind | name | channel/tag | available | note |
|------|------|-------------|-----------|------|
EOF
    fi
    printf '| %s | %s | %s | %s | %s |\n' \
        "${kind}" "${name}" "${channel_or_tag}" "${available}" "${note}" \
        >> "${ARCH_REPORT}"
}
