#!/usr/bin/env bash
# Upload and stage s390x local artifacts on a remote LPAR over SSH.
#
# Usage:
#   tools/sideload_s390x_artifacts.sh <command> <user@host> [options]
#
# Commands:
#   upload   Upload the local-artifacts archive as local-artifacts.tar.zst
#   stage    Upload (if --archive is given) and stage charms/snaps/rocks
#   install  Stage and install snaps/import rocks
#   csi      Download/upload/import CSI sidecar images and the rawfile rock
#   all      upload + csi + install
#
# Options:
#   --archive PATH        local-artifacts directory or .tar.zst
#                         (default: newest artifacts/*/local-artifacts-*.tar.zst)
#   --remote-repo PATH    remote repo (default: /home/ubuntu/zopenstack/sunbeam)
#   --remote-archive NAME remote archive name (default: local-artifacts.tar.zst)
#   --no-csi              with all: skip the CSI sidecar step
#   --upload-only         with csi: upload images but do not import them
#   --help
#
# The remote archive name deliberately has no run ID, so the same command works
# for every run. The archive is staged with tools/install_local_artifacts.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "FATAL: $*" >&2
    exit 1
}

cmd="${1:-}"
case "${cmd}" in
    upload|stage|install|csi|all) shift ;;
    --help|-h|"") usage; exit 0 ;;
    *) echo "unknown command: ${cmd}" >&2; usage >&2; exit 2 ;;
esac

target="${1:-}"
[[ -n "${target}" ]] || { usage >&2; exit 2; }
shift

archive=""
remote_repo="/home/ubuntu/zopenstack/sunbeam"
remote_archive="local-artifacts.tar.zst"
do_csi=1
upload_only=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) archive="${2:?--archive needs a value}"; shift 2 ;;
        --remote-repo) remote_repo="${2:?--remote-repo needs a value}"; shift 2 ;;
        --remote-archive) remote_archive="${2:?--remote-archive needs a value}"; shift 2 ;;
        --no-csi) do_csi=0; shift ;;
        --upload-only) upload_only=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v ssh >/dev/null || die "ssh is required"
command -v scp >/dev/null || die "scp is required"

tmp_archive=""
cleanup() {
    if [[ -n "${tmp_archive}" ]]; then
        rm -f "${tmp_archive}"
    fi
}
trap cleanup EXIT

discover_archive() {
    if [[ -z "${archive}" ]]; then
        archive="$(find "${REPO_ROOT}/artifacts" -maxdepth 2 -type f \
            -name 'local-artifacts-*.tar.zst' -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr | head -n1 | cut -d' ' -f2- || true)"
    fi
    [[ -n "${archive}" ]] || die "no local-artifacts archive found; pass --archive"
    [[ -e "${archive}" ]] || die "archive not found: ${archive}"
    if [[ -d "${archive}" ]]; then
        tmp_archive="$(mktemp "${TMPDIR:-/tmp}/local-artifacts.XXXXXX.tar.zst")"
        tar --zstd -cf "${tmp_archive}" -C "$(dirname "${archive}")" "$(basename "${archive}")"
        archive="${tmp_archive}"
    fi
}

upload_archive() {
    discover_archive
    local local_sha remote_sha
    local_sha="$(sha256sum "${archive}" | awk '{print $1}')"
    ssh "${target}" "mkdir -p '${remote_repo}'"
    scp "${archive}" "${target}:${remote_repo}/${remote_archive}"
    remote_sha="$(ssh "${target}" "sha256sum '${remote_repo}/${remote_archive}'" | awk '{print $1}')"
    [[ "${local_sha}" == "${remote_sha}" ]] || die "remote checksum mismatch for ${remote_archive}"
    echo "uploaded ${archive} -> ${target}:${remote_repo}/${remote_archive}"
}

ensure_remote_tool() {
    ssh "${target}" "mkdir -p '${remote_repo}/tools'"
    scp "${SCRIPT_DIR}/install_local_artifacts.sh" "${target}:${remote_repo}/tools/"
}

stage_remote() {
    ensure_remote_tool
    ssh "${target}" "cd '${remote_repo}' && tools/install_local_artifacts.sh '${remote_archive}'"
}

install_remote() {
    ensure_remote_tool
    ssh "${target}" "cd '${remote_repo}' && tools/install_local_artifacts.sh '${remote_archive}' --all"
}

