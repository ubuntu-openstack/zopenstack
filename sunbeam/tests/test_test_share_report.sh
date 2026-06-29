#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/.status" "${tmp}/tempest"
touch "${tmp}/.status/06_validate_tempest.done"
cat > "${tmp}/tempest/smoke_output.txt" <<'EOF'
Totals
======
Ran: 2 tests
 - Passed: 2
 - Failed: 0
EOF
: > "${tmp}/tempest/failures.txt"
printf '| adminPass | secret | should disappear |\n' > "${tmp}/smoke_instance_launch.txt"
printf 'SSH works\n' > "${tmp}/smoke_instance_ssh.txt"

ARTIFACT_DIR="${tmp}" RUN_ID=test-share-test REPO_ROOT="${REPO_ROOT}" \
    "${REPO_ROOT}/tools/build_test_share_report.sh"

required=(
    README.md catalog_list.txt ceph_tests.txt hypervisor_list.txt image_list.txt
    instance_launch.txt instance_ssh.txt juju_status.txt network_agent_list.txt
    network_extension_list.txt network_list.txt openstack_origin.txt
    tempest_smoke.txt
)
for f in "${required[@]}"; do
    test -f "${tmp}/test-share/${f}"
done
grep -q 'Tempest smoke: PASSED' "${tmp}/test-share/README.md"
grep -q '<redacted>' "${tmp}/test-share/instance_launch.txt"
! grep -q 'secret' "${tmp}/test-share/instance_launch.txt"

echo "test-share report generation: OK"
