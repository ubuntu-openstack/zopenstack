#!/usr/bin/env bash
# Build the local charm artifacts required by the hybrid bundles and stage
# them in ./charms:
#
#   cinder-volume-ceph_s390x.charm
#   microceph_s390x.charm
#   rabbitmq-k8s_s390x.charm
#   sunbeam-machine_s390x.charm
#   microcluster-token-distributor_s390x.charm
#
# Sources are cloned fresh into .charm-build/ on every run; an existing
# checkout is never reused. Build on s390x so charmcraft/LXD installs
# host-architecture wheels. The RabbitMQ charm ref is configurable; pair it
# with the OCI image from the same charm track via RABBITMQ_IMAGE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=proxy_env.sh
# Pass an empty argument so this script's own CLI args are not interpreted as
# a proxy manifest path.
source "${SCRIPT_DIR}/proxy_env.sh" ""

# shellcheck source=release_env.sh
source "${SCRIPT_DIR}/release_env.sh"
release="$(openstack_release)"
SUNBEAM_CHARMS_REPO="${SUNBEAM_CHARMS_REPO:-https://opendev.org/openstack/sunbeam-charms.git}"
SUNBEAM_CHARMS_REF="${SUNBEAM_CHARMS_REF:-}"
RABBITMQ_CHARMS_REPO="${RABBITMQ_CHARMS_REPO:-https://github.com/canonical/charm-rabbitmq-k8s.git}"
RABBITMQ_CHARMS_REF="${RABBITMQ_CHARMS_REF:-main}"
MICROCEPH_CHARMS_REPO="${MICROCEPH_CHARMS_REPO:-https://github.com/canonical/charm-microceph.git}"
MICROCEPH_CHARMS_REF="${MICROCEPH_CHARMS_REF:-main}"
MICROCLUSTER_CHARMS_REPO="${MICROCLUSTER_CHARMS_REPO:-https://github.com/canonical/microcluster-token-distributor-operator.git}"
MICROCLUSTER_CHARMS_REF="${MICROCLUSTER_CHARMS_REF:-main}"
CHARM_BUILD_DIR="${CHARM_BUILD_DIR:-${REPO_ROOT}/.charm-build}"
CHARM_OUT_DIR="${CHARM_OUT_DIR:-${REPO_ROOT}/charms}"

DRY_RUN=0

log() {
    printf '[charm-build] %s\n' "$*" >&2
}

