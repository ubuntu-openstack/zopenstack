# vendor/zopenstack/

Pinned snapshot of selected files from [ubuntu-openstack/zopenstack](https://github.com/ubuntu-openstack/zopenstack):

- Upstream: [github.com/ubuntu-openstack/zopenstack](https://github.com/ubuntu-openstack/zopenstack)
- Branch: `main`
- Commit pinned in [`COMMIT`](COMMIT)

## Important caveat

zopenstack targets **traditional Juju-machine charmed OpenStack** (e.g. the
`keystone`, `glance`, `nova-compute` machine charms). This project deploys
**Sunbeam**, which uses K8s charms (`keystone-k8s`, `glance-k8s`, etc.) with
different endpoint shapes (LoadBalancer through traefik instead of unit
private-addresses) and a different bootstrap path. So we **do not** vendor
zopenstack's configure script, tempest.conf template, or
`report/test_and_report.sh` — they all parse `juju status` output for
machine-charm-specific application names and would not work as-is on Sunbeam.

What we **do** vendor (and may need to adapt over time):

| Vendored | Purpose | Sunbeam adaptation |
|---|---|---|
| `exclude-list.txt` | Tempest tests known not to work | Includes the zopenstack Keystone-policy exclusions plus the floating-IP reachability scenario test, which only passes when the validation host can route to `EXT_SUBNET_POOL`. |

The **workflow** we borrow from zopenstack (in [`scripts/06_validate_tempest.sh`](../../scripts/06_validate_tempest.sh)):

- Run upstream smoke tests with `tempest run --smoke --serial` by default.
  Set `TEMPEST_USE_TOX=1` to exercise `tox -e smoke`; this is optional because
  tox fetches OpenStack upper-constraints over HTTPS and may be blocked by
  internal validation-host proxies.
- Grep `FAILED` lines into a single failures file.
- Allow per-test re-runs with `tempest run --serial --regex <pattern>` (see
  [`tools/run_tempest_test.sh`](../../tools/run_tempest_test.sh)).

The `tempest.conf` itself is **not** sed-rendered from a template like
zopenstack does — instead we use upstream `python-tempestconf` against the
openrc Sunbeam produces. This is deployment-agnostic: works for Sunbeam,
charmed, devstack, or anything else that gives us a working openrc.

## Refreshing

```bash
./tools/refresh_zopenstack.sh
```

Re-pulls the vendored files at the current `main`, writes the new commit SHA
to [`COMMIT`](COMMIT). Review the `git diff` before committing — the
exclude-list may have grown, and any new entries warrant a "does this apply
to Sunbeam too?" check before keeping them.

## Attribution

Original work by the Canonical Ubuntu OpenStack team. See upstream repo for
license and authorship.
