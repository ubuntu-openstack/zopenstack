#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/artifacts"

cat > "${tmp}/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "${SNAP_API_FIXTURE:?SNAP_API_FIXTURE not set}"
EOF
chmod +x "${tmp}/bin/curl"

cat > "${tmp}/api.json" <<'JSON'
{"channel-map":[
  {"channel":{"architecture":"s390x","name":"edge","track":"latest","risk":"edge"},"revision":5844,"version":"v1.37.1"},
  {"channel":{"architecture":"amd64","name":"edge","track":"latest","risk":"edge"},"revision":5848,"version":"v1.37.1"},
  {"channel":{"architecture":"amd64","name":"1/beta","track":"1","risk":"beta"},"revision":1,"version":"1.0"}
]}
JSON

run() {
    PATH="${tmp}/bin:${PATH}" SNAP_API_FIXTURE="${tmp}/api.json" \
        REPO_ROOT="${REPO_ROOT}" RUN_ID=test ARTIFACT_DIR="${tmp}/artifacts" \
        TARGET_ARCH=s390x "${REPO_ROOT}/tools/check_snap_arch.sh" "$@"
}

[[ "$(run k8s latest/edge s390x)" == "yes" ]]
[[ "$(run k8s 1/beta s390x)" == "no" ]]
[[ "$(run k8s nope/edge s390x)" == "no" ]]

grep -q '| snap | k8s | latest/edge | yes (s390x) | revision 5844' \
    "${tmp}/artifacts/arch_report.md"
grep -q '| snap | k8s | 1/beta | no (s390x) | published archs: amd64 |' \
    "${tmp}/artifacts/arch_report.md"
grep -q '| snap | k8s | nope/edge | no (s390x) | channel not published |' \
    "${tmp}/artifacts/arch_report.md"

echo "check_snap_arch: OK"
