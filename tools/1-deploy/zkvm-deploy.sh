#!/bin/bash -ex

# Gather additional tools and repos before deploy
if [[ ! -d "$HOME/tools/juju-wait" ]]; then
    mkdir -vp $HOME/tools/
    git clone https://git.launchpad.net/juju-wait $HOME/tools/juju-wait
fi

# Build a virtualenv containing OpenStack clients
tox -e clients
source .tox/clients/bin/activate

# Customize Bundle
# TODO: munge the bundle yaml to inject maas tags, unit IPs, ssh key, etc.

# Bootstrap, Deploy, and wait for deployment to settle
time juju bootstrap --constraints "arch=amd64 tags=netspaces"
time juju deploy bundles/zkvm/xenial-mitaka-2-machine-control-plane-next.yaml
time timeout 2700 $HOME/tools/juju-wait/juju-wait -v

# Confirm basic OpenStack API health via command line clients
time ./tools/3-test/check-openstack-api-clients.sh

# Configure OpenStack:  Tenant, Network, Images, Security Groups
source novarc
time ./tools/2-configure/configure s390x-zkvm

# Launch and confirm an instance
# TODO
