#!/usr/bin/env bash
# Build a compact, human-reviewable report modelled on
# openstack-charmers/test-share's s390x validation directories.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

REPORT_DIR="${ARTIFACT_DIR}/test-share"
CONTROLLER="${JUJU_CONTROLLER:-sunbeam-controller}"
K8S_MODEL="${K8S_MODEL:-openstack}"
MACHINE_MODEL="${MACHINE_MODEL:-machines}"
OPENRC="${ARTIFACT_DIR}/cloud-admin-openrc"
OSC="${ARTIFACT_DIR}/.osc-venv/bin/openstack"
rm -rf "${REPORT_DIR}"
mkdir -p "${REPORT_DIR}"

if [[ ! -x "${OSC}" ]]; then
    if [[ -x "${ARTIFACT_DIR}/tempest/.venv/bin/openstack" ]]; then
        OSC="${ARTIFACT_DIR}/tempest/.venv/bin/openstack"
    else
        OSC="$(command -v openstack || true)"
    fi
fi

expected_files=(
    README.md
    catalog_list.txt
    ceph_tests.txt
    hypervisor_list.txt
    image_list.txt
    instance_launch.txt
    instance_ssh.txt
    juju_status.txt
    network_agent_list.txt
    network_extension_list.txt
    network_list.txt
    openstack_origin.txt
    tempest_smoke.txt
)

capture() {
    local output="$1"
    shift
    {
        printf '+'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } > "${REPORT_DIR}/${output}" 2>&1 || true
}

capture_openstack() {
    local output="$1"
    shift
    {
        printf '+ openstack'
        printf ' %q' "$@"
        printf '\n'
        "${OSC}" "$@"
    } > "${REPORT_DIR}/${output}" 2>&1 || true
}

print_trace_value() {
    local name="$1"
    local value="${2:-}"
    if [[ -z "${value}" || "${value}" == "{}" ]]; then
        echo "+ ${name}='{}'"
    elif [[ "${value}" =~ ^[A-Za-z0-9._:/@+-]+$ ]]; then
        echo "+ ${name}=${value}"
    else
        printf '+ %s=%q\n' "${name}" "${value}"
    fi
}

capture_juju_status() {
    {
        echo "+ juju status"
        juju status -m "${CONTROLLER}:${K8S_MODEL}" --relations --color=false 2>&1 || true
        echo
        echo "+ juju status -m ${CONTROLLER}:${MACHINE_MODEL}"
        juju status -m "${CONTROLLER}:${MACHINE_MODEL}" --relations --color=false 2>&1 || true
    } > "${REPORT_DIR}/juju_status.txt"
}

series_name() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${VERSION_ID:-}" in
            24.04) echo noble ;;
            26.04) echo resolute ;;
            *) echo "${VERSION_CODENAME:-ubuntu}" ;;
        esac
    else
        echo ubuntu
    fi
}

openstack_series_name() {
    echo "${OPENSTACK_SERIES:-gazpacho}"
}

tempest_result_text() {
    if [[ -s "${ARTIFACT_DIR}/tempest/failures.txt" ]]; then
        echo "The Tempest smoke tests detected the following failures:"
        echo
        sed 's/^/- /' "${ARTIFACT_DIR}/tempest/failures.txt"
    elif [[ -f "${ARTIFACT_DIR}/.status/06_validate_tempest.done" ]]; then
        echo "All selected Tempest smoke tests passed."
    else
        echo "Tempest smoke did not complete; see tempest_smoke.txt and the full diagnostic archive."
    fi
}

{
    ubuntu_series="$(series_name)"
    openstack_series="$(openstack_series_name)"
    echo "Tempest validation of OpenStack ${ubuntu_series}-${openstack_series} (OVN) on $(target_arch)."
    echo
    tempest_result_text
    echo
    echo "Tests were run with the Tempest option \`--serial\` to force sequentially-run tests due to system resource constraints."
    if [[ -r "${TEST_SHARE_NOTES_FILE:-}" ]]; then
        echo
        cat "${TEST_SHARE_NOTES_FILE}"
    fi
} > "${REPORT_DIR}/README.md"

capture_juju_status

if [[ -r "${OPENRC}" && -x "${OSC}" ]]; then
    (
        # shellcheck disable=SC1090
        source "${OPENRC}"
        capture_openstack catalog_list.txt catalog list
        capture_openstack hypervisor_list.txt hypervisor list
        capture_openstack image_list.txt image list
        capture_openstack network_list.txt network list
        capture_openstack network_agent_list.txt network agent list
        capture_openstack network_extension_list.txt extension list --network
    )
else
    for f in catalog_list hypervisor_list image_list network_list \
             network_agent_list network_extension_list; do
        echo "OpenStack client/openrc unavailable; phase 04 did not complete." \
            > "${REPORT_DIR}/${f}.txt"
    done
fi

