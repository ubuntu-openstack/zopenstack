#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/artifacts"

cat > "${tmp}/bin/juju" <<'EOF'
#!/usr/bin/env bash
cat "${JUJU_STATUS_FIXTURE:?JUJU_STATUS_FIXTURE not set}"
EOF
chmod +x "${tmp}/bin/juju"

# The wait loops sleep between polls; make the test fast without changing the
# helper code.
cat > "${tmp}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${tmp}/bin/sleep"

cat > "${tmp}/blocked.json" <<'JSON'
{"applications":{
  "nova":{"units":{"nova/0":{
    "juju-status":{"current":"idle"},
    "workload-status":{"current":"active"},
    "subordinates":{"cinder-microceph/0":{
      "juju-status":{"current":"idle"},
      "workload-status":{"current":"blocked"}}}}}},
  "empty":{"units":{}},
  "subord-app":{"subordinate-to":["nova"],"units":{}}
}}
JSON

cat > "${tmp}/good.json" <<'JSON'
{"applications":{
  "nova":{"units":{"nova/0":{
    "juju-status":{"current":"idle"},
    "workload-status":{"current":"active"},
    "subordinates":{"cinder-microceph/0":{
      "juju-status":{"current":"idle"},
      "workload-status":{"current":"active"}}}}}},
  "empty":{"units":{"empty/0":{
    "juju-status":{"current":"idle"},
    "workload-status":{"current":"active"}}}},
  "subord-app":{"subordinate-to":["nova"],"units":{}}
}}
JSON

export REPO_ROOT RUN_ID=test ARTIFACT_DIR="${tmp}/artifacts"
export PATH="${tmp}/bin:${PATH}"
# shellcheck source=../tools/lib.sh
source "${REPO_ROOT}/tools/lib.sh"

export JUJU_STATUS_FIXTURE="${tmp}/blocked.json"
if juju_wait_units_active test:model 1 >/dev/null 2>"${tmp}/active.err"; then
    echo "juju_wait_units_active unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'cinder-microceph/0=blocked' "${tmp}/active.err"
grep -q 'empty=no-units' "${tmp}/active.err"

if juju_wait_settle test:model 1 >/dev/null 2>"${tmp}/settle.err"; then
    echo "juju_wait_settle unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'did not settle' "${tmp}/settle.err"

export JUJU_STATUS_FIXTURE="${tmp}/good.json"
juju_wait_units_active test:model 1
juju_wait_settle test:model 1

echo "wait helpers: OK"
