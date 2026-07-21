#!/bin/bash -xe

. ../openrcv3_project

for INSTANCE_ID in $(openstack server list --all-projects -f value -c ID);do
    openstack server delete $INSTANCE_ID
done
