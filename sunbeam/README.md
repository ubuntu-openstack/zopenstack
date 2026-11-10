# Sunbeam s390x single-LPAR core charm validation

**Known release profiles**: 2026.1 Gazpacho (Noble) and 2026.2 Hibiscus
(Resolute, default). Any later `YYYY.N` release is accepted by the renderers;
unprofiled releases default to `<release>/edge`, the latest known Ubuntu base,
and the latest independent charm tracks. Override `BASE_OS` or the per-channel
variables as needed.

This repository contains idempotent shell scripts that deploy the **core Sunbeam
charms** on a single IBM Z LPAR **as plain Juju bundles**, without the `sunbeam`
CLI. The scripts record architecture-availability data at every stage and finish
with a distro Tempest smoke suite by default.

The workflow is **diagnostic-first**. It brings up Canonical Kubernetes, deploys
two Juju bundles (a Kubernetes control plane and a machine plane), and records
what succeeded and what failed, including snaps and OCI images that have no
s390x build. It produces an artifact tarball whether or not the deployment fully
succeeds.

> **Why deploy bundles instead of using `sunbeam`?** The Sunbeam CLI ties the
> entire exercise to snap-openstack working end to end on s390x. Deploying the
> charms directly with `juju deploy <bundle>` lets us validate the core charm
> topology, isolate machine-plane issues, and report precise per-image and
> per-snap architecture gaps upstream.

> **Expected outcome:** the workflow has completed on Noble and Resolute s390x
> LPARs. A fresh run still depends on the selected channels publishing the
> required s390x charms, rocks, and snaps. Missing artifacts are reported in
> `arch_report.md`.

## Deployment topology

The deployment uses two Juju models on one controller, mirroring how Sunbeam
splits the workload:

- **`openstack`**
  CAAS model on the Canonical Kubernetes cloud, defined in
  [manifests/control-plane-k8s-s390x.yaml](manifests/control-plane-k8s-s390x.yaml).
  It contains `mysql`, `rabbitmq`, `self-signed-certificates`, `traefik`,
  `keystone`, `glance`, `placement`, `nova`, `neutron`, and `cinder`
  (plus `cinder-router`).
  It exports the cross-model **offers** `amqp`, `identity-*`, `send-ca-cert`,
  `certificates`, `nova-service`, and `cinder-database`. `neutron` consumes the
  machine model's `ovsdb-cms` offer during phase 03b.
- **`machines`**
  IAAS model on a **manual** cloud whose machine `0` is the LPAR, defined in
  [manifests/machine-lpar-s390x.yaml](manifests/machine-lpar-s390x.yaml). It
  contains `sunbeam-machine`, `microcluster-token-distributor`, `microovn`,
  `sunbeam-ovn-proxy`, `openstack-network-agents`, `openstack-hypervisor`,
  `microceph`, `cinder-volume`, and `cinder-volume-ceph`.
  It consumes the control-plane offers and exports `storage-backend` (from
  `cinder-volume`) and `ovsdb-cms` (from `sunbeam-ovn-proxy`) back to the
  control plane.

