# Shared helpers for the s390x Sunbeam deploy scripts.
# Source me; do not execute.

set -o pipefail

: "${REPO_ROOT:?REPO_ROOT must be exported by run.sh}"
: "${RUN_ID:?RUN_ID must be exported by run.sh}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR must be exported by run.sh}"

# shellcheck source=release_env.sh
source "${BASH_SOURCE[0]%/*}/release_env.sh"

ARCH_REPORT="${ARTIFACT_DIR}/arch_report.md"
PHASE_STATUS_DIR="${ARTIFACT_DIR}/.status"
mkdir -p "${PHASE_STATUS_DIR}"

# Proxy bypass defaults. Keep cluster-internal traffic out of the HTTP proxy
# even when the caller only exported http_proxy/https_proxy. The previous
# fallback lived only inside setup_proxy.sh, so phase 03 could inherit a proxy
# but no NO_PROXY; Juju then sent the Kubernetes API request through Squid and
# failed with the misleading error:
#   Get "https://<api>:6443/...": Forbidden
: "${NO_PROXY_DEFAULT:=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.charmhub.io,charmhub.io,.jujucharms.com,registry.jujucharms.com,streams.canonical.com,ubuntu-cloud.archive.canonical.com}"
export NO_PROXY_DEFAULT
if [[ -z "${PROXY_URL:-}" ]]; then
    PROXY_URL="${http_proxy:-${https_proxy:-${HTTPS_PROXY:-${HTTP_PROXY:-}}}}"
    export PROXY_URL
fi
if [[ -z "${NO_PROXY:-}" ]]; then
    export NO_PROXY="${NO_PROXY_DEFAULT}"
fi
if [[ -z "${no_proxy:-}" ]]; then
    export no_proxy="${NO_PROXY_DEFAULT}"
fi

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
    printf '[%s] %s\n' "$(ts)" "$*" >&2
}

log_step() {
    printf '=== [%s] %s ===\n' "$(ts)" "$*" | tee -a "${PHASE_LOG:-/dev/null}" >&2
}

# run_logged <human-readable description> -- <cmd> [args...]
# Writes the full command output to the phase log, but only prints a compact
# RUN/OK line to the terminal. On failure it prints the complete captured
# output. Set RUN_LOGGED_VERBOSE=1 to stream everything live.
run_logged() {
    local desc="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    local rc=0 out
    out="$(mktemp "${TMPDIR:-/tmp}/run-logged.XXXXXX")"

    if [[ "${RUN_LOGGED_VERBOSE:-0}" == "1" ]]; then
        log_step "RUN: ${desc}"
        log_step "CMD: $*"
        set -o pipefail
        "$@" 2>&1 \
            | awk -v ts_cmd="date -u +%Y-%m-%dT%H:%M:%SZ" '{ ts_cmd | getline t; close(ts_cmd); printf "[%s] %s\n", t, $0; fflush() }' \
            | tee -a "${PHASE_LOG:-/dev/null}"
        rc=${PIPESTATUS[0]}
        log "RC: ${rc}"
    else
        log "RUN: ${desc}"
        "$@" >"${out}" 2>&1 || rc=$?
        {
            printf '[%s] RUN: %s\n' "$(ts)" "${desc}"
            printf '[%s] CMD: %s\n' "$(ts)" "$*"
            cat "${out}"
        } >> "${PHASE_LOG:-/dev/null}"
        if (( rc == 0 )); then
            log "OK: ${desc}"
        else
            log "FAILED: ${desc} (rc=${rc}); full output follows"
            awk -v t="$(ts)" '{ printf "[%s] %s\n", t, $0 }' "${out}" >&2
        fi
    fi

    rm -f "${out}"
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

# run_python_tool <tool.py> [args...]
# Run the repository's Python helpers with the host python3; phase 01 installs
# python3-yaml.
run_python_tool() {
    local tool="$1"; shift
    python3 "${tool}" "$@"
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
            | jq '
                # Principal units with no units yet are not settled, and
                # subordinate agents matter just as much as principal ones.
                ([.applications | to_entries[]
                  | select((.value["subordinate-to"] // []) | length == 0)
                  | select((.value.units // {}) | length == 0)
                  | .key] | length)
                +
                ([.applications | to_entries[] as $app
                  | ($app.value.units // {}) | to_entries[] as $unit
                  | ([$unit.value] + [($unit.value.subordinates // {})[]])[]
                  | .["juju-status"].current]
                 | map(select(. != "idle" and . != "error")) | length)
              ' 2>/dev/null || echo 1)
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
                 | select(($app.value["subordinate-to"] // []) | length == 0)
                 | ($app.value.units // {}) as $units
                 | if ($units | length) == 0 then
                     "\($app.key)=no-units"
                   else
                     $units | to_entries[] as $unit
                     | ([{name: $unit.key, status: $unit.value}]
                        + [($unit.value.subordinates // {}) | to_entries[]
                           | {name: .key, status: .value}])
                     | .[]
                     | select(.status["workload-status"].current != "active")
                     | "\(.name)=\(.status["workload-status"].current)"
                   end]
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
