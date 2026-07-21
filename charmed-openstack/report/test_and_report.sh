#!/usr/bin/env bash
#LA_TEMP

set -x

rm -rf report/
mkdir report/
bin/remove_all_instances.sh

bin/juju_status.sh > report/juju_status.txt 2>&1
bin/ceph_tests.sh > report/ceph_tests.txt 2>&1
bin/openstack_origin.sh > report/openstack_origin.txt 2>&1

. ../openrcv3_project
bin/tempest_smoke.sh > report/tempest_smoke.txt 2>&1
bin/network_agent_list.sh > report/network_agent_list.txt 2>&1
bin/network_extension_list.sh > report/network_extension_list.txt 2>&1
bin/network_list.sh > report/network_list.txt 2>&1
bin/hypervisor_list.sh > report/hypervisor_list.txt 2>&1
bin/image_list.sh > report/image_list.txt 2>&1
bin/catalog_list.sh > report/catalog_list.txt 2>&1
bin/instance_launch.sh > report/instance_launch.txt 2>&1
bin/instance_ssh.sh > report/instance_ssh.txt 2>&1
