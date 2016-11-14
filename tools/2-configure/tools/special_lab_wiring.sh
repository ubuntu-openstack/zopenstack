#!/bin/bash -x
# Special wiring script for the neturon-gateway node, which is
# specific to the network interfaces on the test lab 'netspaces' machines.
#
# To use:  copy into neutron-gateway node, execute with sudo.
#
# May not be necessary in all scenarios.

# Create veth pair
ip link add special-wiring0 type veth peer name special-wiring1

# Add part 0 to OVS bridge used by OpenStack
ovs-vsctl add-port br-ex special-wiring0

# Add part 1 to Linux Bridge created by Juju/MAAS
brctl addif br-eth0 special-wiring1

# Set the status to UP on both parts of the pair
ip link set special-wiring1 up
ip link set special-wiring0 up
