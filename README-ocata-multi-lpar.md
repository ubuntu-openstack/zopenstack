# Ubuntu OpenStack Ocata s390x Native LPAR Validation

This validation scenario exercises a basic set of [OpenStack Charms](https://jujucharms.com/u/openstack-charmers)
and [s390x](https://wiki.ubuntu.com/S390X) packages to deploy
OpenStack Ocata using [Juju](https://jujucharms.com) 2.1.2 on [Ubuntu Server](https://www.ubuntu.com/server)
16.04.

The bundle for this deployment can be found [here](bundles/lpar/xenial-ocata-stable.yaml) with deployment instructions [here](README-lpar.md)

There are additionally tools to help [add](tools/1-deploy/add-lpars.sh) and [remove](tools/5-teardown/remove-lpars.sh) LPARs to a juju environment.

### Example Output/Artifacts
This repo contains some [example artifacts](misc/example-ocata-multi-lpar) from a validation deployment:

 - [misc/example-ocata-multi-lpar/juju_status.txt](misc/example-ocata-multi-lpar/juju_status.txt)
 - [misc/example-ocata-multi-lpar/juju_status.yaml](misc/example-ocata-multi-lpar/juju_status.yaml)
 - [misc/example-ocata-multi-lpar/misc_output.txt](misc/example-ocata-multi-lpar/misc_output.txt)
 - [misc/example-ocata-multi-lpar/launch_float_ssh.txt](misc/example-ocata-multi-lpar/launch_float_ssh.txt)
 - [misc/example-ocata-multi-lpar/neutron-agent-list.txt](misc/example-ocata-multi-lpar/neutron-agent-list.txt)
 - [misc/example-ocata-multi-lpar/nova-hypervisor-list.txt](misc/example-ocata-multi-lpar/nova-hypervisor-list.txt)
