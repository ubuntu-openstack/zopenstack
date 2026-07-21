#!/usr/bin/env bash
# Phase 06: run Tempest against the deployed Sunbeam cloud, zopenstack-style.
#
# Workflow (adapted from ubuntu-openstack/zopenstack for Sunbeam):
#   1. Use the openrc Sunbeam produced (cloud-admin-openrc from phase 04).
#   2. Clone upstream openstack/tempest.
#   3. Use python-tempestconf (upstream, deployment-agnostic) to generate
#      tempest.conf from the live cloud's catalog.
#   4. Drop in the vendor/zopenstack/exclude-list.txt.
#   5. Run upstream smoke tests directly with `tempest run --smoke --serial`
#      by default. Set TEMPEST_USE_TOX=1 to exercise upstream tox explicitly.
#      Set TEMPEST_PLUGIN_MODE=distro to run the distro Tempest + plugin set
#      used by the legacy charmed-openstack validation reports.
#   7. Save FAILED lines into failures.txt.
#   8. Dump diagnostic state (openstack CLI: catalog, image list, etc.) into
#      a tempest_report/ directory.
#
# Single-test re-runs are not driven by this phase; use
# tools/run_tempest_test.sh once setup is complete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=06_validate_tempest
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

OPENRC="${ARTIFACT_DIR}/cloud-admin-openrc"
if [[ ! -r "${OPENRC}" ]]; then
    log "FATAL: ${OPENRC} not found. Phase 04 (configure) must succeed first."
    exit 1
fi

TEMPEST_DIR="${ARTIFACT_DIR}/tempest"
REPORT_DIR="${ARTIFACT_DIR}/tempest_report"
mkdir -p "${TEMPEST_DIR}" "${REPORT_DIR}"

# Guest image for discover-tempest-config. Overridable.
ARCH="$(target_arch)"
TEMPEST_IMAGE_URL="${TEMPEST_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ARCH}.img}"

EXCLUDE_LIST="${REPO_ROOT}/vendor/zopenstack/exclude-list.txt"
if [[ ! -s "${EXCLUDE_LIST}" ]]; then
    log "WARN: ${EXCLUDE_LIST} missing or empty; tempest will run with no exclusions"
fi

# 1. Required CLI tooling. Use distro cryptography inside the tempestconf venv
# on s390x: PyPI may not have a usable wheel for the newest cryptography, which
# makes pip try to bootstrap Rust from static.rust-lang.org. That is slow and is
# commonly blocked by internal proxies.
log_step "ensuring python3-venv, openstack client, and Python crypto deps are available"
run_logged "apt update" -- sudo apt-get update || \
    log "WARN: apt-get update failed; package installs may fail"
if ! command -v python3 >/dev/null 2>&1; then
    log "FATAL: python3 missing"
    exit 1
fi
if ! dpkg -s python3-venv >/dev/null 2>&1; then
    run_logged "apt install python3-venv" -- sudo apt-get install -y python3-venv
fi
missing_tempestconf_debs=()
for pkg in python3-cryptography python3-cffi python3-openstackclient; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
        missing_tempestconf_debs+=("${pkg}")
    fi