This charm set mirrors the earlier charmed OpenStack LPAR validation bundle
([zopenstack noble-flamingo-edge](https://github.com/ubuntu-openstack/zopenstack/blob/main/bundles/lpar/noble-flamingo-edge.yaml)),
which contained keystone, glance, nova, neutron, placement, and cinder, together
with a real compute hypervisor and Ceph block storage. It omits all feature
charms (horizon, heat, octavia, magnum, manila, barbican, designate, ironic,
telemetry, and object storage). It also omits `tempest-k8s`, because that charm
has no s390x OCI image; Tempest therefore runs through upstream `tox` in phase
06 instead.

## External network and extra NIC

The external/provider network is created by phase 04 and is not a per-tenant
network. Phase 03b deploys `openstack-network-agents` as a subordinate of
`microovn` and maps a real host NIC into the provider bridge:

```bash
# Uses the s390x-multi-lpar-v3 defaults:
# VLAN 2893, 10.13.3.0/24, gateway .1, floating IPs .200-.230.
# EXT_NIC auto-discovers the only unconfigured, connected physical NIC.
./run.sh all
```

The defaults match the legacy profile. Override only when your external
network differs:

```bash
EXT_NET_TYPE=flat \
EXT_SUBNET_RANGE=172.16.2.0/24 EXT_SUBNET_GW=172.16.2.1 \
EXT_SUBNET_POOL=start=172.16.2.50,end=172.16.2.200 \
./run.sh all
```

If more than one candidate exists, set `EXT_NIC` explicitly (for example
`EXT_NIC=enc25c`). Auto-discovery uses
`openstack-network-agents list-nics` and rejects the default-route/management
NIC, its parent interface, interfaces with a global IPv4 address, bridges, and
virtual/container interfaces. `EXT_NIC` must exist on the LPAR and be dedicated
to the provider network. For `EXT_NET_TYPE=vlan`, its switch port must carry the
configured VLAN tag (trunk); for `flat`, use an access port. The network-agent
action maps `${EXT_BRIDGE:-br-ex}:${EXT_PHYSNET:-physnet1}:${EXT_NIC}`; phase 04
creates the external network with the matching `EXT_NET_TYPE`/`EXT_VLAN_ID` and
a `provider-router`, mirroring the legacy `neutron-ext-net-ksv3` profile. The
The older internal-bridge fallback (`EXTERNAL_BRIDGE_ADDRESS`, e.g. `.1` on `br-ex`)
is still accepted when no extra NIC is available, but it is not a routed
external network.

Phase 04b validates floating-IP SSH without requiring an external client. With
the default `SMOKE_SSH_NETNS=1`, it creates a temporary network namespace, adds a
veth port to `EXT_BRIDGE` (tagged with `EXT_VLAN_ID` for a VLAN provider
network), assigns a client IP on the external subnet, and runs SSH to the FIP
from that namespace. The namespace and veth are removed during cleanup. Set
`SMOKE_SSH_NETNS=0` to use the old host-route path.

## Kubernetes substrate

This deployment uses **Canonical Kubernetes** (the `k8s` snap), not MicroK8s.
Phase 02b creates a single-node cluster on the LPAR, and phase 03 registers it
with Juju as the CAAS cloud for the `openstack` model.

On s390x, phase 02b uses a modified bootstrap path because the default Cilium
CNI and several Canonical add-on images are not available for s390x:

- bootstrap Canonical Kubernetes with networking disabled;
- apply the vendored **PE/IBM Calico** manifest;
- enable only the required add-ons: DNS, local-storage, and load-balancer;
- use a locally built or sideloaded s390x `rawfile-localpv` image for local
  persistent volumes;
- configure the load-balancer L2 pool from `LB_CIDR`.

Do not proceed to Juju until the node is `Ready`, Calico is running, a PVC can
bind, and a `LoadBalancer` service has received an IP address from the
configured pool.

## Prerequisites

- Ubuntu 26.04 LTS (Resolute) on s390x for the default complete two-model
  workflow.
- Ubuntu 24.04 LTS (Noble) is supported via the 2026.1/Gazpacho profile:
  `OPENSTACK_SERIES=gazpacho` places the host-facing machine charms on a Noble
  manual machine and selects the published `s390x/ubuntu/24.04` revisions. The
  default Hibiscus profile can still use `MACHINE_BASE=ubuntu@24.04` for the
  machine plane only.
- A user with passwordless `sudo` **and** key-based SSH back to the host. Phase
  02 configures the SSH key; it is needed to enrol the LPAR as a Juju manual
  machine.
- Outbound internet access to the Snap Store, `ghcr.io`, `docker.io`, and
  Charmhub. See "Behind a proxy". Phase 00 checks these endpoints and
  passwordless sudo before the other phases run.
- Python 3 with `python3-yaml` for the bundle renderers; phase 01 installs it.
- ~32 GB RAM, ~200 GB disk.
- `/dev/kvm` (s390x KVM) for Nova to launch instances. Phase 02 records whether
  it is present.
- On s390x, plan for the Nova ACPI workaround described in
  [Nova ACPI on s390x](#nova-acpi-on-s390x).

## Fresh LPAR setup

These commands prepare a freshly installed Ubuntu 24.04 or 26.04 s390x LPAR and
start the complete workflow. Run them as the deployment user, not as `root`.

The workflow requires passwordless `sudo`. On a dedicated validation LPAR,
configure it for the deployment user first:

```bash
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-sunbeam
sudo chmod 0440 /etc/sudoers.d/90-sunbeam
```

Configure the proxy environment to access remote resources.

```bash
export PROXY_URL=http://squid.ps6.internal:3128
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"

export NO_PROXY='localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.charmhub.io,charmhub.io,.jujucharms.com,registry.jujucharms.com,streams.canonical.com,ubuntu-cloud.archive.canonical.com'
export no_proxy="$NO_PROXY"
```

Then install the minimum tools, clone the repository, and start the default
2026.2/Hibiscus workflow:

```bash
sudo apt-get update
sudo apt-get install -y git ca-certificates

git clone https://github.com/ubuntu-openstack/zopenstack.git ~/zopenstack
```

After passwordless `sudo` is configured, the same setup can be performed with a
single command:

```bash
cd ~/zopenstack/sunbeam && ./run.sh all
```

The clone command fetches the default branch. To deploy the current working
tree, copy the repository to the LPAR instead of cloning it.

For Ubuntu 24.04 (Noble) and the 2026.1/Gazpacho profile:

```bash
OPENSTACK_SERIES=gazpacho ./run.sh all
```

Phase 02 generates an SSH key and adds it to `~/.ssh/authorized_keys` if needed.
If outbound access requires an HTTP proxy, export `http_proxy` and `https_proxy`
before cloning, and export `PROXY_URL` and `NO_PROXY_DEFAULT` before running the
workflow (see "Behind a proxy").

If you need a different fork or branch, replace the `git clone` URL. If you need
to deploy the current working tree, copy the repository to the LPAR before
running `./run.sh`.

## Behind a proxy

Set `PROXY_URL` before running any phase. The phase scripts configure the shell
environment, `/etc/environment`, APT, snap, and the Kubernetes snap's containerd
through [tools/setup_proxy.sh](tools/setup_proxy.sh):

```bash
export PROXY_URL=http://squid.internal:3128
export NO_PROXY_DEFAULT='localhost,127.0.0.1,::1,<host-ip>,<host-subnet>,10.1.0.0/16,10.152.183.0/24,.svc,.cluster.local,.charmhub.io,charmhub.io,.jujucharms.com,registry.jujucharms.com,streams.canonical.com,ubuntu-cloud.archive.canonical.com'
export NO_PROXY="$NO_PROXY_DEFAULT"
export no_proxy="$NO_PROXY_DEFAULT"
./run.sh all
```

Set `NO_PROXY_DEFAULT` before any code derives `NO_PROXY` from it. A combined
assignment such as `export NO_PROXY_DEFAULT=... NO_PROXY="$NO_PROXY_DEFAULT"`
expands the old value and can leave `NO_PROXY` empty. The symptom is that
`juju add-k8s` fails with `Get "https://<node>:6443/...": Forbidden` because the
Kubernetes API request went through Squid. The phase scripts set `NO_PROXY`
internally, but an interactive `juju status` needs it in your shell too:

```bash
export NO_PROXY="$NO_PROXY_DEFAULT"
export no_proxy="$NO_PROXY_DEFAULT"
juju status
```

For a host-specific manifest, copy [proxy.env.example](proxy.env.example) to
`proxy.env` and source the helper:

```bash
cp proxy.env.example proxy.env
$EDITOR proxy.env
source tools/proxy_env.sh
./tools/setup_proxy.sh
```

`tools/setup_proxy.sh` reads `PROXY_ENV_FILE` or `proxy.env` and applies the
values to `/etc/environment`, APT, snapd, and the Kubernetes snap services.
`tools/proxy_env.sh` exports the same values in the current shell (including the
host IP in `NO_PROXY` for interactive Juju). The phase scripts call
`setup_proxy.sh`; interactive commands need the source helper.

`tools/lib.sh` provides a safe default and phase 03 appends the API server host
to `NO_PROXY` before calling `juju add-k8s`, but keep the explicit
`NO_PROXY_DEFAULT` export for hosts whose control-plane addresses are outside
the default private ranges.

The PS6 Squid proxy currently rejects CONNECT requests to `api.charmhub.io`,
although the LPAR can reach that host directly. Keep `.charmhub.io,charmhub.io`
in `NO_PROXY_DEFAULT`; phase 03 propagates that bypass into both Juju models.
The same applies to `registry.jujucharms.com`, which containerd uses for charm
OCI resources. Include `.jujucharms.com,registry.jujucharms.com`, then rerun
`tools/setup_proxy.sh` so the updated bypass reaches the containerd service.
Manual machine enrolment also downloads the Juju agent index from
`streams.canonical.com`, which must bypass this Squid deployment.

Both `snap.k8s.k8sd.service` and `snap.k8s.containerd.service` need the proxy:
`k8sd` reconciles add-ons, while containerd pulls OCI images. Verify the
configuration with:

```bash
sudo systemctl show snap.k8s.k8sd.service -p Environment --no-pager
sudo systemctl show snap.k8s.containerd.service -p Environment --no-pager
curl -I --connect-timeout 30 https://ghcr.io/v2/
```

You can also run the helper directly after exporting `PROXY_URL` and
`NO_PROXY_DEFAULT`; it derives the repository and run context automatically.

On PS6, the Squid allowlist must cover the OCI registries (`ghcr.io`,
`docker.io`, `registry.k8s.io`, and `quay.io`) and registry redirects such as
`*.docker.pkg.dev`. The `ps6_s390x_openstack` ACL in
[canonical-is-internal-proxy-configs](https://launchpad.net/canonical-is-internal-proxy-configs)
already covers special18 through special22 (10.103.192.218-10.103.192.222);
other LPARs require a follow-up maintenance request (MP).

## Quickstart

```bash
cd ~/zopenstack/sunbeam   # or the directory where you cloned the repository
./run.sh all
```

This creates `artifacts/<UTC-timestamp>/`, runs every phase in order, and, on
completion, produces two deliverables:

- `sunbeam-<arch>-<run-id>.tar.zst` — the full diagnostic archive.
- `test-share-<arch>-<run-id>.tar.zst` — a compact, publishable validation
  report modelled on the
  [openstack-charmers/test-share s390x results](https://github.com/openstack-charmers/test-share/tree/master/s390x/2025-dec/noble-flamingo-ovn/multi-lpar).

### Running a single phase

```bash
./run.sh 00          # host suitability check
./run.sh 02b         # Kubernetes and Calico setup
./run.sh 03          # control-plane bundle deployment
./run.sh 03b         # machine-plane bundle deployment
./run.sh --run-id 20260617T120000Z 04   # re-run configuration in an existing run directory
```

All phases are idempotent. Each writes `.status/<phase>.done` and skips itself on
a subsequent run unless you delete the sentinel file.

### Run output

Each phase writes the full command output to
`artifacts/<run-id>/phase_<phase>.log`. The terminal shows one `RUN`/`OK` line
per command; on failure it prints the complete captured output. Set
`RUN_LOGGED_VERBOSE=1` to stream full command output live.

## Phases

| #   | Script                          | Purpose                                                                                |
|-----|---------------------------------|----------------------------------------------------------------------------------------|
| 00  | `00_check_host.sh`              | Verify the target architecture, Ubuntu release, passwordless sudo, and endpoint connectivity; record environment, network, and KVM facts. |
| 01  | `01_install_prereqs.sh`         | Install prerequisites and Juju; check target architecture snaps and bundles.            |
| 02  | `02_prepare_node.sh`            | Prepare the host (kernel modules and `/dev/kvm` check) and configure key-based SSH to itself for the manual cloud. |
| 02b | `02b_setup_s390x_cni.sh`        | Bootstrap Canonical Kubernetes, validate networking and storage, and **configure the load-balancer pool**. |
| 03  | `03_bootstrap.sh`               | Register the cluster with Juju, bootstrap the controller, add the `openstack` model, and deploy the control-plane bundle. |
| 03b | `03b_deploy_machine_plane.sh`   | Create the manual cloud and `machines` model, enrol the LPAR as machine 0, deploy the machine bundle (microovn, proxy, network agents), map `EXT_NIC`, and wire `storage-backend` and `ovsdb-cms`. |
| 04  | `04_configure.sh`               | Obtain an openrc through `keystone get-admin-account`; create the external network (flat/VLAN provider network), provider router, flavors, and s390x image with the OpenStack CLI. |
| 04b | `04b_smoke_cloud.sh`            | Boot a guest, attach a Cinder volume, assign a floating IP, and verify SSH from a temporary provider-network namespace. |
| 05  | `05_capture_state.sh`           | Capture per-model `juju export-bundle`, `status`, and `offers`; dump Kubernetes resources; sweep snap and OCI s390x availability. |
| 06  | `06_validate_tempest.sh`        | Run Tempest smoke tests: generate `tempest.conf` with `discover-tempest-config`, then install/run distro Tempest + plugins by default (`TEMPEST_PLUGIN_MODE=upstream` for upstream-only), and record failures. |
| 99  | `99_collect_artifacts.sh`       | Build the full diagnostic archive and the compact test-share-compatible report.         |

In `./run.sh all` mode, a blocking failure skips the dependent phases and
proceeds directly to phases 05 and 99, so a post-mortem tarball is always
produced.

## Key files

- [run.sh](run.sh) — the entry point. It uses `LC_ALL=C` sorting so that phase `03` runs before `03b`, and phase `02` runs before `02b`.
- [manifests/control-plane-k8s-s390x.yaml](manifests/control-plane-k8s-s390x.yaml) —
  the Kubernetes control-plane bundle and its cross-model offers.
- [manifests/machine-lpar-s390x.yaml](manifests/machine-lpar-s390x.yaml) — the
  machine-plane bundle. It consumes control-plane offers and exports
  `storage-backend` and `ovsdb-cms`.
- [tools/lib.sh](tools/lib.sh) — logging, idempotency, `juju_wait_settle`, and
  architecture-report helpers.
- [tools/build_local_charms.sh](tools/build_local_charms.sh) — fresh-clone and
  build the s390x hybrid charms into `./charms/`.
- [tools/build_snaps.sh](tools/build_snaps.sh) — discover snap patch directories
  and build every corresponding s390x snap into `./snaps/`.
- [tools/build_rock.sh](tools/build_rock.sh) — fresh-clone a rockcraft project,
  apply discovered rock patches, and build it for s390x.
- [tools/proxy_env.sh](tools/proxy_env.sh) and
  [proxy.env.example](proxy.env.example) — sourceable proxy manifest for the
  current shell; `tools/setup_proxy.sh` applies the same file system-wide.
- [tools/check_snap_arch.sh](tools/check_snap_arch.sh) and [tools/check_oci_arch.sh](tools/check_oci_arch.sh) —
  s390x availability for each snap channel and OCI image.
- [tools/check_charm_arch.sh](tools/check_charm_arch.sh) — s390x availability for
  each Charmhub charm, channel, and base. The phase 01 preflight checks both
  bundles with this tool.
- [tools/render_release_bundles.py](tools/render_release_bundles.py) — applies
  the `OPENSTACK_SERIES` and `BASE_OS` profile (2026.2/Hibiscus, 26.04, and the
  OVN and microovn channels) to both bundles.
- [tools/extract_oci_images.sh](tools/extract_oci_images.sh) — extracts image
  references from bundles. Phase 05 also checks the images that are running in
  the cluster, because `juju export-bundle` records resource revisions rather
  than OCI references.
- [tools/refresh_pe_ibm.sh](tools/refresh_pe_ibm.sh) — re-vendors the Calico
  manifest and CoreDNS rewrite from
  [canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation).
- [tools/rewrite_k8s_addon_images.sh](tools/rewrite_k8s_addon_images.sh) —
  rewrites add-on `ghcr.io/canonical/...` images to upstream registries that
  provide s390x builds.
- [tools/run_tempest_test.sh](tools/run_tempest_test.sh) — re-runs a single
  Tempest test.
- [vendor/pe-ibm/](vendor/pe-ibm/) and [vendor/zopenstack/](vendor/zopenstack/) —
  pinned snapshots.

The Python renderers (`render_release_bundles.py`, `render_hybrid_bundles.py`)
use the host `python3` and `python3-yaml`. Run them directly with their
`python3` shebang, or invoke `python3 tools/<script>.py`.

> The old `manifests/sunbeam-2026.1-s390x.yaml` was a *Sunbeam manifest* for the
> retired CLI path. It is kept only as a channel-pin reference; the live channel
> pins now reside in the two bundle files.

## Charm sources: Charmhub, hybrid, or local

Phases 03 and 03b deploy the same topology from one of three charm sources,
selected by `CHARM_SOURCE`:

- **`charmhub`** (default) — published charms selected by `OPENSTACK_SERIES`
  (`2026.2/edge` for the default Hibiscus profile) with OCI images omitted so
  that Juju pulls each revision's image.
  This diagnostic mode exposes per-image s390x gaps. The bundles are
  `manifests/control-plane-k8s-s390x.yaml` and
  `manifests/machine-lpar-s390x.yaml`. As of November 2026, `rabbitmq-k8s` has
  no s390x charm revision on any channel, `microceph` has none on
  `squid/stable`, and `microcluster-token-distributor` (which `microovn`
  requires) has no s390x revision. This mode is therefore expected to stop at
  phase 03 or 03b and record the gaps. The phase 01 preflight reports these
  explicitly in `arch_report.md`.
- **`hybrid`** — the Noble/s390x qualification path while publication is still
  catching up. It generates bundles in the run artifact directory, using
  Charmhub for published components and the local artifacts
  `rabbitmq-k8s_s390x.charm`, `microcluster-token-distributor_s390x.charm`,
  and `sunbeam-machine_s390x.charm`. Local builds of `microceph_s390x.charm`,
  `cinder-volume-ceph_s390x.charm`, `microovn_s390x.charm`, and
  `sunbeam-ovn-proxy_s390x.charm` are used when staged; otherwise the
  published s390x revisions are used. The renderer also selects the currently available s390x TLS and
  Traefik channels. Generated bundles use absolute paths for local charms,
  because Juju resolves them relative to the bundle file under
  `artifacts/<run-id>/`. The RabbitMQ charm is built from
  `RABBITMQ_CHARMS_REF` (default `main`) and must be paired with an OCI image
  from the same charm track via `RABBITMQ_IMAGE`. Hybrid mode requires the image
  to be set and to have an s390x manifest.
- **`local`** — the Sunbeam charms that we build for s390x, deployed from
  `./charms/*_s390x.charm` with their workload OCI images pinned to s390x rocks.
  This exercises our builds on the modified Kubernetes substrate. The bundles
  are `manifests/control-plane-k8s-s390x-local.yaml` and
  `manifests/machine-lpar-s390x-local.yaml`. External dependencies that we do
  **not** build (`mysql-k8s`, `rabbitmq-k8s`, `self-signed-certificates`,
  `traefik-k8s`, `mysql-router-k8s`, `microovn`, `sunbeam-ovn-proxy`, and
  `microceph`) remain on Charmhub. `microcluster-token-distributor` is staged
  locally because Charmhub has no s390x revision. This mode is still blocked by
  the missing s390x revisions for `rabbitmq-k8s` and `microceph`; use hybrid
  mode (with a local RabbitMQ rock) for those two charms. The
  `ovn-central-k8s` and `ovn-relay-k8s` charms are retired.

```bash
# Diagnostic mode with published charms (the default).
./run.sh 03 && ./run.sh 03b
# The published stack plus the unpublished Noble/s390x charms. Set
# RABBITMQ_IMAGE to an s390x RabbitMQ rock (the published tag has no s390x).
RABBITMQ_IMAGE=<your-s390x-rabbitmq-rock> \
CHARM_SOURCE=hybrid ./run.sh 03 && CHARM_SOURCE=hybrid ./run.sh 03b
# 2026.2/Hibiscus hybrid mode. Pass OPENSTACK_SERIES to phase 03b too.
OPENSTACK_SERIES=hibiscus RABBITMQ_IMAGE=<s390x-rock> \
CHARM_SOURCE=hybrid ./run.sh 03 && \
OPENSTACK_SERIES=hibiscus CHARM_SOURCE=hybrid ./run.sh 03b
# Local s390x charm builds.
CHARM_SOURCE=local ./run.sh 03 && CHARM_SOURCE=local ./run.sh 03b
```

### Build the local hybrid charms

[tools/build_local_charms.sh](tools/build_local_charms.sh) builds the hybrid
charm artifacts on s390x. It clones fresh checkouts into `.charm-build/`
(gitignored; no existing repository is reused), applies the s390x platform to
the token-distributor charm, and stages the results in `./charms/`:

```bash
sudo snap install charmcraft --classic
sudo lxd init --auto          # no-op if already initialized
source tools/proxy_env.sh     # if proxy.env exists
./tools/build_local_charms.sh
```

The build selects the release-compatible sources automatically:

| Charm | Source ref |
|---|---|
| `cinder-volume-ceph` | `sunbeam-charms` `stable/<release from OPENSTACK_SERIES>` (Hibiscus defaults to `stable/2026.2`, falling back to `main` if absent) |
| `sunbeam-machine` | same `sunbeam-charms` checkout; `ops_sunbeam` and charm libs are vendored |
| `rabbitmq-k8s` | `charm-rabbitmq-k8s` `main`, configurable via `RABBITMQ_CHARMS_REF` |
| `microceph` | `charm-microceph` `main` |
| `microcluster-token-distributor` | `microcluster-token-distributor-operator` `main` |

The tool defaults `OPENSTACK_SERIES=hibiscus`, so the Sunbeam charms are cloned
from `stable/2026.2` when that branch exists. If it does not exist yet, the
tool warns and falls back to `main`; set `SUNBEAM_CHARMS_REF=stable/2026.2`
explicitly to make a missing branch a hard error.

Override repositories or refs with `OPENSTACK_SERIES`,
`SUNBEAM_CHARMS_REPO/REF`, `RABBITMQ_CHARMS_REPO/REF`,
`MICROCEPH_CHARMS_REPO/REF`, and `MICROCLUSTER_CHARMS_REPO/REF`. Use
`--dry-run` to print the clone and pack commands without building.

The builder clones `sunbeam-charms` from `opendev.org` and the other sources
from GitHub. If Squid blocks `opendev.org`, add `opendev.org` (and
`review.opendev.org` if you use Git over SSH) to the proxy allowlist, or point
`SUNBEAM_CHARMS_REPO` at a reachable mirror. The GitHub sources are already
allowed on PS6.

This builder only builds charms. Pair the built RabbitMQ charm with an image
from the same charm track via `RABBITMQ_IMAGE`; the selected image must be
reachable by the cluster and have an s390x manifest. A published s390x image
does not need a local rock build.

### Build the local machine snaps

[tools/build_snaps.sh](tools/build_snaps.sh) builds every snap that has a
`patches/snaps/<snap>/` directory and stages the result in `./snaps/` as
`<snap>_s390x.snap`:

```bash
source tools/proxy_env.sh
./tools/build_snaps.sh
```

Currently discovered snaps are `openstack-hypervisor` and `cinder-volume`. The
hypervisor source branch defaults to `stable/<release from OPENSTACK_SERIES>`
(for example `stable/2026.2`). If that branch is not published yet, the builder
falls back to `feat/<release>` and then `main`, checking the primary and fallback
repositories in that order. `cinder-volume` defaults to `main`. Override with
`SNAP_HYPERVISOR_BRANCH`, `SNAP_CINDER_BRANCH`, `SNAP_HYPERVISOR_REPO`,
`SNAP_CINDER_REPO`, and their `*_FALLBACK_REPO` counterparts.

Patches are discovered, not hard-coded. Every `*.patch` under
`patches/snaps/<snap>/` is applied in lexical order after the fresh clone. The
hypervisor patches are:

- `patches/snaps/openstack-hypervisor/mdevctl-system-files.patch`
- `patches/snaps/openstack-hypervisor/qemu-s390x-target.patch`
- `patches/snaps/openstack-hypervisor/nova-acpi-ppa.patch` (the PPA entry is
  merged into an existing `package-repositories` block when the branch already
  has one)

The cinder-volume patches are:

- `patches/snaps/cinder-volume/ceph-20.2.4-ppa.patch` (temporary until Resolute
  publishes Ceph 20.2.4)

Phase 03b builds the local snaps by default before deploying the machine
bundle. It installs both the local `openstack-hypervisor` and
`cinder-volume` snaps before deploying the machine bundle; set
`CINDER_VOLUME_SNAP_PATH` or `HYPERVISOR_SNAP_PATH` explicitly to use
prebuilt snaps. Set `BUILD_LOCAL_SNAPS=0` to disable building. The build uses
`snapcraft pack --destructive-mode`; `NO_PROXY_DEFAULT` includes
`ubuntu-cloud.archive.canonical.com`, and `build_snaps.sh` also enforces that
bypass, because the Squid allowlist rejects the UCA while direct access works.

A locally built snap is not store-declared, so snapd does not auto-connect its
interfaces before the configure hook. Phase 03b installs it with
`snap install --dangerous --devmode` and then explicitly connects
`hardware-observe`, `system-observe`, `mount-observe`, `block-devices`,
`network-control`, `network-observe`, `process-control`,
`kernel-module-control`, `kernel-module-observe`, `hugepages-control`, `kvm`,
`libvirt`, `iscsi-initiator`, `nvme-control`, `raw-usb`, `firewall-control`,
`dm-multipath`, `microstack-support`, `etc-driverctl`, and `mdevctl-config`.
It also connects the `ovn-chassis` and `ovn-env` content interfaces to
`microovn` and links `microovn`'s switch socket under the hypervisor's
`SNAP_DATA`; without that path `nova-compute` cannot plug OVS VIFs. Because the
local snap is devmode, phase 03b sets the hypervisor charm's
`experimental-devmode` option to match; published strict snaps leave it unset.
For the published `cinder-volume` snap, phase 03b connects
`hardware-observe`, `block-devices`, `network-observe`, `network-control`,
`mount-observe`, `process-control`, and `system-observe`, then restarts it.

Phase 03b also reconnects the `ovn-chassis` content interface of
`openstack-network-agents` and `ovn-exporter` after microovn creates its
`run/switch/db.sock`, then restarts `ovn-exporter`. snapd can leave those
content mounts empty when the charms connect before microovn bootstraps; the
reconnect prevents the network-agent `configure-snap` timeout and the
microovn `metrics endpoint is not reachable` block.

### Build a rock from ubuntu-openstack-rocks

[tools/build_rock.sh](tools/build_rock.sh) is the generic builder for rocks in
`canonical/ubuntu-openstack-rocks`. It clones a fresh checkout into
`.rock-build/`, builds `rocks/<rock>` for s390x, and optionally pushes the
result to an OCI registry with `--push`.

Juju does not import image layers into containerd. `juju attach-resource` (or
the bundle's resource entry) takes a registry reference; the cluster then pulls
the image. The tool therefore publishes to a registry rather than writing
directly to the Kubernetes node.

Check the selected RabbitMQ image with `tools/check_oci_arch.sh`. If it is
already published for s390x, no local rock build is needed. The generic builder
is useful for other rocks or for a custom image:

```bash
sudo snap install rockcraft --classic
sudo snap install skopeo
sudo lxd init --auto
source tools/proxy_env.sh
./tools/build_rock.sh cinder-volume --ref main \
  --push <registry>/cinder-volume:2026.2-s390x
```

If you omit `--push`, the tool leaves the `.rock` in
`.rock-build/ubuntu-openstack-rocks/rocks/<rock>/` for a separate
`skopeo copy oci-archive:<rock> docker://<registry>/<image>:<tag>`.

The same tool builds other rocks, for example:

```bash
./tools/build_rock.sh cinder-volume --ref main \
  --push registry.example/cinder-volume:2026.2-s390x
./tools/build_rock.sh nova --ref main --push registry.example/nova:2026.2-s390x
```

`--ref` accepts a branch, tag, or commit. The default recommendation is
`docker.io/library/<rock>:<version>-s390x`; override it with `--tag` or
`--output-image`. `--push` accepts any OCI registry reference and uses
`skopeo copy`; set `SKOPEO_DEST_TLS_VERIFY=true` for a TLS registry.

Hybrid mode fails preflight unless the two unpublishable local charms exist in
`./charms/` and declare s390x support: `rabbitmq-k8s_s390x.charm` and
`microcluster-token-distributor_s390x.charm`. The RabbitMQ charm must declare
Ubuntu 24.04. MicroCeph, cinder-volume-ceph, sunbeam-machine, microovn, and
sunbeam-ovn-proxy are used locally when staged and otherwise fall back to their
published s390x revisions. The machine charms must match the machine base
(26.04 by default; set `OPENSTACK_SERIES=gazpacho` for 24.04, or
`MACHINE_BASE=ubuntu@24.04` explicitly). Optional local `microovn_s390x.charm` and
`sunbeam-ovn-proxy_s390x.charm` builds
are used when they are staged. Preflight also fails if `RABBITMQ_IMAGE` has no
s390x manifest.

For local mode, first stage the `.charm` files in `charms/` (see
[charms/README.md](charms/README.md)) and replace the `REPLACE-ME/...:s390x`
resource placeholders in `control-plane-k8s-s390x-local.yaml` with real s390x
rock references. Note that the external Charmhub charms listed above still need
their own s390x images. Check them with `tools/check_oci_arch.sh` first; a
missing image will stall the deployment regardless of our charms.

## 2026.2 Hibiscus on Resolute 26.04

Set `OPENSTACK_SERIES=hibiscus` (the default) for the entire run. The release
profile implies `ubuntu@26.04` and selects the following:

| Component | 2026.2 channel | Base |
|-----------|----------------|------|
| keystone/glance/placement/nova/neutron/cinder | `2026.2/edge` | `ubuntu@26.04` |
| `cinder-volume`/`openstack-hypervisor`/`cinder-volume-ceph` | `2026.2/edge` | `ubuntu@26.04` |
| `openstack-network-agents` | `2026.2/edge` | `ubuntu@26.04` |
| guest cloud image | `resolute` (Ubuntu 26.04) | n/a |
| `sunbeam-machine` | local s390x build | `ubuntu@26.04` |
| `sunbeam-ovn-proxy` | `2026.2/edge` | `ubuntu@26.04` |
| `microovn` | `26.03/edge` | `ubuntu@26.04` |
| `microceph` | `tentacle/edge` | `ubuntu@26.04` |
| `openstack-hypervisor`/`cinder-volume` snaps | `2026.2/edge` | n/a |
| `microcluster-token-distributor` | `v1/stable` | local s390x build |

`ovn-central-k8s` and `ovn-relay-k8s` are retired; `microovn` owns the OVN
databases and `sunbeam-ovn-proxy` bridges them to `neutron` and the hypervisor.

```bash
# Published 2026.2 charms on Resolute. This still requires local s390x builds
# of rabbitmq-k8s, microcluster-token-distributor, and sunbeam-machine.
OPENSTACK_SERIES=hibiscus CHARM_SOURCE=hybrid \
RABBITMQ_IMAGE=<your-s390x-rabbitmq-rock> \
./run.sh all
```

If you run phases individually, export `OPENSTACK_SERIES=hibiscus` for phase 01
(preflight), phase 03 (control-plane rendering), and phase 03b (machine
rendering). `BASE_OS` and `MACHINE_BASE` can override the base, but the
published 2026.2 s390x charms support only `ubuntu@26.04`, so a different base
requires local builds.

## Useful environment overrides

| Variable | Default | Used by |
|----------|---------|---------|
| `TARGET_ARCH` | `s390x` | all phases (architecture checks and the guest image); only `s390x` is supported |
| `PROXY_URL` | unset | all (proxy setup) |
| `PROXY_ENV_FILE` | `proxy.env` if present | proxy manifest read by `setup_proxy.sh`/`proxy_env.sh` |
| `NO_PROXY_DEFAULT` | private ranges + cluster suffixes + UCA | all phases (proxy bypass; phase 03 appends the API host) |
| `CHECK_NETWORK` | `1` | 00 — set `0` to skip endpoint reachability checks |
| `CHECK_NET_TIMEOUT` | `30` | 00 — curl timeout in seconds per endpoint |
| `CHECK_SNAP_API_TIMEOUT` | `30` | 01 — Snap Store API timeout in seconds |
| `CHECK_SNAP_CLI_TIMEOUT` | `30` | 01 — `snap info` timeout in seconds |
| `RUN_LOGGED_VERBOSE` | `0` | all `run_logged` commands — stream full command output to the terminal; full output is always in `phase_<phase>.log` |
| `CHARM_BUILD_DIR` | `.charm-build` | `tools/build_local_charms.sh` fresh checkout directory |
| `SNAP_HYPERVISOR_BRANCH` | `stable/<release from OPENSTACK_SERIES>` | `tools/build_snaps.sh`; falls back to `feat/<release>` and `main` |
| `SNAP_CINDER_BRANCH` | `main` | `tools/build_snaps.sh` |
| `SNAP_HYPERVISOR_REPO` / `SNAP_HYPERVISOR_FALLBACK_REPO` | canonical repo / himax16 fork | `tools/build_snaps.sh` |
| `SNAP_CINDER_REPO` / `SNAP_CINDER_FALLBACK_REPO` | canonical repo / unset | `tools/build_snaps.sh` |
| `SNAP_PATCH_ROOT` | `patches/snaps` | `tools/build_snaps.sh`; every subdirectory is built |
| `SNAP_BUILD_DIR` / `SNAP_OUT_DIR` | `.snap-build` / `snaps` | `tools/build_snaps.sh` |
| `ROCK_PATCH_ROOT` | `patches/rocks` | `tools/build_rock.sh`; patches are read from `<root>/<rock>` |
| `BUILD_LOCAL_SNAPS` | `1` | 03b — build all locally patched snaps; install the local hypervisor snap |
| `SUBSTRATE_STRICT` | `1` | 02b — fail if Calico/rawfile CSI/PVC/MetalLB readiness gates fail |
| `RAWFILE_LOCALPV_IMAGE` | `docker.io/library/rawfile-localpv:0.8.3-s390x` | 02b local-storage image tag |
| `RAWFILE_LOCALPV_ROCK` | auto-discovered under `$HOME/builds/rawfile-localpv-rocks-s390x/` | 02b — `.rock` to import into Canonical Kubernetes containerd when the image is absent |
| `LB_CIDR` | derived `<host /24>.240-.250` | 02b load-balancer pool; set this explicitly to a reserved, unused L2 range |
| `K8S_CHANNEL` | `latest/edge` | 01/02b |
| `JUJU_CHANNEL` | `3/stable` | 01 |
| `JUJU_CONTROLLER` / `K8S_MODEL` / `MACHINE_MODEL` / `MANUAL_CLOUD` | `sunbeam-controller` / `openstack` / `machines` / `lpar-manual` | 03/03b/04/05/06 |
| `CHARM_SOURCE` | `charmhub` | 03/03b — `charmhub`, `hybrid`, or `local` (see "Charm sources") |
| `BUNDLE` | per-phase `*-s390x.yaml` | 03/03b — explicit bundle path; overrides `CHARM_SOURCE` |
| `OPENSTACK_SERIES` | `hibiscus` (2026.2) | 01/03/03b — selects the release profile, core/machine charm channels, and `ubuntu@26.04`; `gazpacho` selects 2026.1/`ubuntu@24.04`; also selects `stable/<release>` in the local builders |
| `BASE_OS` | release profile (`ubuntu@26.04` / `ubuntu@24.04`) | 03/03b — Ubuntu base for the rendered control-plane and machine bundles |
| `RABBITMQ_IMAGE` | unset; required for hybrid | hybrid — OCI image from the same track as the RabbitMQ charm; must have an s390x manifest |
| `MACHINE_BASE` | unset; `ubuntu@26.04` for Hibiscus | 03b — explicit machine base override |
| `MACHINE_CHANNEL` / `MICROCEPH_CHARM_CHANNEL` / `MICROOVN_CHANNEL` / `OVN_PROXY_CHANNEL` / `TOKEN_DISTRIBUTOR_CHANNEL` | release profile (`2026.2/edge`, `tentacle/edge`, `26.03/edge`, `2026.2/edge`, `v1/stable`) | 03b — channel overrides for the rendered machine bundle |
| `HYPERVISOR_CHANNEL` / `CINDER_VOLUME_CHANNEL` / `MICROCEPH_CHANNEL` / `MICROOVN_SNAP_CHANNEL` / `OVN_EXPORTER_CHANNEL` | release profile (`2026.2/edge`, `2026.2/edge`, `tentacle/edge`, `26.03/stable`, `stable`) | 01 — snap arch checks |
| `ALLOW_UNSUPPORTED_HOST_BASE` | `0` | 01 preflight — allow a non-24.04 host for control-plane/tooling diagnostics |
| `HYPERVISOR_SNAP_PATH` | built by `tools/build_snaps.sh` when `BUILD_LOCAL_SNAPS=1` | 03b — install this local `openstack-hypervisor` snap with `snap install --dangerous` before the machine charm configures it; a local devmode snap also sets the charm's `experimental-devmode` so the charm accepts it (strict published snaps leave it unset) |
| `CINDER_VOLUME_SNAP_PATH` | built by `tools/build_snaps.sh` when `BUILD_LOCAL_SNAPS=1` | 03b — install this local `cinder-volume` snap with `snap install --dangerous --devmode` before the machine bundle is deployed |
| `MICROOVN_EXPORTER_RISK` | `edge` on s390x | 03b — microovn `ovn_exporter_risk`; the stable exporter's `content: microovn-run-switch` plug does not match the microovn slot, while edge connects successfully |
| `HYPERVISOR_EXPECT_NOVA_ACPI_PATCH` | `auto` | 03b — on s390x, `auto` or `warn` issues a warning if the installed hypervisor snap does not stage Nova with the LP #2043987 ACPI workaround; set `1` to fail early |
| `HYPERVISOR_SKIP_CEPH_SECRET_CONFIG` | `auto` | 03b — seed `/var/snap/openstack-hypervisor/common/skip-ceph-secret-config` before deploy; `auto` enables it on s390x |
| `HYPERVISOR_DISABLE_SPICE` | `auto` | 03b — write a Nova config override disabling SPICE graphics on s390x QEMU |
| `HYPERVISOR_DISABLE_VTPM` | `auto` | 03b — write a Nova config override disabling vTPM on s390x; the current libvirt build reports no vTPM support and Nova otherwise refuses to start |
| `DEPLOY_TIMEOUT` | `3600` | 03/03b settle wait |
| `READINESS_TIMEOUT` | value of `DEPLOY_TIMEOUT` | 03b — final per-model wait for every unit workload to become active |
| `EXT_NET_NAME` / `EXT_SUBNET_RANGE` / `EXT_SUBNET_GW` / `EXT_SUBNET_POOL` / `EXT_PHYSNET` | external-network / 10.13.3.0/24 / .1 / .200-.230 / physnet1 | 03b/04/04b/06 |
| `EXT_NIC` | auto-discovered when exactly one safe candidate exists | 03b — physical host NIC mapped to `br-ex`/physnet1 by `openstack-network-agents`; set explicitly if discovery is ambiguous |
| `EXT_BRIDGE` | `br-ex` | 03b — OVS bridge name used in the network-agents mapping |
| `EXT_NET_TYPE` / `EXT_VLAN_ID` | `vlan` / `2893` | 04 — external network provider type and VLAN ID (`vlan` requires a trunked `EXT_NIC`) |
| `EXT_PROVIDER_ROUTER` | `provider-router` | 04 — router connected to the external gateway |
| `EXTERNAL_BRIDGE_ADDRESS` | unset | 03b — legacy local-bridge address (for example `172.16.2.1/24`); when `EXT_NIC` is set it configures `openstack-network-agents` instead of the hypervisor |
| `NETWORK_AGENTS_CHANNEL` / `NETWORK_AGENTS_SNAP_CHANNEL` | release profile (`2026.2/edge` for Hibiscus) | 01/03b — Charmhub channel and pre-install channel for `openstack-network-agents` |
| `IMAGE_URL` | release guest cloud image for `TARGET_ARCH` | 04 — overrides the complete guest image URL |
| `TEMPEST_IMAGE_URL` | release guest cloud image for `TARGET_ARCH` | 06 — overrides the image used by `discover-tempest-config` |
| `CINDER_READY_ATTEMPTS` / `CINDER_READY_INTERVAL` | `30` / `10` | 04b — wait for the `cinder-volume` service to become up before volume tests |
| `SMOKE_IMAGE` | `ubuntu` | 04b — Glance image used for the smoke guest |
| `SMOKE_VALIDATE_SSH` / `SMOKE_SSH_USER` | `1` / `ubuntu` | 04b — floating-IP SSH acceptance check |
| `SMOKE_SSH_NETNS` | `1` | 04b — run FIP SSH from a temporary veth/network namespace on the provider bridge; set `0` to use the host network |
| `SMOKE_CLIENT_IP` | derived from `EXT_SUBNET_RANGE` | 04b — address assigned to the temporary FIP client; override if it collides |
| `SMOKE_CONFIG_DRIVE` | `true` | 04b — pass Nova metadata/network data via config-drive; required for reliable s390x guest networking in the LPAR test cloud |
| `SMOKE_SSH_INITIAL_SLEEP` / `SMOKE_SSH_ATTEMPTS` / `SMOKE_SSH_INTERVAL` | `90` / `30` / `10` | 04b — SSH proof timing after floating-IP association |
| `TEMPEST_PLUGIN_MODE` | `distro` | 06 — `distro` installs/runs the distribution Tempest plugin set for legacy charmed OpenStack test-count parity; `upstream` uses upstream Tempest only |
| `TEST_SHARE_NOTES_FILE` | unset | 99 — optional Markdown file appended as "Notes and known issues" in the publishable report |

Phase 03 sets the Juju model constraint `arch=$TARGET_ARCH` before deploying
applications, so all CAAS pods are scheduled on the s390x LPAR.

The current `traefik-k8s` s390x revision on `latest/edge` uses `ubuntu@26.04`
and Python 3.14. It contains a `google._upb._message` extension that segfaults
while importing OpenTelemetry protobuf modules. Phase 03 disables that optional
accelerator inside Traefik's charm virtual environment, so that protobuf falls
back to its pure-Python implementation. Set `TRAEFIK_DISABLE_BROKEN_UPB=0` once
a fixed revision is published.

Phase 03 fails on unresolved `ErrImagePull` and `ImagePullBackOff` states, but
it does not require every workload to be active before phase 03b. Cinder is
expected to block until the machine-plane storage offer exists. Nova may also
briefly report a conductor crash loop because its Pebble liveness check runs
while the service is deliberately disabled pending relations. Evaluate final
unit health after phase 03b connects both models.

Phase 03b discovers the actual Juju ID of the enrolled manual machine and maps
bundle machine `0` to it. Juju does not reuse IDs after a failed enrolment, so
hard-coding `0=0` can create an impossible extra machine on the manual provider.

On s390x, phase 03b seeds `skip-ceph-secret-config` before deployment to avoid
an early Ceph/libvirt ordering failure in the hypervisor snap. Set
`HYPERVISOR_SKIP_CEPH_SECRET_CONFIG=0` when testing a snap that should handle
this itself.

Phase 03b builds the local hypervisor snap automatically (see "Build the local
machine snaps"). To use an existing snap instead, set `BUILD_LOCAL_SNAPS=0` and
provide `HYPERVISOR_SNAP_PATH`. The script installs it with `--dangerous`, holds
refreshes, and lets the charm configure it:

```bash
BUILD_LOCAL_SNAPS=0 \
HYPERVISOR_SNAP_PATH=/path/openstack-hypervisor_s390x.snap \
HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1 \
OPENSTACK_SERIES=hibiscus CHARM_SOURCE=hybrid \
./run.sh --run-id <run-id> 03b
```

For client-facing s390x validation, set `HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1`
so that the run fails before guest boot if the workaround is missing.

After the machine model settles, phase 03b also applies the current s390x
runtime fixes: it connects the `mdevctl-config` plug, disables SPICE, defines the
libvirt RBD secret, and restarts the hypervisor services.

On Resolute, the supported path is the 2026.2/Hibiscus profile:

```bash
OPENSTACK_SERIES=hibiscus ./run.sh all
# Or run only the machine plane in an existing run:
OPENSTACK_SERIES=hibiscus ./run.sh --run-id <run-id> 03b
```

The renderer selects `ubuntu@26.04` and the published 26.04 channels:
`2026.2/edge` for the core services and machine charms, `26.03/edge` for
microovn, `2026.2/edge` for sunbeam-ovn-proxy, and `tentacle/edge` for
microceph. You can override these with `MACHINE_CHANNEL`,
`MICROCEPH_CHARM_CHANNEL`, `MICROOVN_CHANNEL`, `OVN_PROXY_CHANNEL`, and
`TOKEN_DISTRIBUTOR_CHANNEL`. `BASE_OS` and `MACHINE_BASE` can pin a different
base, but the published 2026.2 s390x charms support only 26.04.

The older `MACHINE_BASE=ubuntu@26.04` path still renders the Gazpacho topology
on 26.04 using the 2026.2 machine publications, but the control plane remains on
2026.1/24.04. Use `OPENSTACK_SERIES=hibiscus` (the default) when you want the
entire cloud on Hibiscus. Hybrid mode additionally requires its local machine charms
(`microceph_s390x.charm`, `cinder-volume-ceph_s390x.charm`, and
`microcluster-token-distributor_s390x.charm`) to declare `ubuntu@26.04` when the
machine base is 26.04.

This validates the host-facing machine charms against a 26.04 manual machine.
If `juju add-machine` reports `machine is already provisioned` after a failed
attempt, destroy the failed `machines` model and remove the stale Juju
machine-agent state before re-enrolling the LPAR.

Phase 03b has two distinct gates. First, it waits for Juju agents to finish
their hooks; then it requires every unit in both the `machines` and `openstack`
models to report an active workload. An idle agent with a blocked, waiting, or
error workload therefore fails the phase instead of producing a false success.

The first s390x `openstack-hypervisor` revision tested on Noble
(`2026.1/edge`, snap revision 646, June 25, 2026) had a strict-confinement gap:
`libvirtd` could not monitor `/etc/mdevctl.d`, exited, and the configure hook
subsequently failed because `virtqemud-sock` did not exist. The correct
snap-side fix is a read-only `system-files` plug for `/etc/mdevctl.d` connected
to the `libvirtd` app. Phase 03b detects this exact failure and stops with a
packaging error; do not disable AppArmor to hide it. The tested source patch is
kept at `patches/snaps/openstack-hypervisor/mdevctl-system-files.patch` until an
equivalent fix is published.

The initial QEMU build list also omitted `s390x-softmmu`, which left libvirt
without a native s390x emulator and caused Nova compute to fail its QEMU
minimum-version check. `tools/build_snaps.sh` applies
`patches/snaps/openstack-hypervisor/qemu-s390x-target.patch`.

The old `ovs-vswitchd-symlink` patch is obsolete: current upstream stages
`openvswitch-switch` directly, so the patch no longer applies and has been
removed.

### Nova ACPI on s390x

The first guest boot can fail with:

```text
machine type 's390-ccw-virtio-*' does not support ACPI
```

This is the Nova s390x ACPI bug tracked as LP #2043987. Treat this as a manual
s390x requirement unless the selected `openstack-hypervisor` snap is known to
stage a Nova build with the workaround.

For local validation builds, `tools/build_snaps.sh` adds
`patches/snaps/openstack-hypervisor/nova-acpi-ppa.patch` (or merges the PPA into
an existing `package-repositories` block) so the snap stages Nova from
`ppa:himax16/s390x-nova-acpi`. The PPA entry carries `priority: 1001`; the UCA
repository is pinned at 1000, so without that override apt keeps the unpatched
UCA Nova. Verify the installed snap with:

```bash
zgrep -m1 '^nova (' /snap/openstack-hypervisor/current/usr/share/doc/python3-nova/changelog.Debian.gz
```

Phase 03b warns by default if the patched Nova is missing; set
`HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1` to make that a hard failure.

The old `cinder-volume-ceph-library-triplet` patch is obsolete: current
upstream uses `$CRAFT_ARCH_TRIPLET_BUILD_FOR` in the app library path.
`tools/build_snaps.sh` now builds a local `cinder-volume` snap when patches are
present, but phase 03b only installs the hypervisor snap. Install the local
cinder-volume snap manually when validating the Ceph 20.2.4/aes256k fix; the
published snap remains the default otherwise.

Phase 04 uses Ubuntu's `python3-openstackclient` package. Installing the latest
client from PyPI on s390x can fall back to compiling `cryptography` with Rust
because upstream wheels are unavailable. That approach is slower, less
reproducible, and may fail on hosts with restricted egress.

## Artifact bundle contents

Each `artifacts/<run-id>/` contains:

- `env.txt` and `arch_report.md` (the primary s390x availability matrix)
- `phase_<N>_<name>.log` — timestamped output from each phase
- `juju_bundle_<model>.yaml`, `juju_status_<model>.txt`, `juju_status_relations_<model>.txt`, and `juju_offers.txt`
- `juju_status_watch.log` — background status captured during deployment
- `k8s_resources.yaml`, `k8s_events.txt`, `k8s_nodes_describe.txt`, `snaps.txt`
- `manual-cloud.yaml`, `manual_host_ip`, `lb_cidr`, `get-admin-account.json`
- `cloud-admin-openrc`, `ca_bundle.pem` (if 04 ran)
- `tempest/` + `tempest_report/` (if 06 ran)
- `smoke_server.yaml`, `smoke_volume.yaml` (if 04b ran)
- `sunbeam-<arch>-<run-id>.tar.zst`
- `test-share/` and `test-share-<arch>-<run-id>.tar.zst`, containing a flat,
  human-reviewable report matching the legacy `openstack-charmers/test-share`
  s390x file names: `README.md`, `juju_status.txt`,
  `catalog_list.txt`, `hypervisor_list.txt`, `image_list.txt`,
  `network_list.txt`, `network_agent_list.txt`,
  `network_extension_list.txt`, `ceph_tests.txt`, `instance_launch.txt`,
  `instance_ssh.txt`, `openstack_origin.txt`, and `tempest_smoke.txt`.
  Sunbeam-specific bundle and Kubernetes evidence remains in the full
  diagnostic archive.

## Load balancer (most likely failure point)

`traefik-k8s` requires an external `LoadBalancer` IP. Without one, keystone's
`public_endpoint` (and therefore the openrc `OS_AUTH_URL`) never resolves, and
phases 04 and 06 cannot be used. Phase 02b enables the Canonical Kubernetes
load-balancer add-on and sets an L2 address pool (`LB_CIDR`). The bundle
requests a `LoadBalancer` Traefik service, so the add-on assigns an external
IP from its own pool. On s390x the
image rewrite also aligns the MetalLB probes with the upstream images: the
liveness/readiness paths become `/metrics` on the workload's `--port`, and the
speaker probe host is cleared because the upstream speaker binds the node IP.
Skipping that leaves the controller and speaker in `CrashLoopBackOff` even
though the upstream binaries are healthy. Verify the service addresses with
`sudo k8s kubectl get svc -A` before relying on phase 04.

## Reset between runs

```bash
juju destroy-controller sunbeam-controller --destroy-all-models --no-prompt || true
juju remove-cloud lpar-manual --client || true
juju remove-cloud sunbeam-k8s --client || true
sudo k8s kubectl delete pod k8s-smoke --ignore-not-found || true
sudo snap remove --purge k8s juju openstack-hypervisor microceph cinder-volume microovn || true
sudo rm -rf /var/lib/juju
sudo rm -rf /var/snap/k8s ~/.local/share/juju
```

Then start a fresh run with `./run.sh all`.

## Canonical Kubernetes s390x prerequisites

The Canonical Kubernetes snap does not work out of the box on s390x: its default
CNI (Cilium) has no IBM Z or POWER build, and several bundled add-on images at
`ghcr.io/canonical/...` are not published for s390x. The Performance Engineering
and IBM Z Alliances team maintains a working recipe in
[canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
(branch `c-k8s-and-calico-experimental`). Phase 02b implements that recipe:

1. Run `sudo k8s bootstrap --file <cfg>` with `network.enabled: false` (no Cilium).
2. Apply the patched Calico manifest with
   `sudo k8s kubectl apply -f vendor/pe-ibm/calico.yaml`.
3. Remove Metrics Server on s390x; OpenStack does not require it.
4. Enable the DNS, local-storage, and load-balancer add-ons. The s390x path
   removes the unused CSI resizer and snapshotter sidecars and rewrites the
   required CSI and MetalLB sidecars to upstream multi-architecture images.
5. Use a locally built `rawfile-localpv:0.8.3` s390x image. Canonical's
   `ghcr.io/canonical/rawfile-localpv:0.8.3-ck2` currently has no s390x image.
   The source recipe is
   [canonical/rawfile-localpv-rocks](https://github.com/canonical/rawfile-localpv-rocks).
6. A smoke pod confirms scheduling, image pull, and pod networking on the LPAR.
7. Before phase 03 starts, a test PVC and its consumer pod must bind and become
   Ready, and MetalLB must have both its controller and speaker running.

Phase 02b writes the generated bootstrap configuration, resolved `LB_CIDR`,
rawfile image choice, Kubernetes resources, node descriptions, and recent events
into the run artifact directory. If phase 03 later fails in Juju, check those
files first; many apparent charm failures are actually image-pull, PVC, or
load-balancer problems in the underlying Kubernetes layer.

Useful live diagnostics:

```bash
sudo k8s kubectl get nodes
sudo k8s kubectl get pods -A
sudo k8s kubectl get events -A --sort-by=.lastTimestamp | tail -40
sudo k8s status
```

Do not continue to Juju merely because the node is `Ready`: the PVC and
LoadBalancer gates must also pass. Phase 02b exits non-zero if Calico, the
rawfile CSI workloads, the test PVC, or the MetalLB controller/speaker fail to
become ready. Fix the substrate, remove
`artifacts/<run-id>/.status/02b_setup_s390x_cni.done`, and re-run phase 02b.
`SUBSTRATE_STRICT=0` keeps the old diagnostic-only behaviour but must not be
used for a deployment run.

### Build rawfile-localpv locally on the LPAR

A Launchpad remote build is not required. On the Noble s390x LPAR, install
Rockcraft and LXD, then run the repository helper:

```bash
sudo snap install rockcraft --classic
sudo snap install lxd
sudo lxd init --auto
./tools/build_rock.sh rawfile-localpv \
  --repo https://github.com/canonical/rawfile-localpv-rocks.git \
  --source-dir "$HOME/builds/rawfile-localpv-rocks-s390x" \
  --subdir . \
  --tag docker.io/library/rawfile-localpv:0.8.3-s390x
```

The patch is discovered automatically from
`patches/rocks/rawfile-localpv/s390x.patch`; it adds the s390x platform,
makes `grpcio` use Ubuntu's OpenSSL, and drops the `openssl-fips-module-3`
stage package (not published for s390x). Otherwise, `grpcio`'s bundled BoringSSL
fails with `Unknown target CPU` on s390x. The generated protobuf modules are
committed upstream, so the runtime image does not need `grpcio-tools`.

Phase 02b imports the resulting `.rock` through
`/run/containerd/containerd.sock` and tags it as
`docker.io/library/rawfile-localpv:0.8.3-s390x`. It discovers the rock under
`$HOME/builds/rawfile-localpv-rocks-s390x/` or uses `RAWFILE_LOCALPV_ROCK` if
set. Phase 02b rewrites the add-on's rawfile driver to that local tag. Override
the tag with `RAWFILE_LOCALPV_IMAGE` if needed. If rawfile CSI pods are already
running and stuck in ImagePullBackOff, phase 02b deletes them once so kubelet
retries the imported tag.

If the LPAR's proxy blocks the redirect from `registry.k8s.io` to `*.pkg.dev`,
sideload the registrar and provisioner from a workstation with Docker and
direct registry access:

```bash
./tools/sideload_s390x_k8s_images.sh ubuntu@10.103.192.218
```

The helper uses containerized Skopeo to select the s390x manifests, transfers
OCI archives over SSH, imports them through Canonical Kubernetes' containerd
socket, and restarts the rawfile CSI pods. A successful result shows controller
`1/1` and node `3/3`:

```bash
sudo k8s kubectl -n kube-system get pods \
  -l app.kubernetes.io/name=rawfile-csi
```

### Vendoring workflow

Before the first run, populate `vendor/pe-ibm/`:

```bash
./tools/refresh_pe_ibm.sh
```

## Tempest

Phase 06 follows the structure of the
[zopenstack](https://github.com/ubuntu-openstack/zopenstack) workflow (`grep
FAILED`, artifact and report capture, and per-test re-runs) with substitutions
appropriate for Sunbeam:

1. **`tempest.conf` is generated by upstream `python-tempestconf`** against the
   live cloud using the openrc produced in phase 04, without a charmed OpenStack
   template.
2. **No Kubernetes-charm-specific code.** Per-service diagnostics use the openrc
   and the `openstack` CLI instead of parsing `juju status keystone`.
3. **Distro Tempest is the default.** Phase 06 installs the distribution
   `tempest` and plugin packages, then runs `tempest run --smoke --serial`.
   Set `TEMPEST_PLUGIN_MODE=upstream` to use the isolated upstream Tempest
   virtual environment without distro plugin packages. In upstream mode, set
   `TEMPEST_USE_TOX=1` if you want to exercise upstream Tempest's tox
   environment; on lab hosts behind internal proxies, tox may fail while
   fetching OpenStack upper-constraints.

Debug logging for `python-tempestconf` is disabled by default because it may
write authentication material to `tempestconf.log`. Set `TEMPESTCONF_DEBUG=1`
only when you need verbose configuration-generation traces and will handle the
resulting artifacts as sensitive.

With compute and block storage deployed, the full smoke suite (booting an
instance and creating a volume) is meaningful. This repository vendors only the
**exclude list** from zopenstack (under [vendor/zopenstack/](vendor/zopenstack/)).
The default exclusions currently cover:

- Charmed Keystone policy tests inherited from zopenstack. Re-evaluate them
  against keystone-k8s as policy coverage improves.
- `tempest.scenario.test_network_basic_ops.TestNetworkBasicOps.test_network_basic_ops`,
  because it requires the validation host to ping floating IPs allocated from
  `EXT_SUBNET_POOL`. Many LPAR lab networks can create provider-network
  resources but do not route that floating-IP range back to the runner. Remove
  this exclusion when your external network is genuinely reachable from the
  Tempest host.

The default phase 06 run uses distribution Tempest + plugins, matching the
legacy charmed OpenStack reports. To use upstream-only Tempest instead, run:

```bash
TEMPEST_PLUGIN_MODE=upstream ./run.sh 06
```

On Resolute, distribution Tempest currently needs a small Python compatibility
shim: `neutron-tempest-plugin` still imports `testtools.try_import` during
discovery, but Resolute's `testtools` package no longer provides that helper.
Phase 06 writes a temporary `sitecustomize.py` under the run's Tempest artifact
directory and adds it only to the default distro Tempest process. This avoids
modifying system packages and lets unavailable-service plugin classes be
discovered and reported as skips, matching the legacy report style.

### Re-running a single test

```bash
./tools/run_tempest_test.sh 'test_dashboard_basic_ops.TestDashboardBasicOps.test_basic_scenario'
```

The helper defaults to the most recent run ID; pass `--run-id <id>` to target a
specific run.

## Channel pins (subject to change)

The static bundles pin the 2026.1/Noble profile. `OPENSTACK_SERIES=hibiscus`
(the default) renders the Hibiscus/Resolute profile through
[tools/render_release_bundles.py](tools/render_release_bundles.py). Override the
individual `*_CHANNEL` defaults in [scripts/01_install_prereqs.sh](scripts/01_install_prereqs.sh)
or the renderer variables in "Useful environment overrides" if Sunbeam publishes
a non-edge risk level.

| Component             | 2026.1 / Noble | 2026.2 / Resolute |
|-----------------------|----------------|-------------------|
| `juju` snap           | `3/stable` | `3/stable` |
| `k8s` snap            | `latest/edge` | `latest/edge` |
| Core `*-k8s` charms   | `2026.1/edge`, `ubuntu@24.04` | `2026.2/edge`, `ubuntu@26.04` |
| `microovn`            | `26.03/edge`, `ubuntu@24.04` | `26.03/edge`, `ubuntu@26.04` |
| `sunbeam-ovn-proxy`   | `2026.1/edge`, `ubuntu@24.04` | `2026.2/edge`, `ubuntu@26.04` |
| `microcluster-token-distributor` | `v1/stable` (no s390x Charmhub revision; local build required) | `v1/stable` (same) |
| `mysql-k8s`           | `8.0/stable` | `8.0/stable` |
| `mysql-router-k8s`    | `8.0/edge` | `8.0/edge` |
| `rabbitmq-k8s`        | `3.12/edge` (no s390x Charmhub revision; hybrid/local build required) | `4.0/edge` (no s390x Charmhub revision; local build required) |
| `traefik-k8s`         | `latest/edge` on `ubuntu@26.04` | `latest/edge` |
| `self-signed-certificates` | `1/edge` on `ubuntu@24.04` | `1/edge` |
| `openstack-hypervisor`/`openstack-network-agents`/`cinder-volume`/`cinder-volume-ceph`/`sunbeam-machine` | `2026.1/edge`, `ubuntu@24.04` | `2026.2/edge`, `ubuntu@26.04` |
| `microceph` charm     | `squid/stable` (no s390x revision; hybrid/local build required) | `tentacle/edge`, `ubuntu@26.04` |
| `microceph` snap      | `squid/stable` (s390x revision exists) | `tentacle/edge` (s390x revision exists) |
