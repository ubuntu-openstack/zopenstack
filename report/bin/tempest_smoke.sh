#!/usr/bin/env bash

set -xe


tempest.discover \
    --image https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-s390x.img \
    --flavor-min-disk 10 \
    validation.image_ssh_user ubuntu \
    validation.image_alt_ssh_user ubuntu \
    compute.flavor_ref 2 \
    compute.flavor_ref_alt 3 \
    auth.admin_domain_name admin_domain


tempest run --smoke --concurrency 8 --config-file etc/tempest.conf --exclude-list etc/exclude-list.txt