{
    echo "# Sunbeam/OpenStack provenance"
    echo
    echo "This file replaces the legacy charm 'openstack-origin' dump. Sunbeam"
    echo "charms generally do not expose an 'openstack-origin' config option, so"
    echo "the useful provenance is the selected Ubuntu/OpenStack series, Juju charm"
    echo "channels/revisions/bases, and machine-side snap/package evidence."
    echo "Operational status is intentionally left to juju_status.txt."
    echo
    echo "## Validation target"
    echo
    echo "ubuntu-series=$(series_name)"
    echo "openstack-series=$(openstack_series_name)"
    echo "target-arch=$(target_arch)"
    echo "run-id=${RUN_ID}"
    echo "charm-source=${CHARM_SOURCE:-charmhub}"
    echo
    echo "## Juju charm revisions"
    echo
    for model in "${K8S_MODEL}" "${MACHINE_MODEL}"; do
        echo "+ juju status -m ${CONTROLLER}:${model} --format=json"
        juju status -m "${CONTROLLER}:${model}" --format=json 2>/dev/null |
            jq -r --arg model "${model}" '
                def origin:
                    if (.["charm-origin"] | type) == "object" then .["charm-origin"] else {} end;
                def base:
                    if .base then ((.base.name // "-") + "@" + (.base.channel // "-"))
                    elif origin.base then ((origin.base.name // "-") + "@" + (origin.base.channel // "-"))
                    else "-" end;
                (.applications // {}) | to_entries[] |
                [
                    $model,
                    .key,
                    (.value["charm-name"] // .value.charm // "-"),
                    (.value.channel // .value["charm-channel"] // (.value | origin.channel) // "-"),
                    ((.value["charm-rev"] // .value.revision // (.value | origin.revision) // "-") | tostring),
                    (.value | base)
                ] | @tsv
            ' 2>/dev/null |
            awk -F '\t' 'BEGIN {
                    printf "%-10s %-22s %-28s %-14s %-8s %-12s\n", "MODEL", "APP", "CHARM", "CHANNEL", "REV", "BASE"
                    printf "%-10s %-22s %-28s %-14s %-8s %-12s\n", "-----", "---", "-----", "-------", "---", "----"
                }
                {
                    printf "%-10s %-22s %-28s %-14s %-8s %-12s\n", $1, $2, $3, $4, $5, $6
                }' || true
        echo
    done
    echo "## Machine-side snaps"
    echo
    echo "+ snap list juju k8s openstack-hypervisor cinder-volume microceph"
    snap list juju k8s openstack-hypervisor cinder-volume microceph 2>&1 || true
    echo
    echo "## Machine-side OpenStack runtime evidence"
    echo
    echo "+ readlink -f /snap/openstack-hypervisor/current"
    readlink -f /snap/openstack-hypervisor/current 2>&1 || true
    echo
    echo "+ zgrep -m1 '^nova (' /snap/openstack-hypervisor/current/usr/share/doc/python3-nova/changelog.Debian.gz"
    zgrep -m1 '^nova (' /snap/openstack-hypervisor/current/usr/share/doc/python3-nova/changelog.Debian.gz 2>&1 || true
    echo
    echo "+ test -x /snap/openstack-hypervisor/current/usr/bin/qemu-system-s390x"
    if test -x /snap/openstack-hypervisor/current/usr/bin/qemu-system-s390x; then
        echo "qemu-system-s390x=present"
    else
        echo "qemu-system-s390x=missing"
    fi
} > "${REPORT_DIR}/openstack_origin.txt"

{
    for args in "osd lspools" "osd df"; do
        echo "+ sudo microceph.ceph ${args}"
        # shellcheck disable=SC2086
        sudo microceph.ceph ${args} 2>&1 || true
        echo
    done
    mapfile -t ceph_pools < <(
        sudo microceph.ceph osd lspools 2>/dev/null |
            awk '{$1=""; sub(/^ /, ""); print}' |
            grep -vE '^(\.mgr)?$' || true
    )
    for pool in "${ceph_pools[@]}"; do
        echo "+ sudo microceph.rados -p ${pool} ls"
        sudo microceph.rados -p "${pool}" ls 2>&1 || \
            sudo microceph.rbd -p "${pool}" ls 2>&1 || true
        echo
    done
} > "${REPORT_DIR}/ceph_tests.txt"

if [[ -r "${ARTIFACT_DIR}/smoke_instance_launch.txt" ]]; then
    sed -E 's/(adminPass[[:space:]]*\|[[:space:]]*).*/\1<redacted> |/' \
        "${ARTIFACT_DIR}/smoke_instance_launch.txt" \
        > "${REPORT_DIR}/instance_launch.txt"
else
    echo "Instance launch proof unavailable; phase 04b did not complete." \
        > "${REPORT_DIR}/instance_launch.txt"
fi
cp -f "${ARTIFACT_DIR}/smoke_instance_ssh.txt" \
    "${REPORT_DIR}/instance_ssh.txt" 2>/dev/null || \
    echo "Instance SSH proof unavailable; phase 04b did not complete." \
        > "${REPORT_DIR}/instance_ssh.txt"
cp -f "${ARTIFACT_DIR}/tempest/smoke_output.txt" \
    "${REPORT_DIR}/tempest_smoke.txt" 2>/dev/null || \
    echo "Tempest output unavailable; phase 06 did not complete." \
        > "${REPORT_DIR}/tempest_smoke.txt"

for f in "${expected_files[@]}"; do
    touch "${REPORT_DIR}/${f}"
done

log "test-share report: ${REPORT_DIR}"
