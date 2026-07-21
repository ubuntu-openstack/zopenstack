# Ubuntu OpenStack Pike s390x Native LPAR Validation

This validation scenario exercises a basic set of [OpenStack Charms](https://jujucharms.com/u/openstack-charmers)
and [s390x](https://wiki.ubuntu.com/S390X) packages to deploy
OpenStack Pike using [Juju](https://jujucharms.com) 2 on [Ubuntu Server](https://www.ubuntu.com/server)
16.04.

The bundle for this deployment can be found [here](bundles/lpar/xenial-pike-stable.yaml) with deployment instructions [here](README-lpar.md)

There are additionally tools to help [add](tools/1-deploy/add-lpars.sh) and [remove](tools/5-teardown/remove-lpars.sh) LPARs to and from a juju environment.

### Example Output/Artifacts
This repo contains some [example artifacts](misc/example-pike-multi-lpar) from a validation deployment:

 - [misc/example-pike-multi-lpar/juju_status.txt](misc/example-pike-multi-lpar/juju_status.txt)
 - [misc/example-pike-multi-lpar/juju_status.yaml](misc/example-pike-multi-lpar/juju_status.yaml)
 - [misc/example-pike-multi-lpar/misc_output.txt](misc/example-pike-multi-lpar/misc_output.txt)
 - [misc/example-pike-multi-lpar/launch_float_ssh.txt](misc/example-pike-multi-lpar/launch_float_ssh.txt)
 - [misc/example-pike-multi-lpar/neutron_agent_list.txt](misc/example-pike-multi-lpar/neutron_agent_list.txt)
 - [misc/example-pike-multi-lpar/hypervisor_list.txt](misc/example-pike-multi-lpar/hypervisor_list.txt)

### Known Issues and Workarounds

[Bug 1713032](https://bugs.launchpad.net/ubuntu/+source/ceph/+bug/1713032)

`[luminous] ceph-mon crashes when it is elected leader (s390x) `
ceph-mon will crash on s390x when it decides it has been elected as the leader - this does not cause a hook error
as ceph-mon does not actually raise an external exception.

Workaround is to disable ceph either in the bundle, or juju remove-application after deploy, which will force
openstack to use local storage.