sideload_csi() {
    local out_dir="${SIDELOAD_DIR:-/tmp/s390x-k8s-images}"
    local skopeo_image="${SKOPEO_IMAGE:-quay.io/skopeo/stable:latest}"
    local rawfile_rock="${RAWFILE_ROCK:-}"
    local remote_dir="${REMOTE_CSI_DIR:-/home/ubuntu/builds/s390x-k8s-images}"
    local images=(
        "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0"
        "registry.k8s.io/sig-storage/csi-provisioner:v5.3.0"
    )
    local archives=()
    local image leaf archive remote_archive_path remote_rock raw_ref

    if [[ -z "${rawfile_rock}" && -r "${REPO_ROOT}/rocks/rawfile-localpv_s390x.rock" ]]; then
        rawfile_rock="${REPO_ROOT}/rocks/rawfile-localpv_s390x.rock"
    fi

    if ! command -v skopeo >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        die "skopeo or docker is required on the download machine"
    fi

    mkdir -p "${out_dir}"
    for image in "${images[@]}"; do
        leaf="${image##*/}"
        archive="${out_dir}/${leaf/:/-}-s390x.tar"
        echo "exporting linux/s390x ${image}"
        if command -v skopeo >/dev/null 2>&1; then
            skopeo copy --override-arch s390x \
                "docker://${image}" \
                "oci-archive:${archive}:${image}"
        else
            docker run --rm -v "${out_dir}:/out" "${skopeo_image}" copy \
                --override-arch s390x \
                "docker://${image}" \
                "oci-archive:/out/${archive##*/}:${image}"
        fi
        archives+=("${archive}")
    done

    ssh "${target}" "mkdir -p '${remote_dir}'"
    scp "${archives[@]}" "${target}:${remote_dir}/"
    if [[ -n "${rawfile_rock}" ]]; then
        [[ -r "${rawfile_rock}" ]] || die "RAWFILE_ROCK is not readable: ${rawfile_rock}"
        scp "${rawfile_rock}" "${target}:${remote_dir}/"
    fi

    if (( upload_only )); then
        echo "uploaded CSI images to ${target}:${remote_dir}"
        echo "phase 03 will import them from that directory"
        return 0
    fi

    for archive in "${archives[@]}"; do
        remote_archive_path="${remote_dir}/${archive##*/}"
        ssh "${target}" \
            "sudo /snap/k8s/current/bin/ctr \
              --address /run/containerd/containerd.sock \
              --namespace k8s.io images import '${remote_archive_path}'"
    done

    if [[ -n "${rawfile_rock}" ]]; then
        remote_rock="${remote_dir}/${rawfile_rock##*/}"
        ssh "${target}" "
            set -e
            sudo /snap/k8s/current/bin/ctr \
              --address /run/containerd/containerd.sock \
              --namespace k8s.io images import '${remote_rock}'
            raw_ref=\"\$(sudo /snap/k8s/current/bin/ctr \
              --address /run/containerd/containerd.sock \
              --namespace k8s.io images ls \
              | awk '/import-[0-9]{4}-[0-9]{2}-[0-9]{2}:0\\.8\\.3/ {print \$1; exit}')\"
            if [ -n \"\${raw_ref}\" ]; then
                sudo /snap/k8s/current/bin/ctr \
                  --address /run/containerd/containerd.sock \
                  --namespace k8s.io images tag \"\${raw_ref}\" \
                  docker.io/library/rawfile-localpv:0.8.3-s390x || true
                sudo /snap/k8s/current/bin/ctr \
                  --address /run/containerd/containerd.sock \
                  --namespace k8s.io images tag \"\${raw_ref}\" \
                  docker.io/library/\"\${raw_ref}\" || true
            fi
        "
    fi

    ssh "${target}" \
        "sudo k8s kubectl -n kube-system delete pod \
          -l app.kubernetes.io/name=rawfile-csi --wait=false || true"

    echo "CSI images imported. Verify with:"
    echo "  ssh ${target} sudo k8s kubectl -n kube-system get pods -l app.kubernetes.io/name=rawfile-csi"
}

case "${cmd}" in
    upload) upload_archive ;;
    stage) upload_archive; stage_remote ;;
    install) upload_archive; install_remote ;;
    csi) sideload_csi ;;
    all)
        upload_archive
        if (( do_csi )); then
            sideload_csi
        fi
        install_remote
        ;;
esac
