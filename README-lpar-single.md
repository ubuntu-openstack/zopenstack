# Ubuntu OpenStack Pike s390x Native LPAR Validation

This validation scenario exercises a basic set of [OpenStack Charms](https://jujucharms.com/u/openstack-charmers)
and [s390x](https://wiki.ubuntu.com/S390X) packages to deploy
OpenStack Pike using [Juju](https://jujucharms.com) 2 on [Ubuntu Server](https://www.ubuntu.com/server)
16.04.

The Juju bundle, along with deployment procedures and post-deployment
configuration details are documented in the upstream
[OpenStack Charm Guide OpenStack-on-LXD section](http://docs.openstack.org/developer/charm-guide/openstack-on-lxd.html).

### Example Output/Artifacts
This repo contains some [example artifacts](misc/example-pike-single-lpar) from such an exercise:

 - [misc/example-pike-single-lpar/juju_status.txt](misc/example-pike-single-lpar/juju_status.txt)
 - [misc/example-pike-single-lpar/juju_status.yaml](misc/example-pike-single-lpar/juju_status.yaml)
 - [misc/example-pike-single-lpar/misc_output.txt](misc/example-pike-single-lpar/misc_output.txt)
 - [misc/example-pike-single-lpar/launch_float_ssh.txt](misc/example-pike-single-lpar/launch_float_ssh.txt)
 - [misc/example-pike-single-lpar/network_agent_list.txt](misc/example-pike-single-lpar/network_agent_list.txt)
 - [misc/example-pike-single-lpar/hypervisor_list.txt](imisc/example-pike-single-lpar/hypervisor_list.txt)

### Known Issues and Workarounds

[Bug 1710994](https://bugs.launchpad.net/nova/+bug/1710994)

`Openstack Pike + LXD with ZFS - cannot convert image to raw`

The Pike release of openstack attempts a new image conversion which was not present in Ocata, and does not work 
in zfs, as it uses O_DIRECT calls. Workaround is to use directory storage backend for lxd.

[Bug 1713032](https://bugs.launchpad.net/ubuntu/+source/ceph/+bug/1713032)

`[luminous] ceph-mon crashes when it is elected leader (s390x)`

ceph-mon will crash on s390x when it decides it has been elected as the leader - this does not cause a hook error
as ceph-mon does not actually raise an external exception.

