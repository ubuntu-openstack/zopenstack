# vendor/pe-ibm/

Vendored, pinned-by-commit snapshot of files from the Performance Engineering /
IBM Z validation effort:

- Upstream: [canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
- Branch: `c-k8s-and-calico-experimental`

[`scripts/02b_setup_s390x_cni.sh`](../../scripts/02b_setup_s390x_cni.sh) uses
`calico.yaml` to install the patched Calico CNI (the default cilium does not
run on s390x), and uses the coredns image tag in `20-enable-dns.sh` as the
ground truth for [`tools/rewrite_k8s_addon_images.sh`](../../tools/rewrite_k8s_addon_images.sh)'s
`IMAGE_MAP`. The other vendored scripts are reference-only — useful when you
want to know "how do they actually do X" without leaving the LPAR.

Vendored files (all from the upstream repo root — the branch has a flat layout):

| Vendored                                  | Purpose                                                        |
|-------------------------------------------|----------------------------------------------------------------|
| `calico.yaml`                             | Patched Calico manifest (applied by phase 02b)                 |
| `k8s-bootstrap.yaml`                      | Upstream's k8s bootstrap config — reference; we generate ours  |
| `15-build-cluster-calico.sh`              | Reference: how upstream bootstraps k8s + applies Calico        |
| `20-enable-dns.sh`                        | Reference: how upstream enables coredns + rewrites its image   |
| `40-test-basic-workloads.sh`              | Reference: upstream's basic-workload smoke test                |
| `minimal-nginx-v2-no-storage.yaml`        | Reference: upstream's minimal-nginx workload spec              |
| `static-nginx-three-node-lb.yaml`         | Reference: upstream's multi-node LB workload spec              |

## Why vendored

This repo must be runnable on an LPAR where cloning extra repos at deploy time
is awkward, and the source branch is experimental — pinning to a known commit
keeps runs reproducible. The trade-off is staleness; refresh when the upstream
branch advances and you want to pick up changes.

## Refreshing

```bash
./tools/refresh_pe_ibm.sh
```

This re-clones the upstream branch, copies the tracked files in over the top,
writes the new upstream commit SHA to [`COMMIT`](COMMIT), and leaves you with
a `git diff` to review and commit.

## Attribution

Original work by the Canonical Performance Engineering / IBM Z alliances team.
See upstream repository for license and authorship.
