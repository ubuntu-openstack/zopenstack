#!/bin/bash -e
# Download s390x images and add to glance via openstack cli

# Download images if not already present
mkdir -p ~/images
[ -f ~/images/xenial-server-cloudimg-s390x-disk1.img ] || {
    wget -O ~/images/xenial-server-cloudimg-s390x-disk1.img http://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-s390x-disk1.img
}

# Create images
openstack image show xenial-s390x ||\
	  openstack image create --public --container-format bare --disk-format qcow2 --file ~/images/xenial-server-cloudimg-s390x-disk1.img xenial-s390x