fatal() {
    log "FATAL: $*"
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: ./tools/build_local_charms.sh [--dry-run] [--help]

Builds the four s390x hybrid charms from fresh checkouts under .charm-build/
and stages them in ./charms.

Environment overrides:
  CHARM_BUILD_DIR, CHARM_OUT_DIR
  OPENSTACK_SERIES                (hibiscus by default; selects stable/<release> for
                                   sunbeam-charms; gazpacho selects 2026.1)
  SUNBEAM_CHARMS_REPO/REF         (REF overrides the release branch)
  RABBITMQ_CHARMS_REPO/REF       (default ref main; override for another track)
  MICROCEPH_CHARMS_REPO/REF
  MICROCLUSTER_CHARMS_REPO/REF
  PROXY_ENV_FILE, PROXY_URL, NO_PROXY_DEFAULT

Prerequisites on the s390x LPAR:
  sudo snap install charmcraft --classic
  sudo lxd init --auto

This does not build a RabbitMQ rock. Set RABBITMQ_IMAGE to the s390x image
paired with the built charm when running CHARM_SOURCE=hybrid.
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

clone_repo() {
    local url="$1" ref="$2" dest="$3"
    log "cloning ${url} (${ref})"
    if ! run git clone --depth 1 --branch "${ref}" "${url}" "${dest}"; then
        fatal "clone failed for ${url}; allow its host through the proxy or override the matching *_REPO/REF variable"
    fi
}

resolve_sunbeam_ref() {
    if [[ -n "${SUNBEAM_CHARMS_REF}" ]]; then
        return 0
    fi
    SUNBEAM_CHARMS_REF="stable/${release}"
    if (( DRY_RUN )); then
        return 0
    fi
    # The release branch may not exist yet; fall back to main only for the default.
    # An explicitly supplied SUNBEAM_CHARMS_REF is never substituted.
    if ! git ls-remote --exit-code --heads \
            "${SUNBEAM_CHARMS_REPO}" "${SUNBEAM_CHARMS_REF}" >/dev/null 2>&1; then
        log "WARN: ${SUNBEAM_CHARMS_REF} not found; using main (set SUNBEAM_CHARMS_REF to pin)"
        SUNBEAM_CHARMS_REF="main"
    fi
}

find_charm() {
    local dir="$1"
    find "${dir}" -maxdepth 1 -type f -name '*.charm' | head -n 1
}

build_charm() {
    local name="$1" src="$2" platform="$3"
    local out="${CHARM_BUILD_DIR}/out-${name}"
    local charm

    log "packing ${name} for ${platform}"
    if (( DRY_RUN )); then
        run mkdir -p "${out}"
        run charmcraft --project-dir "${src}" pack --platform "${platform}" -o "${out}"
        run cp "${out}/${name}_*.charm" "${CHARM_OUT_DIR}/${name}_s390x.charm"
        return 0
    fi

    mkdir -p "${out}"
    (cd "${src}" && charmcraft pack --platform "${platform}" -o "${out}")
    charm="$(find_charm "${out}")"
    [[ -n "${charm}" ]] || fatal "charmcraft did not produce a .charm for ${name}"
    cp -f "${charm}" "${CHARM_OUT_DIR}/${name}_s390x.charm"
    log "staged ${CHARM_OUT_DIR}/${name}_s390x.charm"
}

ensure_microcluster_platform() {
    local file="$1/charmcraft.yaml"
    if (( DRY_RUN )); then
        log "would ensure ubuntu@26.04:s390x in ${file}"
        return 0
    fi
    if grep -Fq '  ubuntu@26.04:s390x:' "${file}"; then
        return 0
    fi
    log "adding ubuntu@26.04:s390x platform to ${file}"
    python3 - "${file}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "  ubuntu@26.04:s390x:\n"
if needle in text:
    raise SystemExit(0)
if "platforms:\n" not in text:
    raise SystemExit(f"{path}: no top-level platforms: block")
path.write_text(text.replace("platforms:\n", "platforms:\n" + needle, 1), encoding="utf-8")
PY
}

while (( $# > 0 )); do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fatal "unknown argument: $1 (try --help)" ;;
    esac
done

if (( ! DRY_RUN )); then
    [[ "$(dpkg --print-architecture 2>/dev/null || uname -m)" == "s390x" ]] \
        || fatal "build this on s390x; charmcraft installs native wheels"
    command -v git >/dev/null 2>&1 || fatal "git is required"
    command -v charmcraft >/dev/null 2>&1 \
        || fatal "charmcraft is required: sudo snap install charmcraft --classic"
    command -v lxc >/dev/null 2>&1 \
        || fatal "LXD is required: sudo snap install lxd && sudo lxd init --auto"
    lxc info >/dev/null 2>&1 \
        || fatal "LXD is not usable by $(id -un); run: sudo lxd init --auto"

    log "removing previous checkout: ${CHARM_BUILD_DIR}"
    rm -rf "${CHARM_BUILD_DIR}"
    mkdir -p "${CHARM_BUILD_DIR}" "${CHARM_OUT_DIR}"
else
    log "dry run: no checkout will be created"
fi

resolve_sunbeam_ref

clone_repo "${SUNBEAM_CHARMS_REPO}" "${SUNBEAM_CHARMS_REF}" "${CHARM_BUILD_DIR}/sunbeam-charms"
clone_repo "${RABBITMQ_CHARMS_REPO}" "${RABBITMQ_CHARMS_REF}" "${CHARM_BUILD_DIR}/charm-rabbitmq-k8s"
clone_repo "${MICROCEPH_CHARMS_REPO}" "${MICROCEPH_CHARMS_REF}" "${CHARM_BUILD_DIR}/charm-microceph"
clone_repo "${MICROCLUSTER_CHARMS_REPO}" "${MICROCLUSTER_CHARMS_REF}" "${CHARM_BUILD_DIR}/microcluster-token-distributor-operator"

CINDER_CEPH_SRC="${CHARM_BUILD_DIR}/sunbeam-charms/charms/storage/cinder-volume-ceph"
SUNBEAM_MACHINE_SRC="${CHARM_BUILD_DIR}/sunbeam-charms/charms/sunbeam-machine"
RABBITMQ_SRC="${CHARM_BUILD_DIR}/charm-rabbitmq-k8s"
MICROCEPH_SRC="${CHARM_BUILD_DIR}/charm-microceph"
MICROCLUSTER_SRC="${CHARM_BUILD_DIR}/microcluster-token-distributor-operator"

if (( ! DRY_RUN )); then
    grep -Fq '  s390x:' "${CINDER_CEPH_SRC}/charmcraft.yaml" \
        || fatal "${CINDER_CEPH_SRC}/charmcraft.yaml does not declare s390x"
    grep -Fq '  s390x:' "${RABBITMQ_SRC}/charmcraft.yaml" \
        || fatal "${RABBITMQ_SRC}/charmcraft.yaml does not declare s390x"
    grep -Fq 'ubuntu-26.04-s390x:' "${MICROCEPH_SRC}/charmcraft.yaml" \
        || fatal "${MICROCEPH_SRC}/charmcraft.yaml does not declare ubuntu-26.04-s390x"
fi
ensure_microcluster_platform "${MICROCLUSTER_SRC}"

# The sunbeam-machine charm imports ops_sunbeam from the monorepo sibling
# package; include it in the charm payload when building only that subtree.
mkdir -p "${SUNBEAM_MACHINE_SRC}/src"
cp -a "${CHARM_BUILD_DIR}/sunbeam-charms/ops-sunbeam/ops_sunbeam" \
    "${SUNBEAM_MACHINE_SRC}/src/ops_sunbeam"
if (( ! DRY_RUN )); then
    for lib in charms.operator_libs_linux.v0.sysctl \
            charms.tempo_coordinator_k8s.v0.tracing \
            charms.tempo_coordinator_k8s.v0.charm_tracing; do
        (cd "${SUNBEAM_MACHINE_SRC}" && charmcraft fetch-lib "${lib}")
    done
    # ops >=3.9 passes deferred= into the framework event-context hook; the
    # published charm_tracing library predates that keyword.
    python3 - "${SUNBEAM_MACHINE_SRC}/lib/charms/tempo_coordinator_k8s/v0/charm_tracing.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "def wrap_event_context(event_name: str):"
new = "def wrap_event_context(event_name: str, **_kwargs):"
if old not in text:
    raise SystemExit(f"{path}: expected tracing wrapper signature not found")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
fi

build_charm "cinder-volume-ceph" "${CINDER_CEPH_SRC}" "s390x"
build_charm "sunbeam-machine" "${SUNBEAM_MACHINE_SRC}" "s390x"
build_charm "rabbitmq-k8s" "${RABBITMQ_SRC}" "s390x"
build_charm "microceph" "${MICROCEPH_SRC}" "ubuntu-26.04-s390x"
build_charm "microcluster-token-distributor" "${MICROCLUSTER_SRC}" "ubuntu@26.04:s390x"

if (( DRY_RUN )); then
    log "dry run complete"
    exit 0
fi

log "built:"
find "${CHARM_OUT_DIR}" -maxdepth 1 -type f \
    \( -name 'cinder-volume-ceph_s390x.charm' \
       -o -name 'rabbitmq-k8s_s390x.charm' \
       -o -name 'sunbeam-machine_s390x.charm' \
       -o -name 'microceph_s390x.charm' \
       -o -name 'microcluster-token-distributor_s390x.charm' \) \
    -printf '  %p\n' | sort
log "pair the built RabbitMQ charm with the matching image via RABBITMQ_IMAGE"
