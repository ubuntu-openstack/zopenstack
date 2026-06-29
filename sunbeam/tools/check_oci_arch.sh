#!/usr/bin/env bash
# Report whether an OCI image has a manifest entry for the target arch.
# Usage: check_oci_arch.sh <image-ref> [arch]
# arch defaults to ${TARGET_ARCH:-s390x}.
# Writes one row to arch_report.md and prints yes/no/unknown to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

image="${1:?image ref required, e.g. ghcr.io/canonical/keystone:2026.1-26.04_edge}"
arch="${2:-${TARGET_ARCH:-s390x}}"

if ! command -v skopeo >/dev/null 2>&1; then
    arch_report_append oci "${image}" "" unknown "skopeo not installed"
    echo unknown
    exit 0
fi

# Fetch raw manifest. For multi-arch images this is the index/manifest-list;
# for single-arch images it's the image manifest itself.
raw=$(skopeo inspect --raw "docker://${image}" 2>/dev/null || true)

if [[ -z "${raw}" ]]; then
    arch_report_append oci "${image}" "" unknown "skopeo inspect failed (unreachable or unauthorized)"
    echo unknown
    exit 0
fi

# Multi-arch manifest list: look for any manifest with the target architecture.
if grep -q '"manifests"' <<<"${raw}"; then
    if grep -qE "\"architecture\"[[:space:]]*:[[:space:]]*\"${arch}\"" <<<"${raw}"; then
        arch_report_append oci "${image}" "" "yes (${arch})" ""
        echo yes
    else
        archs=$(grep -oE '"architecture"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"${raw}" | sort -u | tr '\n' ',' | sed 's/,$//')
        arch_report_append oci "${image}" "" "no (${arch})" "manifests: ${archs}"
        echo no
    fi
    exit 0
fi

# Single-arch image: fall back to a non-raw inspect that surfaces Architecture.
single=$(skopeo inspect "docker://${image}" 2>/dev/null || true)
img_arch=$(grep -oE '"Architecture"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"${single}" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/')
if [[ "${img_arch}" == "${arch}" ]]; then
    arch_report_append oci "${image}" "" "yes (${arch})" "single-arch"
    echo yes
else
    arch_report_append oci "${image}" "" "no (${arch})" "single-arch ${img_arch:-unknown}"
    echo no
fi
