#!/usr/bin/env bash
# Phase 99: bundle artifacts into a single tarball + emit a summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=99_collect_artifacts
init_phase "${PHASE}"

ARCH="$(target_arch)"
tarball="${ARTIFACT_DIR}/sunbeam-${ARCH}-${RUN_ID}.tar.zst"
tmp_tarball="${ARTIFACT_DIR}.sunbeam-${ARCH}-${RUN_ID}.tar.zst.tmp"
share_tarball="${ARTIFACT_DIR}/test-share-${ARCH}-${RUN_ID}.tar.zst"
share_tmp="${ARTIFACT_DIR}.test-share-${ARCH}-${RUN_ID}.tar.zst.tmp"

log_step "building compact test-share report"
"${SCRIPT_DIR}/../tools/build_test_share_report.sh"

log_step "creating ${tarball}"

# Write outside ARTIFACT_DIR first so tar never archives the file it is creating.
tar --zstd \
    --exclude="$(basename "${tarball}")" \
    -cf "${tmp_tarball}" \
    -C "${ARTIFACT_DIR}" .
mv "${tmp_tarball}" "${tarball}"

log_step "creating ${share_tarball}"
tar --zstd -cf "${share_tmp}" -C "${ARTIFACT_DIR}" test-share
mv "${share_tmp}" "${share_tarball}"

log_step "phase status summary:"
{
    printf '\n%-25s %-10s\n' PHASE STATUS
    printf '%-25s %-10s\n' ----- ------
    for p in 00_check_host 01_install_prereqs 02_prepare_node \
             02b_setup_s390x_cni 03_bootstrap 03b_deploy_machine_plane \
             04_configure 04b_smoke_cloud 05_capture_state \
             06_validate_tempest; do
        if [[ -f "${PHASE_STATUS_DIR}/${p}.failed" ]]; then
            st="FAILED(rc=$(cat "${PHASE_STATUS_DIR}/${p}.failed"))"
        elif [[ -f "${PHASE_STATUS_DIR}/${p}.done" ]]; then
            st=DONE
        else
            st=SKIPPED
        fi
        printf '%-25s %-10s\n' "${p}" "${st}"
    done
    printf '\nfull diagnostic bundle: %s\n' "${tarball}"
    printf 'publishable test-share bundle: %s\n' "${share_tarball}"
} | tee -a "${PHASE_LOG}"

phase_done "${PHASE}"
