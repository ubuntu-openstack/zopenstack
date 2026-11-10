#!/usr/bin/env bash
# Report whether an OCI image has a manifest entry for the target arch.
# Usage: check_oci_arch.sh <image-ref> [arch] [used-by]
# arch defaults to ${TARGET_ARCH:-s390x}.
# used-by is optional context (for example the pod/application using the image).
# Writes one row to arch_report.md and prints yes/no/unknown to stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

image="${1:?image ref required, e.g. ghcr.io/canonical/keystone:<tag>}"
arch="${2:-${TARGET_ARCH:-s390x}}"
used_by="${3:-}"

containerd_image_metadata() {
    local ctr_bin="${CTR_BIN:-/snap/k8s/current/bin/ctr}"
    local sock="${CONTAINERD_SOCK:-/run/containerd/containerd.sock}"
    [[ -x "${ctr_bin}" && -S "${sock}" ]] || return 1
    sudo "${ctr_bin}" --address "${sock}" --namespace k8s.io images ls 2>/dev/null \
        | awk -v ref="${image}" '$1 == ref { print $2, $6; exit }'
}

local_image_note=""
containerd_type=""
containerd_platforms=""
read -r containerd_type containerd_platforms <<< "$(containerd_image_metadata || true)" || true
if [[ -n "${containerd_type}" ]]; then
    if [[ "${image}" != *"@sha256:"* \
          && "${containerd_type}" == "application/vnd.oci.image.manifest.v1+json" \
          && "${containerd_platforms}" == "linux/s390x" ]]; then
        # A single-platform tag is what a locally built/imported image looks
        # like. Registry images are normally multi-platform indexes or digest
        # references.
        local_image_note="local image"
    else
        local_image_note="remote image"
    fi
fi

note_with_context() {
    local note="$1"
    if [[ -n "${used_by}" ]]; then
        if [[ -n "${note}" ]]; then
            printf 'used by %s; %s' "${used_by}" "${note}"
        else
            printf 'used by %s' "${used_by}"
        fi
    else
        printf '%s' "${note}"
    fi
}

combine_notes() {
    local first="$1" second="$2"
    if [[ -n "${first}" && -n "${second}" ]]; then
        printf '%s; %s' "${first}" "${second}"
    elif [[ -n "${first}" ]]; then
        printf '%s' "${first}"
    else
        printf '%s' "${second}"
    fi
}

# A bare digest is a local image ID, not a pullable registry reference.
if [[ "${image}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    arch_report_append oci "${image}" "" unknown "$(note_with_context 'local image')"
    echo unknown
    exit 0
fi

if ! command -v skopeo >/dev/null 2>&1; then
    note="${local_image_note:-remote image}"
    arch_report_append oci "${image}" "" unknown "$(note_with_context "${note}")"
    echo unknown
    exit 0
fi

# Fetch raw manifest. For multi-arch images this is the index/manifest-list;
# for single-arch images it's the image manifest itself.
raw=$(timeout "${CHECK_OCI_TIMEOUT:-20}" skopeo inspect --raw "docker://${image}" 2>/dev/null || true)

if [[ -z "${raw}" ]]; then
    note="${local_image_note:-remote image}"
    arch_report_append oci "${image}" "" unknown "$(note_with_context "${note}")"
    echo unknown
    exit 0
fi

# Multi-arch manifest list: look for any manifest with the target architecture.
if grep -q '"manifests"' <<<"${raw}"; then
    if grep -qE "\"architecture\"[[:space:]]*:[[:space:]]*\"${arch}\"" <<<"${raw}"; then
        arch_report_append oci "${image}" "" "yes (${arch})" "$(note_with_context "${local_image_note}")"
        echo yes
    else
        archs=$(grep -oE '"architecture"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"${raw}" \
            | sort -u | tr '\n' ',' | sed 's/,$//' || true)
        arch_report_append oci "${image}" "" "no (${arch})" "$(note_with_context "$(combine_notes "${local_image_note}" "manifests: ${archs}")")"
        echo no
    fi
    exit 0
fi

# Single-arch image: fall back to a non-raw inspect that surfaces Architecture.
single=$(timeout "${CHECK_OCI_TIMEOUT:-20}" skopeo inspect "docker://${image}" 2>/dev/null || true)
img_arch=$(grep -oE '"Architecture"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"${single}" \
    | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
if [[ "${img_arch}" == "${arch}" ]]; then
    arch_report_append oci "${image}" "" "yes (${arch})" "$(note_with_context "$(combine_notes "${local_image_note}" 'single-arch')")"
    echo yes
else
    arch_report_append oci "${image}" "" "no (${arch})" "$(note_with_context "$(combine_notes "${local_image_note}" "single-arch ${img_arch:-unknown}")")"
    echo no
fi
