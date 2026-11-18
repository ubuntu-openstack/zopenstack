#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/artifacts"

cat > "${tmp}/bin/juju" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
charm="$2"
case "${charm}" in
    good)
        cat <<'JSON'
{"channels":{"2026.1":{"edge":[{"track":"2026.1","risk":"edge","revision":461,"architectures":["s390x"],"bases":[{"name":"ubuntu","channel":"24.04"}]}]}}}
JSON
        ;;
    wrong-base)
        cat <<'JSON'
{"channels":{"2026.1":{"edge":[{"track":"2026.1","risk":"edge","revision":999,"architectures":["s390x"],"bases":[{"name":"ubuntu","channel":"26.04"}]}]}}}
JSON
        ;;
    no-arch)
        cat <<'JSON'
{"channels":{"2026.1":{"edge":[{"track":"2026.1","risk":"edge","revision":1,"architectures":["amd64"],"bases":[{"name":"ubuntu","channel":"24.04"}]}]}}}
JSON
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "${tmp}/bin/juju"

run() {
    PATH="${tmp}/bin:${PATH}" REPO_ROOT="${REPO_ROOT}" RUN_ID=test \
        ARTIFACT_DIR="${tmp}/artifacts" TARGET_ARCH=s390x \
        "${REPO_ROOT}/tools/check_charm_arch.sh" "$@"
}

[[ "$(run good 2026.1/edge ubuntu@24.04 s390x)" == "yes" ]]
[[ "$(run wrong-base 2026.1/edge ubuntu@24.04 s390x)" == "no" ]]
[[ "$(run no-arch 2026.1/edge ubuntu@24.04 s390x)" == "no" ]]
[[ "$(run missing 2026.1/edge ubuntu@24.04 s390x)" == "unknown" ]]

grep -q '| charm | good | 2026.1/edge | yes (s390x) | revision 461' \
    "${tmp}/artifacts/arch_report.md"
grep -q '| charm | wrong-base | 2026.1/edge | no (s390x) | base ubuntu@24.04' \
    "${tmp}/artifacts/arch_report.md"
grep -q '| charm | no-arch | 2026.1/edge | no (s390x) |' \
    "${tmp}/artifacts/arch_report.md"
grep -q '| charm | missing | 2026.1/edge | unknown |' \
    "${tmp}/artifacts/arch_report.md"

echo "check_charm_arch: OK"
