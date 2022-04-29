#!/usr/bin/env bash

set -xe

openstack keypair create --public-key ~/.ssh/id_rsa.pub mykey || true

private_network_id="$(openstack network list |grep private | awk '{print $2}')"
openstack server create --wait --image bionic-s390x --flavor m1.small --key-name mykey --nic net-id=$private_network_id my-bionic-s390x
