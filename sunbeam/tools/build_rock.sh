#!/usr/bin/env bash
# Build a rockcraft project for s390x, and optionally push it to a registry for
# use as a Juju OCI resource. The default source is canonical/ubuntu-openstack-rocks;
# --repo/--source-dir/--subdir support projects such as rawfile-localpv-rocks.
#
# Examples:
#   ./tools/build_rock.sh rabbitmq --ref <ref> \
#       --push registry.example:5000/rabbitmq:<tag>
#   ./tools/build_rock.sh cinder-volume --ref main
#   ./tools/build_rock.sh nova --ref main --tag docker.io/library/nova:<tag>
#
# A fresh clone is made under .rock-build/ on every run. The default output
# tag is docker.io/library/<rock>:<version>-s390x.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=proxy_env.sh
source "${SCRIPT_DIR}/proxy_env.sh" ""

ROCK_REPO="${ROCK_REPO:-https://github.com/canonical/ubuntu-openstack-rocks.git}"
ROCK_REF="${ROCK_REF:-main}"
ROCK_BUILD_DIR="${ROCK_BUILD_DIR:-${REPO_ROOT}/.rock-build}"
ROCK_SOURCE_DIR="${ROCK_SOURCE_DIR:-}"
ROCK_SUBDIR="${ROCK_SUBDIR:-}"
ROCK_PATCH_ROOT="${ROCK_PATCH_ROOT:-${REPO_ROOT}/patches/rocks}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-}"
PUSH_IMAGE="${PUSH_IMAGE:-}"
SKOPEO_DEST_TLS_VERIFY="${SKOPEO_DEST_TLS_VERIFY:-false}"
DRY_RUN=0
ROCK=""

log() {
    printf '[rock-build] %s\n' "$*" >&2
}

