#!/bin/bash -ex
# Expect all to exit zero

. openrc

openstack aggregate list
openstack catalog list

openstack token issue
openstack user list
openstack project list
openstack server list

openstack endpoint list
openstack service list
openstack flavor list
openstack compute service list
openstack compute agent list
openstack image list

openstack stack list

openstack hypervisor show 1
openstack hypervisor show 2
openstack hypervisor list
