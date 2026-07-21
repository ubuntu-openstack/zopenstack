#!/bin/bash -e
# Download s390x images and add to glance.

: ${WGET_MODE}:=""

# Download images if not already present
mkdir -p ~/images
[ -f ~/images/xenial-server-cloudimg-s390x-disk1.img ] || {
    wget ${WGET_MODE} -O ~/images/xenial-server-cloudimg-s390x-disk1.img http://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-s390x-disk1.img
}

# XXX: s390x cirros image not yet available, required for tempest testing.
#[ -f ~/images/cirros-d150923-ppc64le-disk.img ] || {
#    wget -O ~/images/cirros-???.img http://download.cirros-cloud.net/daily/20150923/cirros-???.img
#}


# Upload glance images to overcloud
glance --os-image-api-version 1 image-create --name="xenial-s390x" --is-public=true --progress \
    --container-format=bare --disk-format=qcow2 < ~/images/xenial-server-cloudimg-s390x-disk1.img

# Set image architecture properties
glance --os-image-api-version 1 image-update --property architecture=s390x xenial-s390x