done
if ((${#missing_tempestconf_debs[@]})); then
    run_logged "apt install tempestconf python deps" -- \
        sudo apt-get install -y "${missing_tempestconf_debs[@]}"
fi
if [[ "${TEMPEST_PLUGIN_MODE:-upstream}" == "distro" ]]; then
    run_logged "apt install distro tempest plugins" -- sudo apt-get install -y \
        tempest \
        barbican-tempest-plugin \
        cinder-tempest-plugin \
        designate-tempest-plugin \
        glance-tempest-plugin \
        heat-tempest-plugin \
        ironic-tempest-plugin \
        keystone-tempest-plugin \
        magnum-tempest-plugin \
        manila-tempest-plugin \
        neutron-tempest-plugin \
        octavia-tempest-plugin \
        telemetry-tempest-plugin \
        watcher-tempest-plugin
fi

# 2. Clone upstream tempest (if not already cloned).
if [[ ! -d "${TEMPEST_DIR}/tempest/.git" ]]; then
    log_step "cloning upstream openstack/tempest"
    run_logged "git clone tempest" -- \
        git clone https://github.com/openstack/tempest "${TEMPEST_DIR}/tempest"
else
    log "tempest repo already present; using existing checkout"
fi

# 3. Set up a venv with python-tempestconf + openstack client.
venv="${TEMPEST_DIR}/.venv"
if [[ ! -x "${venv}/bin/discover-tempest-config" ]]; then
    log_step "creating tempestconf venv at ${venv}"
    rm -rf "${venv}"
    python3 -m venv --system-site-packages "${venv}"
    "${venv}/bin/pip" install --upgrade pip
    "${venv}/bin/pip" install python-tempestconf python-openstackclient
fi
if [[ -x "${venv}/bin/openstack" ]]; then
    OSC="${venv}/bin/openstack"
else
    OSC="$(command -v openstack || true)"
fi
if [[ -z "${OSC}" ]]; then
    log "FATAL: openstack client missing from venv and PATH"
    exit 1
fi

# 4. Generate tempest.conf with python-tempestconf, against the live cloud.
# discover-tempest-config talks to keystone/nova/glance/neutron via the
# openrc to figure out what's enabled and writes a working tempest.conf.
log_step "generating tempest.conf via python-tempestconf"
(
    # shellcheck disable=SC1090
    source "${OPENRC}"
    cd "${TEMPEST_DIR}/tempest"
    tempestconf_args=(
        --out "${TEMPEST_DIR}/tempest/etc/tempest.conf"
        --create
        --image "${TEMPEST_IMAGE_URL}"
        --network-id "$("${OSC}" network show external-network -f value -c id 2>/dev/null || true)"
    )
    if [[ "${TEMPESTCONF_DEBUG:-0}" == "1" ]]; then
        tempestconf_args+=(--debug)
    fi
    # Generate then drop into etc/.
    "${venv}/bin/discover-tempest-config" "${tempestconf_args[@]}"
) 2>&1 | tee "${TEMPEST_DIR}/tempestconf.log" || \
    log "WARN: discover-tempest-config returned non-zero; check ${TEMPEST_DIR}/tempestconf.log"

# python-tempestconf defaults to 1 GiB test flavors and volumes. Ubuntu Noble's
# cloud image has a 3.5 GiB virtual size, so those defaults make every
# server/boot-from-volume smoke test fail before it reaches the hypervisor.
# Reuse the phase-04 flavors and size test volumes to fit the selected image.
log_step "sizing Tempest resources for the guest image"
(
    # shellcheck disable=SC1090
    source "${OPENRC}"
    flavor_ref=$("${OSC}" flavor show m1.tiny -f value -c id)
    flavor_ref_alt=$("${OSC}" flavor show m1.small -f value -c id)
    "${venv}/bin/python" - \
        "${TEMPEST_DIR}/tempest/etc/tempest.conf" \
        "${flavor_ref}" "${flavor_ref_alt}" \
        "${TEMPEST_VOLUME_SIZE_GB:-4}" \
        "${TEMPEST_IMAGE_SSH_USER:-ubuntu}" \
        "${TEMPEST_RUN_VALIDATION:-false}" <<'PY'
import configparser
import sys

(
    path,
    flavor_ref,
    flavor_ref_alt,
    volume_size,
    image_ssh_user,
    run_validation,
) = sys.argv[1:]
config = configparser.RawConfigParser()
config.read(path)
for section in ("compute", "volume", "validation"):
    if not config.has_section(section):
        config.add_section(section)
config.set("compute", "flavor_ref", flavor_ref)
config.set("compute", "flavor_ref_alt", flavor_ref_alt)
config.set("volume", "volume_size", volume_size)
config.set("validation", "image_ssh_user", image_ssh_user)
config.set("validation", "run_validation", run_validation)
with open(path, "w", encoding="utf-8") as stream:
    config.write(stream)
PY
)

# 5. Drop in exclude-list and accounts (use upstream tempest's default accounts shape).
if [[ -s "${EXCLUDE_LIST}" ]]; then
    cp "${EXCLUDE_LIST}" "${TEMPEST_DIR}/tempest/exclude-list.txt"
    log "exclude-list copied to ${TEMPEST_DIR}/tempest/exclude-list.txt"
fi

# 6. Run smoke. Direct `tempest run` is the default because upstream tox pulls
# OpenStack upper-constraints over HTTPS, which is often blocked by internal
# proxies on validation hosts. Set TEMPEST_USE_TOX=1 to exercise tox explicitly.
smoke_out="${TEMPEST_DIR}/smoke_output.txt"
rc=0
(
    if [[ "${TEMPEST_PLUGIN_MODE:-upstream}" == "distro" ]]; then
        # Resolute currently carries a neutron-tempest-plugin module that still
        # calls testtools.try_import during discovery, while Resolute's
        # testtools package no longer provides that helper. Discovery imports
        # every plugin module before Tempest can apply an exclude-list, so keep
        # the workaround local to this Tempest process rather than editing
        # distro files on the validation host.
        tempest_compat_dir="${TEMPEST_DIR}/python-compat"
        mkdir -p "${tempest_compat_dir}"
        cat > "${tempest_compat_dir}/sitecustomize.py" <<'PY'
"""Small Tempest-only compatibility shims for distro plugin discovery."""
import importlib

try:
    import testtools
except Exception:
    testtools = None

if testtools is not None and not hasattr(testtools, "try_import"):
    def try_import(import_str, alternative=None, error_callback=None):
        try:
            return importlib.import_module(import_str)
        except ImportError as exc:
            if error_callback is not None:
                error_callback(exc)
            return alternative

    testtools.try_import = try_import
PY
        distro_workspace="${TEMPEST_DIR}/distro-workspace"
        rm -rf "${distro_workspace}"
        /usr/bin/tempest init "${distro_workspace}"
        cp "${TEMPEST_DIR}/tempest/etc/tempest.conf" "${distro_workspace}/etc/tempest.conf"
        if [[ -s "${TEMPEST_DIR}/tempest/exclude-list.txt" ]]; then
            cp "${TEMPEST_DIR}/tempest/exclude-list.txt" "${distro_workspace}/etc/exclude-list.txt"
            TEMPEST_FLAGS="--exclude-list etc/exclude-list.txt"
        else
            TEMPEST_FLAGS=""
        fi
        cd "${distro_workspace}"
        log_step "distro tempest run --smoke with plugins -> ${smoke_out}"
        PYTHONPATH="${tempest_compat_dir}${PYTHONPATH:+:${PYTHONPATH}}" \
            /usr/bin/tempest run \
            --config-file etc/tempest.conf \
            --smoke \
            --serial \
            ${TEMPEST_FLAGS} 2>&1 | tee "${smoke_out}"
    else
        cd "${TEMPEST_DIR}/tempest"
        if [[ -s exclude-list.txt ]]; then
            TEMPEST_FLAGS="--exclude-list exclude-list.txt"
        else
            TEMPEST_FLAGS=""
        fi
        if [[ "${TEMPEST_USE_TOX:-0}" == "1" ]]; then
            log_step "tox -e smoke --notest (bootstrap tempest tox venv)"
            run_logged "tox -e smoke --notest" -- \
                env -i HOME="${HOME}" PATH="${PATH}" \
                    http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
                    HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
                    NO_PROXY="${NO_PROXY:-}" no_proxy="${no_proxy:-}" \
                    tox -e smoke --notest
            log_step "tox -e smoke (full smoke run) -> ${smoke_out}"
            tox -e smoke -- ${TEMPEST_FLAGS} 2>&1 | tee "${smoke_out}"
        else
            log_step "tempest run --smoke (direct venv run) -> ${smoke_out}"
            "${venv}/bin/tempest" run \
                --config-file "${TEMPEST_DIR}/tempest/etc/tempest.conf" \
                --smoke \
                --serial \
                ${TEMPEST_FLAGS} 2>&1 | tee "${smoke_out}"
        fi
    fi
) || rc=$?

# 7. Extract FAILED lines.
failures="${TEMPEST_DIR}/failures.txt"
grep -E '^FAILED|\{.*\}.*FAILED' "${smoke_out}" > "${failures}" || true
log_step "failures: $(wc -l < "${failures}") (see ${failures})"

# 8. Sidecar diagnostic dumps (zopenstack-style report/), Sunbeam-flavor.
log_step "writing diagnostic dumps to ${REPORT_DIR}"
(
    # shellcheck disable=SC1090
    source "${OPENRC}"
    set +e
    "${OSC}" catalog list                > "${REPORT_DIR}/catalog_list.txt"      2>&1
    "${OSC}" endpoint list               > "${REPORT_DIR}/endpoint_list.txt"     2>&1
    "${OSC}" image list                  > "${REPORT_DIR}/image_list.txt"        2>&1
    "${OSC}" network list                > "${REPORT_DIR}/network_list.txt"      2>&1
    "${OSC}" network agent list          > "${REPORT_DIR}/network_agent_list.txt" 2>&1
    "${OSC}" hypervisor list             > "${REPORT_DIR}/hypervisor_list.txt"   2>&1
    "${OSC}" server list --all-projects  > "${REPORT_DIR}/server_list.txt"       2>&1
    "${OSC}" volume list --all-projects  > "${REPORT_DIR}/volume_list.txt"       2>&1
    _ctrl="${JUJU_CONTROLLER:-sunbeam-controller}"
    juju status -m "${_ctrl}:openstack" --format=yaml > "${REPORT_DIR}/juju_status_openstack.txt" 2>&1
    juju status -m "${_ctrl}:machines"  --format=yaml > "${REPORT_DIR}/juju_status_machines.txt"  2>&1
)

if (( rc != 0 )); then
    log "tempest smoke returned ${rc}; see ${smoke_out} and ${failures}"
    echo "${rc}" > "${ARTIFACT_DIR}/.status/${PHASE}.failed"
else
    phase_done "${PHASE}"
fi

log_step "phase ${PHASE} complete"
log "NEXT: re-run any single failing test with:"
log "  ./tools/run_tempest_test.sh '<test-regex>'"
log "e.g. ./tools/run_tempest_test.sh 'test_dashboard_basic_ops.TestDashboardBasicOps.test_basic_scenario'"
exit "${rc}"
