#!/usr/bin/env bash
# Report whether a snap has a revision for the target arch in the requested channel.
# Usage: check_snap_arch.sh <snap-name> <channel> [arch]
# arch defaults to ${TARGET_ARCH:-s390x}.
# Writes one row to arch_report.md and prints yes/no/unknown to stdout.
#
# `snap info` only shows the revision for the host architecture and does not
# print the architecture name, so it cannot answer an arch-specific question.
# Query the public Snap Store API instead; it exposes every published
# architecture in the channel map.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

snap_name="${1:?snap name required}"
channel="${2:?channel required}"
arch="${3:-${TARGET_ARCH:-s390x}}"
snap_api_timeout="${CHECK_SNAP_API_TIMEOUT:-30}"
snap_cli_timeout="${CHECK_SNAP_CLI_TIMEOUT:-30}"

report() {
    arch_report_append snap "${snap_name}" "${channel}" "$1" "$2"
    echo "$3"
}

# Normalize "latest/<risk>" because the store API records the default track as
# "<risk>" (for example, channel.name == "edge" for latest/edge).
normalize_channel_jq='
def norm: if startswith("latest/") then .[7:] else . end;
'

# Preferred path: the store API reports every architecture for every channel.
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    api_url="https://api.snapcraft.io/v2/snaps/info/${snap_name}"
    if info=$(curl -fsS --connect-timeout 30 --max-time "${snap_api_timeout}" \
            -H 'Snap-Device-Series: 16' \
            -H "Snap-Device-Architecture: ${arch}" "${api_url}" 2>/dev/null) \
            && jq -e . >/dev/null 2>&1 <<<"${info}"; then
        match=$(jq -r --arg ch "${channel}" --arg arch "${arch}" \
            "${normalize_channel_jq}"'
            [ .["channel-map"][]?
              | select(.channel.architecture == $arch)
              | select((.channel.name | norm) == ($ch | norm))
            ] | sort_by(.revision) | last // empty
            | "\(.revision)\t\(.version)"
            ' <<<"${info}" 2>/dev/null || true)
        if [[ -n "${match}" ]]; then
            rev="${match%%$'\t'*}"
            version="${match#*$'\t'}"
            report "yes (${arch})" "revision ${rev} (${version})" yes
            exit 0
        fi

        available_archs=$(jq -r --arg ch "${channel}" \
            "${normalize_channel_jq}"'
            [ .["channel-map"][]?
              | select((.channel.name | norm) == ($ch | norm))
              | .channel.architecture
            ] | unique | join(",")
            ' <<<"${info}" 2>/dev/null || true)
        if [[ -z "${available_archs}" ]]; then
            report "no (${arch})" "channel not published" no
        else
            report "no (${arch})" "published archs: ${available_archs}" no
        fi
        exit 0
    fi
    log "WARN: Snap Store API lookup for ${snap_name} failed; falling back to snap info"
fi

# Fallback: snap info only reports the host architecture. If the caller asks
# about another arch we cannot answer reliably.
host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if ! command -v snap >/dev/null 2>&1; then
    report unknown "snap CLI not installed" unknown
    exit 0
fi
if [[ "${arch}" != "${host_arch}" ]]; then
    report unknown "snap info reports only host arch ${host_arch}; curl+jq unavailable or API lookup failed" unknown
    exit 0
fi

info_timeout_rc=0
info=$(timeout "${snap_cli_timeout}" snap info --verbose "${snap_name}" 2>&1) || info_timeout_rc=$?
if (( info_timeout_rc == 124 )); then
    report unknown "snap info timed out after ${snap_cli_timeout}s" unknown
    exit 0
fi
if [[ -z "${info}" ]] || grep -qE 'error:|no snap found' <<<"${info}"; then
    report no "snap not found in store" no
    exit 0
fi

channel_line=$(awk -v c="${channel}:" '$1 == c { print; exit }' <<<"${info}")
if [[ -z "${channel_line}" ]]; then
    report no "channel not published" no
    exit 0
fi
# snap info prints "--" when the channel exists but has no revision for this
# host's architecture.
if grep -q -- '--' <<<"${channel_line}"; then
    report "no (${arch})" "channel has no revision for host arch ${host_arch}" no
    exit 0
fi

report "yes (${arch})" "channel published for host arch ${host_arch}" yes
