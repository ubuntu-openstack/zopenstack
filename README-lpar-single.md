# Ubuntu OpenStack Newton s390x Native LPAR Validation

This validation scenario exercises a basic set of [OpenStack Charms](https://jujucharms.com/u/openstack-charmers)
and [s390x](https://wiki.ubuntu.com/S390X) packages to deploy
OpenStack Newton using [Juju](https://jujucharms.com) 2.0.2 on [Ubuntu Server](https://www.ubuntu.com/server)
16.04.

The Juju bundle, along with deployment procedures and post-deployment
configuration details are documented in the upstream
[OpenStack Charm Guide OpenStack-on-LXD section](http://docs.openstack.org/developer/charm-guide/openstack-on-lxd.html).

This repo contains some [example artifacts](misc/example-newton-single-lpar) from such an exercise:

 - [misc/example-newton-single-lpar/juju_status.txt](misc/example-newton-single-lpar/juju_status.txt)
 - [misc/example-newton-single-lpar/juju_status.yaml](misc/example-newton-single-lpar/juju_status.yaml)
 - [misc/example-newton-single-lpar/misc_output.txt](misc/example-newton-single-lpar/misc_output.txt)
 - [misc/example-newton-single-lpar/misc_perf_output.txt](misc/example-newton-single-lpar/misc_perf_output.txt)
