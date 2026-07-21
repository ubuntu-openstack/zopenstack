#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/phases" "${tmp}/artifacts"

for phase in 00_ok 01_fail 02_must_skip 05_capture_state 06_must_skip 99_collect_artifacts; do
    rc=0
    [[ "${phase}" == "01_fail" ]] && rc=7
    cat > "${tmp}/phases/${phase}.sh" <<EOF
#!/usr/bin/env bash
echo "${phase}" >> "${tmp}/executed"
exit ${rc}
EOF
    chmod +x "${tmp}/phases/${phase}.sh"
done

set +e
PHASES_DIR="${tmp}/phases" ARTIFACT_ROOT="${tmp}/artifacts" \
    "${REPO_ROOT}/run.sh" --run-id driver-test all >"${tmp}/output" 2>&1
rc=$?
set -e

[[ "${rc}" == "7" ]]
cat > "${tmp}/expected" <<'EOF'
00_ok
01_fail
05_capture_state
99_collect_artifacts
EOF
diff -u "${tmp}/expected" "${tmp}/executed"
grep -q "skipping dependent phases" "${tmp}/output"
echo "run.sh failure-path dispatch: OK"
