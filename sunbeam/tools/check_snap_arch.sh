#!/usr/bin/env bash
# Report whether a snap has a revision for the target arch in the requested channel.
# Usage: check_snap_arch.sh <snap-name> <channel> [arch]
# arch defaults to ${TARGET_ARCH:-s390x}.
# Writes one row to arch_report.md and prints yes/no/unknown to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

snap_name="${1:?snap name required}"
channel="${2:?channel required}"
arch="${3:-${TARGET_ARCH:-s390x}}"

if ! command -v snap >/dev/null 2>&1; then
    arch_report_append snap "${snap_name}" "${channel}" unknown "snap CLI not installed"
    echo unknown
    exit 0
fi

# `snap info --verbose` includes the channel map with architectures.
info=$(snap info --verbose "${snap_name}" 2>&1 || true)

if [[ -z "${info}" ]] || grep -qE 'error:|no snap found' <<<"${info}"; then
    arch_report_append snap "${snap_name}" "${channel}" no "snap not found in store"
    echo no
    exit 0
fi

# The channel map prints lines like:
#   2026.1/edge:    s390x   2026-04-12   (12345)   42MB    -
# Find the line for the requested channel and check for s390x.
channel_line=$(awk -v c="${channel}:" '$1 == c { $1=""; print; exit }' <<<"${info}")

if [[ -z "${channel_line}" ]]; then
    arch_report_append snap "${snap_name}" "${channel}" no "channel not published"
    echo no
    exit 0
fi

if grep -qw "${arch}" <<<"${channel_line}"; then
    arch_report_append snap "${snap_name}" "${channel}" "yes (${arch})" ""
    echo yes
else
    archs=$(grep -oE '[a-z0-9]+(,[a-z0-9]+)+' <<<"${channel_line}" | head -n1)
    arch_report_append snap "${snap_name}" "${channel}" "no (${arch})" "published archs: ${archs:-unknown}"
    echo no
fi
