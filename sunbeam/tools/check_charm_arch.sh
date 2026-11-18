#!/usr/bin/env bash
# Report whether a Charmhub charm has a revision for the target arch and base.
# Usage: check_charm_arch.sh <charm-name> <channel> [base] [arch]
#   base is e.g. ubuntu@<release>; leave empty to accept any base.
#   arch defaults to ${TARGET_ARCH:-s390x}.
# Writes one row to arch_report.md and prints yes/no/unknown to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

charm="${1:?charm name required}"
channel="${2:?channel required}"
base="${3:-}"
arch="${4:-${TARGET_ARCH:-s390x}}"

if ! command -v juju >/dev/null 2>&1; then
    arch_report_append charm "${charm}" "${channel}" unknown "juju CLI not installed"
    echo unknown
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    arch_report_append charm "${charm}" "${channel}" unknown "jq not installed"
    echo unknown
    exit 0
fi

info=$(juju info "${charm}" --channel "${channel}" --arch "${arch}" --format=json 2>/dev/null || true)
if [[ -z "${info}" ]] || ! jq -e . >/dev/null 2>&1 <<<"${info}"; then
    arch_report_append charm "${charm}" "${channel}" unknown \
        "juju info failed (charm/channel not found or network error)"
    echo unknown
    exit 0
fi

track="${channel%/*}"
risk="${channel#*/}"
if [[ "${track}" == "${channel}" ]]; then
    track="latest"
    risk="${channel}"
fi

base_name=""
base_channel=""
if [[ -n "${base}" ]]; then
    base_name="${base%@*}"
    base_channel="${base#*@}"
fi

match=$(jq -r --arg track "${track}" --arg risk "${risk}" --arg arch "${arch}" \
    --arg bname "${base_name}" --arg bchan "${base_channel}" '
    [ .channels[$track][$risk] // [] | .[]
      | select((.architectures // []) | index($arch))
      | select($bname == "" or any((.bases // [])[]; .name == $bname and .channel == $bchan))
    ] | sort_by(.revision) | last // empty
    | "\(.revision)\t\((.bases // []) | map(.name + "@" + .channel) | join(","))"
    ' <<<"${info}" 2>/dev/null || true)
if [[ -n "${match}" ]]; then
    revision="${match%%$'\t'*}"
    bases="${match#*$'\t'}"
    arch_report_append charm "${charm}" "${channel}" "yes (${arch})" \
        "revision ${revision}; bases ${bases:-unknown}"
    echo yes
    exit 0
fi

available=$(jq -r --arg track "${track}" --arg risk "${risk}" '
    [ .channels[$track][$risk] // [] | .[]
      | "\((.architectures // []) | join(",")):\((.bases // []) | map(.name + "@" + .channel) | join(","))" ]
    | unique | join("; ")
    ' <<<"${info}" 2>/dev/null || true)
note="available ${available:-none}"
[[ -n "${base}" ]] && note="base ${base}; ${note}"
arch_report_append charm "${charm}" "${channel}" "no (${arch})" "${note}"
echo no