fatal() {
    log "FATAL: $*"
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: ./tools/build_rock.sh <rock> [options]

Build a rockcraft project for s390x. The default source is
canonical/ubuntu-openstack-rocks, cloned fresh into .rock-build/ (gitignored).
Use --repo/--source-dir/--subdir for other layouts such as
rawfile-localpv-rocks. The resulting .rock is usable with Juju as an OCI
resource; either push it to a registry with --push and point an image config at
that ref, or attach the registry ref with `juju attach-resource`. Juju does not
import image layers into containerd.

Arguments:
  <rock>                 directory under rocks/, e.g. rabbitmq, cinder-volume

Options:
  --ref REF              git ref to build (default: main or $ROCK_REF)
  --repo URL             source repository (default canonical GitHub mirror)
  --source-dir DIR       exact checkout path (default <build-dir>/ubuntu-openstack-rocks)
  --subdir DIR           rock project directory within the checkout, relative to source root
                         (default rocks/<rock>; use "." when rockcraft.yaml is at the repo root)
  --patch-root DIR       patch root (default patches/rocks; patches are read from <root>/<rock>)
  --tag TAG              image tag to use/recommend (default <rock>:<version>-s390x)
  --output-image TAG     alias for --tag
  --push REF             push the rock to an OCI registry ref with skopeo
  --build-dir DIR        fresh checkout parent (default .rock-build)
  --dry-run              print commands without cloning or building
  --help                 show this help

Environment:
  ROCK_REPO, ROCK_REF, ROCK_BUILD_DIR, ROCK_SOURCE_DIR, ROCK_SUBDIR,
  ROCK_PATCH_ROOT, OUTPUT_IMAGE, PUSH_IMAGE,
  SKOPEO_DEST_TLS_VERIFY (default false, for local HTTP registries)

Patches under patches/rocks/<rock>/*.patch are applied automatically after the
checkout. A patch that is already applied is accepted; a patch that no longer
applies is fatal.

Prerequisites on the s390x LPAR:
  sudo snap install rockcraft --classic
  sudo lxd init --auto
EOF
}

run() {
    if (( DRY_RUN )); then
        printf '+ ' >&2
        printf '%q ' "$@" >&2
        printf '\n' >&2
    else
        "$@"
    fi
}

apply_rock_patches() {
    local src="$1" patch_dir="$2" patch
    [[ -d "${patch_dir}" ]] || return 0
    while IFS= read -r patch; do
        if git -C "${src}" apply --check "${patch}" 2>/dev/null; then
            log "applying $(basename "${patch}")"
            git -C "${src}" apply "${patch}"
        elif git -C "${src}" apply --reverse --check "${patch}" 2>/dev/null; then
            log "$(basename "${patch}") already applied"
        else
            fatal "$(basename "${patch}") no longer applies to ${src}"
        fi
    done < <(find "${patch_dir}" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
}

while (( $# > 0 )); do
    case "$1" in
        --ref) ROCK_REF="${2:?--ref needs a value}"; shift 2 ;;
        --repo) ROCK_REPO="${2:?--repo needs a value}"; shift 2 ;;
        --source-dir) ROCK_SOURCE_DIR="${2:?--source-dir needs a value}"; shift 2 ;;
        --subdir) ROCK_SUBDIR="${2:?--subdir needs a value}"; shift 2 ;;
        --patch-root) ROCK_PATCH_ROOT="${2:?--patch-root needs a value}"; shift 2 ;;
        --tag|--output-image) OUTPUT_IMAGE="${2:?$1 needs a value}"; shift 2 ;;
        --push) PUSH_IMAGE="${2:?--push needs a registry ref}"; shift 2 ;;
        --build-dir) ROCK_BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        -*) fatal "unknown option: $1 (try --help)" ;;
        *)
            [[ -z "${ROCK}" ]] || fatal "only one rock may be built at a time"
            ROCK="$1"; shift
            ;;
    esac
done

[[ -n "${ROCK}" ]] || { usage; exit 2; }
[[ "${ROCK}" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "invalid rock name: ${ROCK}"
ROCK_SUBDIR="${ROCK_SUBDIR:-rocks/${ROCK}}"
ROCK_SOURCE_DIR="${ROCK_SOURCE_DIR:-${ROCK_BUILD_DIR}/ubuntu-openstack-rocks}"

src="${ROCK_SOURCE_DIR}"
rock_dir="${src}/${ROCK_SUBDIR}"
rockcraft_file="${rock_dir}/rockcraft.yaml"

if (( ! DRY_RUN )); then
    [[ "$(dpkg --print-architecture 2>/dev/null || uname -m)" == "s390x" ]] \
        || fatal "build this on s390x"
    command -v git >/dev/null 2>&1 || fatal "git is required"
    command -v rockcraft >/dev/null 2>&1 \
        || fatal "rockcraft is required: sudo snap install rockcraft --classic"
    command -v lxc >/dev/null 2>&1 \
        || fatal "LXD is required: sudo snap install lxd && sudo lxd init --auto"
    lxc info >/dev/null 2>&1 \
        || fatal "LXD is not usable by $(id -un); run: sudo lxd init --auto"
    if [[ -n "${PUSH_IMAGE}" ]]; then
        command -v skopeo >/dev/null 2>&1 \
            || fatal "skopeo is required for --push (apt install skopeo)"
    fi

    log "removing previous checkout: ${src}"
    rm -rf "${src}"
    mkdir -p "${ROCK_BUILD_DIR}" "$(dirname "${src}")"
fi

log "cloning ${ROCK_REPO} (${ROCK_REF})"
if ! run git clone "${ROCK_REPO}" "${src}"; then
    fatal "clone failed; allow the source host through the proxy or set ROCK_REPO"
fi
if ! run git -C "${src}" checkout --detach "${ROCK_REF}"; then
    fatal "ref ${ROCK_REF} not found in ${ROCK_REPO}"
fi

if (( ! DRY_RUN )); then
    apply_rock_patches "${src}" "${ROCK_PATCH_ROOT}/${ROCK}"
fi

if (( DRY_RUN )); then
    log "would build ${ROCK_SUBDIR}"
    run bash -c "cd '${rock_dir}' && rockcraft pack --use-lxd --platform s390x"
    if [[ -n "${PUSH_IMAGE}" ]]; then
        run skopeo copy --dest-tls-verify="${SKOPEO_DEST_TLS_VERIFY}" \
            "oci-archive:<generated>.rock" "docker://${PUSH_IMAGE}"
    else
        log "would leave the .rock in ${rock_dir}; use --push to publish it"
    fi
    exit 0
fi

[[ -r "${rockcraft_file}" ]] || fatal "missing ${rockcraft_file}"
grep -Eq '(^|[[:space:]-])s390x:' "${rockcraft_file}" \
    || fatal "${rockcraft_file} does not declare s390x"
version="$(awk '/^version:/ {v=$2; gsub(/"/, "", v); print v; exit}' "${rockcraft_file}")"
[[ -n "${version}" ]] || fatal "could not read version from ${rockcraft_file}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-docker.io/library/${ROCK}:${version}-s390x}"

log "building rocks/${ROCK} version ${version} for s390x"
(cd "${rock_dir}" && rockcraft pack --use-lxd --platform s390x)
rock="$(find "${rock_dir}" -maxdepth 1 -type f -name '*.rock' | head -n 1)"
[[ -n "${rock}" ]] || fatal "rockcraft did not produce a .rock"

if [[ -n "${PUSH_IMAGE}" ]]; then
    log "pushing ${rock} to ${PUSH_IMAGE}"
    skopeo copy --dest-tls-verify="${SKOPEO_DEST_TLS_VERIFY}" \
        "oci-archive:${rock}" "docker://${PUSH_IMAGE}" \
        || fatal "skopeo push failed for ${PUSH_IMAGE}"
    IMAGE_REF="${PUSH_IMAGE}"
else
    IMAGE_REF="${OUTPUT_IMAGE}"
fi

log "built ${rock}"
log "OCI image ref: ${IMAGE_REF}"
log "use RABBITMQ_IMAGE=${IMAGE_REF} for the RabbitMQ hybrid bundle, or"
log "attach it with: juju attach-resource <app> <resource>=${IMAGE_REF}"
