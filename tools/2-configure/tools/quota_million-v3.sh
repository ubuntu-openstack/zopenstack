#!/bin/bash -ex
# Set quotas to a ridiculous level for all tenants for testing.

for tenant in $(openstack project list -f value -c ID); do
    openstack quota set --instances 999999 $tenant
    openstack quota set --ram 999999 $tenant
    openstack quota set --floating-ips 999999 $tenant
    openstack quota set --fixed-ips 999999 $tenant
    openstack quota set --cores 999999 $tenant
    openstack quota set --key-pairs 999999 $tenant
    openstack quota set --networks 999999 $tenant
    openstack quota set --subnets 999999 $tenant
    openstack quota set --ports 999999 $tenant
    openstack quota set --routers 999999 $tenant
    openstack quota set --secgroups 999999 $tenant
    openstack quota set --secgroup-rules 999999 $tenant
done

echo " + Setting n-c-c ram and cpu overcommits."
juju config nova-cloud-controller ram-allocation-ratio=999999
juju config nova-cloud-controller cpu-allocation-ratio=999999
