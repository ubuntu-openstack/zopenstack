# Ubuntu OpenStack Queens s390x Native LPAR Validation

This validation scenario exercises a basic set of [OpenStack Charms](https://jujucharms.com/u/openstack-charmers)
and [s390x](https://wiki.ubuntu.com/S390X) packages to deploy
OpenStack Queens using [Juju](https://jujucharms.com) 2 on [Ubuntu Server](https://www.ubuntu.com/server)
16.04 & 18.04

The bundles for this deployment can be found here: [xenial](bundles/lpar/xenial-queens-stable.yaml) or [bionic](bundles/lpar/bionic-queens-stable.yaml) with deployment instructions [here](README-lpar.md)

This bundle was deployed on S390x Lpars, Configured with 5 Lpars roughtly 20 Processors each and around 49GB Ram. With at least 2 shared disks if not more. 


### Output/Artifacts

The tested artifacts for Xenial & Bionic Queens can be found here:

- [Bionic 18.04 with Queens artifacts](https://github.com/openstack-charmers/test-share/tree/master/s390x/2018-may/bionic-queens-multi-lpar)

- [Xenial 16.04 with Queens artifacts](https://github.com/openstack-charmers/test-share/tree/master/s390x/2018-mar/xenial-queens-multi-lpar)

### Known Issues and Workarounds

[Bug 1713032](https://bugs.launchpad.net/ubuntu/+source/ceph/+bug/1713032)

`[luminous] ceph-mon crashes when it is elected leader (s390x) `
ceph-mon will crash on s390x when it decides it has been elected as the leader - this does not cause a hook error
as ceph-mon does not actually raise an external exception.

Workaround is to disable ceph either in the bundle, or juju remove-application after deploy, which will force
openstack to use local storage.
