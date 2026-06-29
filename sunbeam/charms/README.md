# Local s390x charm staging

`CHARM_SOURCE=local` deploys the Sunbeam charms we build for s390x from this
directory instead of charmhub. Stage the built `.charm` files here before
running phases 03 / 03b in local mode. The files themselves are gitignored
(`charms/*.charm`); only this README is tracked.

## What to put here

Control-plane charms (consumed by `manifests/control-plane-k8s-s390x-local.yaml`):

```
keystone-k8s_s390x.charm
glance-k8s_s390x.charm
nova-k8s_s390x.charm
neutron-k8s_s390x.charm
placement-k8s_s390x.charm
cinder-k8s_s390x.charm
ovn-central-k8s_s390x.charm
ovn-relay-k8s_s390x.charm
```

Machine-plane charms (consumed by `manifests/machine-lpar-s390x-local.yaml`):

```
sunbeam-machine_s390x.charm
cinder-volume_s390x.charm
openstack-hypervisor_s390x.charm
```

## How to get them here

From wherever the charms were built (e.g. the dev box's
`sunbeam-charms-s390x/charms/*/*_s390x.charm`):

```bash
rsync -av --include='*/' \
  --include='keystone-k8s_s390x.charm' --include='glance-k8s_s390x.charm' \
  --include='nova-k8s_s390x.charm' --include='neutron-k8s_s390x.charm' \
  --include='placement-k8s_s390x.charm' --include='cinder-k8s_s390x.charm' \
  --include='ovn-central-k8s_s390x.charm' --include='ovn-relay-k8s_s390x.charm' \
  --include='sunbeam-machine_s390x.charm' --include='cinder-volume_s390x.charm' \
  --include='openstack-hypervisor_s390x.charm' --exclude='*' \
  <build-host>:.../sunbeam-charms-s390x/charms/ ./
# then flatten if needed so the .charm files sit directly in charms/
```

(Or just `scp` each `*_s390x.charm` into this directory — the bundles reference
them by basename, e.g. `./charms/keystone-k8s_s390x.charm`.)

## Before deploying

Edit `manifests/control-plane-k8s-s390x-local.yaml` and replace every
`REPLACE-ME/...:s390x` resource value with the real s390x rock image ref. The
machine bundle has no image resources (snap-based charms).

## Path resolution note

Phases 03/03b `cd` to the repo root before `juju deploy`, so `./charms/...`
resolves here. The `manifests/charms` symlink (→ `../charms`) is a fallback in
case your Juju resolves bundle charm paths relative to the bundle file instead
of the working directory.
