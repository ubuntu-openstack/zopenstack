# Ubuntu OpenStack Testing on z Series (s390x)

This repo contains development-focused test bundles, procedures, tools and scripts -- not intended for production use.

Bundles, scripts and charm configuration options may need to be adjusted for different lab environments.


## Repo Directory Contents
* bundles/*
    * Juju bundles for dev and test deployments
* tools/* 
    * Scripts, tools, glue for testing dev deployments


## Scenarios

### Ubuntu Native LPAR (OpenStack-on-LXD)
A single LPAR running Ubuntu Server natively, with OpenStack deployed via Juju and the OpenStack Charms on the LXD provider.

 - [See: Charm Guide - OpenStack on LXD](http://docs.openstack.org/developer/charm-guide/openstack-on-lxd.html)

### Ubuntu Native Multi-LPAR Testing
Multiple LPARs running Ubuntu Server natively, with OpenStack deployed via Juju and the OpenStack Charmns on the Juju manual provider.

 - [See: README-lpar.md](README-lpar.md)

### z/KVM
z/KVM compute nodes with amd64 control plane.

  - [See: README-zkvm.md](README-zkvm.md)
