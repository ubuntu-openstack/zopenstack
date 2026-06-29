#!/usr/bin/env bash
# Download required s390x K8s images on a machine with registry access and
# import them into Canonical K8s containerd on a proxy-restricted LPAR.
set -euo pipefail

TARGET="${1:?usage: $0 ubuntu@LPAR_ADDRESS}"
OUT_DIR="${SIDELOAD_DIR:-/tmp/s390x-k8s-images}"
SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:latest}"
RAWFILE_ROCK="${RAWFILE_ROCK:-}"

images=(
    "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0"
    "registry.k8s.io/sig-storage/csi-provisioner:v5.3.0"
)

command -v docker >/dev/null || {
    echo "FATAL: docker is required on the download machine" >&2
    exit 1
}
command -v ssh >/dev/null || {
    echo "FATAL: ssh is required" >&2
    exit 1
}

mkdir -p "${OUT_DIR}"

archives=()
for image in "${images[@]}"; do
    leaf="${image##*/}"
    archive="${OUT_DIR}/${leaf/:/-}-s390x.tar"
    echo "Exporting linux/s390x ${image}"
    docker run --rm -v "${OUT_DIR}:/out" "${SKOPEO_IMAGE}" copy \
        --override-arch s390x \
        "docker://${image}" \
        "oci-archive:/out/${archive##*/}:${image}"
    archives+=("${archive}")
done

remote_dir="/home/ubuntu/builds/s390x-k8s-images"
ssh "${TARGET}" "mkdir -p '${remote_dir}'"
scp "${archives[@]}" "${TARGET}:${remote_dir}/"
if [[ -n "${RAWFILE_ROCK}" ]]; then
    [[ -r "${RAWFILE_ROCK}" ]] || {
        echo "FATAL: RAWFILE_ROCK is not readable: ${RAWFILE_ROCK}" >&2
        exit 1
    }
    scp "${RAWFILE_ROCK}" "${TARGET}:${remote_dir}/"
fi

for archive in "${archives[@]}"; do
    remote_archive="${remote_dir}/${archive##*/}"
    ssh "${TARGET}" \
        "sudo /snap/k8s/current/bin/ctr \
          --address /run/containerd/containerd.sock \
          --namespace k8s.io images import '${remote_archive}'"
done

if [[ -n "${RAWFILE_ROCK}" ]]; then
    remote_rock="${remote_dir}/${RAWFILE_ROCK##*/}"
    ssh "${TARGET}" "
        set -e
        sudo /snap/k8s/current/bin/ctr \
          --address /run/containerd/containerd.sock \
          --namespace k8s.io images import '${remote_rock}'
        # Rockcraft archives may import with an auto-generated ref such as
        # import-2026-06-26:0.8.3. Kubernetes/containerd can still look for the
        # original normalized ref after tagging, so keep both aliases present.
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

ssh "${TARGET}" \
    "sudo k8s kubectl -n kube-system delete pod \
      -l app.kubernetes.io/name=rawfile-csi --wait=false || true"

echo "Images imported. Verify with:"
echo "  ssh ${TARGET} sudo k8s kubectl -n kube-system get pods -l app.kubernetes.io/name=rawfile-csi"
