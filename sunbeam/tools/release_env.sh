# Canonical OpenStack release selector for the s390x workflow.
# Sourced by lib.sh and the standalone build tools.
#
# OPENSTACK_SERIES is the public switch. It defaults to hibiscus and accepts
# either the codename or the matching Sunbeam release number; the numeric
# release is derived internally for bundle/channel rendering.

OPENSTACK_SERIES="${OPENSTACK_SERIES:-hibiscus}"
case "${OPENSTACK_SERIES,,}" in
    2026.1|gazpacho) OPENSTACK_SERIES="gazpacho" ;;
    2026.2|hibiscus) OPENSTACK_SERIES="hibiscus" ;;
    *) : ;;
esac
export OPENSTACK_SERIES

# Map the public series/codename to the numeric Sunbeam release used by the
# bundle renderers. Unknown values are passed through for future releases.
openstack_release() {
    case "${OPENSTACK_SERIES,,}" in
        gazpacho) echo "2026.1" ;;
        hibiscus) echo "2026.2" ;;
        *) echo "${OPENSTACK_SERIES}" ;;
    esac
}

openstack_series_name() {
    case "${OPENSTACK_SERIES,,}" in
        2026.1) echo "gazpacho" ;;
        2026.2) echo "hibiscus" ;;
        *) echo "${OPENSTACK_SERIES}" ;;
    esac
}

# Ubuntu cloud-image series for the guest image. Override GUEST_SERIES for a
# different image without changing the OpenStack release profile.
guest_series() {
    if [[ -n "${GUEST_SERIES:-}" ]]; then
        echo "${GUEST_SERIES}"
        return
    fi
    case "$(openstack_release)" in
        2026.1) echo "noble" ;;
        2026.2) echo "resolute" ;;
        *) echo "noble" ;;
    esac
}
