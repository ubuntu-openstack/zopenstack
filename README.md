# Ubuntu OpenStack Testing on z Series (s390x)

This repo contains development-focused test bundles, procedures, tools and 
scripts -- not intended for production use.

## Repo Directory Contents

Bundles, scripts and charm configuration options may need to be adjusted 
for different lab environments.  All bundles and scripts should be reviewed
prior to use.

 * ``README*``  Procedures and information
 * ``bundles/*``  Juju bundles for dev and test deployments
 * ``tools/*``  Scripts and tools for deploying, configuring and testing dev deployments

## Scenarios

#### Ubuntu Native Single-LPAR
A single LPAR running Ubuntu Server natively, with OpenStack deployed via 
Juju and the OpenStack Charms on the LXD provider.

 - [See: README-lpar-single.md](README-lpar-single.md)
 - [See also: Charm Guide - OpenStack on LXD](http://docs.openstack.org/developer/charm-guide/openstack-on-lxd.html)

#### Ubuntu Native Multi-LPAR
Multiple LPARs running Ubuntu Server natively, with OpenStack deployed via 
Juju and the OpenStack Charmns on the Juju manual provider.

 - [See: README-lpar.md](README-lpar.md)

#### z/KVM
z/KVM compute nodes deployed via Juju and a proxy charm, with amd64 control 
plane deployed via Juju and MAAS.

  - [See: README-zkvm.md](README-zkvm.md)

#### Validating Bundle Yaml Files

When adjusting bundles, be sure to check validity with the following:

```
tox -e lint
```
