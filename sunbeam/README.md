# Sunbeam s390x single-LPAR core charm validation

**Known release profiles**: 2026.1 Gazpacho (Noble) and 2026.2 Hibiscus
(Resolute, default). Any later `YYYY.N` release is accepted by the renderers;
unprofiled releases default to `<release>/edge`, the latest known Ubuntu base,
and the latest independent charm tracks. Override `BASE_OS` or the per-channel
variables as needed.

This repository deploys the core Sunbeam charms on one IBM Z LPAR using
plain Juju bundles. It does not use the `sunbeam` CLI.

The workflow is diagnostic-first. It:

- bootstraps Canonical Kubernetes;
- deploys a Kubernetes control plane and a machine plane as two Juju bundles;
- records s390x availability for snaps, charms, rocks, and OCI images;
- runs a Tempest smoke suite when the cloud is healthy;
- produces a full diagnostic archive and a compact test-share report.

It writes artifacts even when deployment fails, so missing s390x builds are
reported instead of hidden.

**Why bundles?** Deploying the charms directly tests the charm topology without
depending on `snap-openstack` working end to end on s390x. This isolates
machine-plane failures and produces precise per-artifact architecture gaps.

**Expected outcome:** the workflow has completed on Noble and Resolute s390x
LPARs. A fresh run still depends on the selected channels publishing the
required s390x artifacts. Missing artifacts are listed in `arch_report.md`.

## Requirements

- Ubuntu 24.04 LTS (Noble) or 26.04 LTS (Resolute) on s390x. The default
  profile is 2026.2/Hibiscus on 26.04. Use `OPENSTACK_SERIES=gazpacho` for
  2026.1/Noble; `MACHINE_BASE=ubuntu@24.04` keeps only the machine plane on
  Noble.
- Passwordless `sudo` for the deployment user.
- Key-based SSH back to the host. Phase 02 creates and authorizes a key for the
  Juju manual cloud.
- Outbound HTTPS access to Canonical Kubernetes, Juju, Charmhub, the Snap
  Store, `ghcr.io`, `docker.io`, and `registry.k8s.io`.
- Python 3 with `python3-yaml`. Phase 01 installs it.
- At least 32 GB RAM and 200 GB free disk.
- `/dev/kvm` for Nova instances. Phase 00 checks and records it.
- The s390x Nova ACPI workaround described in
  [Nova ACPI on s390x](#nova-acpi-on-s390x) unless the selected hypervisor snap
  already includes it.

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
  machine model's `ovsdb-cms` offer during phase 05.
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

The external/provider network is created by phase 06 and is not a per-tenant
network. Phase 05 deploys `openstack-network-agents` as a subordinate of
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
action maps `${EXT_BRIDGE:-br-ex}:${EXT_PHYSNET:-physnet1}:${EXT_NIC}`; phase 06
creates the external network with the matching `EXT_NET_TYPE`/`EXT_VLAN_ID` and
a `provider-router`, mirroring the legacy `neutron-ext-net-ksv3` profile.

The older internal-bridge fallback (`EXTERNAL_BRIDGE_ADDRESS`, for example
`.1` on `br-ex`) is still accepted when no extra NIC is available, but it is
not a routed external network.

Phase 07 validates floating-IP SSH without requiring an external client. With
the default `SMOKE_SSH_NETNS=1`, it creates a temporary network namespace, adds a
veth port to `EXT_BRIDGE` (tagged with `EXT_VLAN_ID` for a VLAN provider
network), assigns a client IP on the external subnet, and runs SSH to the FIP
from that namespace. The namespace and veth are removed during cleanup. Set
`SMOKE_SSH_NETNS=0` to use the old host-route path.

## Kubernetes substrate

This deployment uses **Canonical Kubernetes** (the `k8s` snap), not MicroK8s.
Phase 03 creates a single-node cluster on the LPAR, and phase 04 registers it
with Juju as the CAAS cloud for the `openstack` model.

On s390x, phase 03 uses a modified bootstrap path because the default Cilium
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

## Fresh LPAR setup

These commands prepare a freshly installed Ubuntu 24.04 or 26.04 s390x LPAR and
start the complete workflow. Run them as the deployment user, not as `root`.

The workflow requires passwordless `sudo`:

```bash
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-sunbeam
sudo chmod 0440 /etc/sudoers.d/90-sunbeam
```

There are two supported paths.

### Path A: supplied artifacts

Use this when you saved a phase-99 `local-artifacts` archive from the old LPAR.
Always clone the repo from GitHub.

```bash
git clone https://github.com/ubuntu-openstack/zopenstack.git ~/zopenstack
cd ~/zopenstack/sunbeam
source tools/proxy_env.sh
./tools/setup_proxy.sh

# From the workstation:
./artifacts.py stage ubuntu@<lpar>
./artifacts.py csi ubuntu@<lpar> --upload-only
```

Then set the deploy environment and run phases `00` through `09`, followed by
`99`.

### Path B: build all artifacts

Use this when no saved artifacts are available.

```bash
sudo apt-get update
sudo apt-get install -y git ca-certificates squashfs-tools
git clone https://github.com/ubuntu-openstack/zopenstack.git ~/zopenstack
cd ~/zopenstack/sunbeam
source tools/proxy_env.sh
./tools/setup_proxy.sh

command -v charmcraft >/dev/null || sudo snap install charmcraft --classic
command -v snapcraft  >/dev/null || sudo snap install snapcraft --classic
command -v rockcraft  >/dev/null || sudo snap install rockcraft --classic
command -v lxd        >/dev/null || sudo snap install lxd
sudo lxd init --auto >/dev/null 2>&1 || true
lxc network set lxdbr0 ipv6.address none
sudo snap install astral-uv --classic

export OPENSTACK_SERIES=hibiscus
CHARMCRAFT_DESTRUCTIVE=1 ./build.py charms
./build.py snaps
./build.py csi
./build.py rocks --rock rabbitmq

# From a host with direct registry access:
./artifacts.py csi ubuntu@<lpar> --upload-only
```

Then set the deploy environment and run phases `00` through `09`, followed by
`99`.

### Deploy environment

```bash
export OPENSTACK_SERIES=hibiscus
export CHARM_SOURCE=hybrid
export RABBITMQ_IMAGE=ghcr.io/canonical/rabbitmq:4.0.5-26.04_edge
export BUILD_LOCAL_SNAPS=0
export HYPERVISOR_SNAP_PATH="$PWD/snaps/openstack-hypervisor_s390x.snap"
export CINDER_VOLUME_SNAP_PATH="$PWD/snaps/cinder-volume_s390x.snap"
export RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
```

```bash
./run.sh --run-id "$RUN_ID" 00
./run.sh --run-id "$RUN_ID" 01
./run.sh --run-id "$RUN_ID" 02
./run.sh --run-id "$RUN_ID" 03
./run.sh --run-id "$RUN_ID" 04
./run.sh --run-id "$RUN_ID" 05
./run.sh --run-id "$RUN_ID" 06
./run.sh --run-id "$RUN_ID" 07
./run.sh --run-id "$RUN_ID" 08
./run.sh --run-id "$RUN_ID" 09
./run.sh --run-id "$RUN_ID" 99
```

For Ubuntu 24.04 (Noble) and 2026.1/Gazpacho, set
`OPENSTACK_SERIES=gazpacho`.

Phase 02 creates and authorizes an SSH key for the Juju manual cloud. Configure
a proxy before cloning and before `run.sh` when required; see
[Behind a proxy](#behind-a-proxy).

## Behind a proxy

Set `PROXY_URL` before running a phase. The phase scripts pass it to the shell,
APT, Juju, and the Kubernetes snap services through
[tools/setup_proxy.sh](tools/setup_proxy.sh).

```bash
export PROXY_URL=http://squid.internal:3128
export NO_PROXY_DEFAULT='localhost,127.0.0.1,::1,<host-ip>,<host-subnet>,10.1.0.0/16,10.152.183.0/24,.svc,.cluster.local,.charmhub.io,charmhub.io,.jujucharms.com,registry.jujucharms.com,streams.canonical.com,ubuntu-cloud.archive.canonical.com,api.snapcraft.io,.snapcraftcontent.com'
export NO_PROXY="$NO_PROXY_DEFAULT"
export no_proxy="$NO_PROXY_DEFAULT"
./run.sh all
```

`NO_PROXY_DEFAULT` must include the Kubernetes API and the direct-only hosts:
Charmhub, Juju streams, the Ubuntu Cloud Archive, and the Snap Store. The phase
scripts set `NO_PROXY` internally. Interactive commands such as `juju status`
need it in the shell as well.

A combined assignment such as
`export NO_PROXY_DEFAULT=... NO_PROXY="$NO_PROXY_DEFAULT"` expands the old
value and can leave `NO_PROXY` empty. The symptom is
`juju add-k8s: Forbidden` because the Kubernetes API request went through Squid.

For repeatable host configuration, copy and edit the example file:

```bash
cp proxy.env.example proxy.env
$EDITOR proxy.env
source tools/proxy_env.sh
./tools/setup_proxy.sh
```

`tools/setup_proxy.sh` reads `PROXY_ENV_FILE` or `proxy.env` and applies the
values to `/etc/environment`, APT, snapd, and the Kubernetes snap services.
`tools/proxy_env.sh` exports the same values in the current shell and adds the
host IP to `NO_PROXY` for interactive Juju.

**Snap Store exception:** snapd has no `proxy.no-proxy` setting, so its only
options are "use the proxy for everything" or "use the proxy for nothing".
Direct Snap Store access normally works. `setup_proxy.sh` therefore leaves the
snapd proxy unset by default. Set `SNAP_PROXY=1` only when snapd cannot reach
the store directly.

Both `snap.k8s.k8sd.service` and `snap.k8s.containerd.service` need the proxy.
Verify their environment with:

```bash
sudo systemctl show snap.k8s.k8sd.service -p Environment --no-pager
sudo systemctl show snap.k8s.containerd.service -p Environment --no-pager
curl -I --connect-timeout 30 https://ghcr.io/v2/
```

On PS6, the Squid allowlist must cover `ghcr.io`, `docker.io`,
`registry.k8s.io`, `quay.io`, and registry redirects such as
`*.docker.pkg.dev`. The `ps6_s390x_openstack` ACL in
[canonical-is-internal-proxy-configs](https://launchpad.net/canonical-is-internal-proxy-configs)
covers special18 through special22 (10.103.192.218-10.103.192.222). Other LPARs
need a follow-up maintenance request.

## Output

`./run.sh all` creates `artifacts/<UTC-timestamp>/` and runs every phase. On
completion it produces:

- `sunbeam-<arch>-<run-id>.tar.zst` — full diagnostic archive.
- `test-share-<arch>-<run-id>.tar.zst` — compact publishable validation report,
  modelled on the
  [openstack-charmers/test-share s390x results](https://github.com/openstack-charmers/test-share/tree/master/s390x/2025-dec/noble-flamingo-ovn/multi-lpar).

### Running a single phase

```bash
./run.sh 00          # host suitability check
./run.sh 03          # Kubernetes and Calico setup
./run.sh 04          # control-plane bundle deployment
./run.sh 05          # machine-plane bundle deployment
./run.sh --run-id 20260617T120000Z 06   # re-run configuration in an existing run
```

All phases are idempotent. Each writes `.status/<phase>.done` and skips itself on
a later run unless you delete the sentinel.

Each phase writes full command output to
`artifacts/<run-id>/phase_<phase>.log`. The terminal shows one `RUN`/`OK` line
per command; failures include the full output. Set `RUN_LOGGED_VERBOSE=1` to
stream it live.

## Building artifacts

[build.py](build.py) is the single entry point for the local s390x artifacts. It
selects the existing builders; it does not duplicate their clone, patch, or pack
logic.

```bash
./build.py                         # charms + snaps + rawfile CSI rock
./build.py charms
./build.py snaps
./build.py csi
./build.py all --rock rabbitmq
./build.py rocks --rock rabbitmq --rock cinder-consolidated
ROCKS="rabbitmq cinder-consolidated" ./build.py rocks
./build.py --dry-run all          # print commands without building
```

`all` builds the charms, the machine snaps, and the `rawfile-localpv` CSI rock.
Generic `ubuntu-openstack-rocks` images are built only when named with `--rock`,
`--rocks`, or `ROCKS`. Use `--keep-going` to continue after a failed component.

Artifacts are staged where the deployment expects them:

| Artifact | Location |
|---|---|
| Charms | `./charms/<charm>_s390x.charm` |
| Snaps | `./snaps/<snap>_s390x.snap` |
| Generic rocks | `./rocks/<rock>_s390x.rock` |
| CSI rock | `./rocks/rawfile-localpv_s390x.rock` |

Run the build on s390x with `charmcraft`, `snapcraft`, `rockcraft`, and LXD
installed. The detailed build sections below document source selection,
patches, and per-component overrides.

### Local opendev mirrors

Only needed for Path B (building charms from source). Path A uses prebuilt
artifacts and does not need the mirrors.

If the build host cannot reach `opendev.org`, pack the required bare mirrors on
a host that can, then unpack them on the LPAR:

```bash
# On the host with opendev access
./artifacts.py mirrors pack
# writes artifacts/local-mirrors-<UTC>.tar.zst and .sha256

# Upload and unpack on the LPAR
./artifacts.py mirrors all ubuntu@<lpar>

# Or separately
./artifacts.py mirrors upload ubuntu@<lpar>
./artifacts.py mirrors unpack ubuntu@<lpar>
```

The pack helper mirrors these repositories by default:

- `openstack/sunbeam-charms`
- `openstack/charm-ops-interface-ceph-client`
- `openstack/charm-ops-interface-tls-certificates`

Add more with `--repo NAME=URL`; use `--no-default-repos` for a custom set. The
archive contains bare repositories and a `manifest.tsv` with each URL and HEAD
commit.

The unpack helper extracts to `artifacts/local-mirrors`, verifies the manifest
commits, and configures `git insteadOf` rewrites for the current user and root.
It also creates `$HOME/sunbeam-charms-src` as a compatibility symlink. Use
`--no-git-config` to extract without changing Git configuration.

## Phases

| #   | Script                          | Purpose                                                                                |
|-----|---------------------------------|----------------------------------------------------------------------------------------|
| 00  | `00_check_host.sh`              | Verify the target architecture, Ubuntu release, passwordless sudo, and endpoint connectivity; record environment, network, and KVM facts. |
| 01  | `01_install_prereqs.sh`         | Install prerequisites and Juju; check target architecture snaps and bundles.            |
| 02  | `02_prepare_node.sh`            | Prepare the host (kernel modules and `/dev/kvm` check) and configure key-based SSH to itself for the manual cloud. |
| 03  | `03_setup_s390x_cni.sh`         | Bootstrap Canonical Kubernetes, validate networking and storage, and **configure the load-balancer pool**. |
| 04  | `04_bootstrap.sh`               | Register the cluster with Juju, bootstrap the controller, add the `openstack` model, and deploy the control-plane bundle. |
| 05  | `05_deploy_machine_plane.sh`    | Create the manual cloud and `machines` model, enrol the LPAR as machine 0, deploy the machine bundle (microovn, proxy, network agents), map `EXT_NIC`, and wire `storage-backend` and `ovsdb-cms`. |
| 06  | `06_configure.sh`               | Obtain an openrc through `keystone get-admin-account`; create the external network (flat/VLAN provider network), provider router, flavors, and s390x image with the OpenStack CLI. |
| 07  | `07_smoke_cloud.sh`             | Boot a guest, attach a Cinder volume, assign a floating IP, and verify SSH from a temporary provider-network namespace. |
| 08  | `08_capture_state.sh`           | Capture per-model `juju export-bundle`, `status`, and `offers`; dump Kubernetes resources; sweep snap and OCI s390x availability. |
| 09  | `09_validate_tempest.sh`        | Run Tempest smoke tests: generate `tempest.conf` with `discover-tempest-config`, then install/run distro Tempest + plugins by default (`TEMPEST_PLUGIN_MODE=upstream` for upstream-only), and record failures. |
| 99  | `99_collect_artifacts.sh`       | Build the full diagnostic archive, the compact test-share-compatible report, and a standalone local-artifacts archive (charms, snaps, rocks). |

In `./run.sh all` mode, a blocking failure skips the dependent phases and
proceeds directly to phases 08 and 99, so a post-mortem tarball is always
produced.

## Key files

- [run.sh](run.sh) — the deployment entry point. It uses `LC_ALL=C` sorting so that phase `03` runs before `05`, and phase `02` runs before `03`.
- [build.py](build.py) — the single build entry point for charms, snaps, generic rocks, and the rawfile CSI rock.
- [tools/pack_local_mirrors.sh](tools/pack_local_mirrors.sh) — pack bare opendev mirrors on a host with opendev access.
- [tools/unpack_local_mirrors.sh](tools/unpack_local_mirrors.sh) — extract the mirrors and configure Git `insteadOf` rewrites on the LPAR.
- [manifests/control-plane-k8s-s390x.yaml](manifests/control-plane-k8s-s390x.yaml) —
  the Kubernetes control-plane bundle and its cross-model offers.
- [manifests/machine-lpar-s390x.yaml](manifests/machine-lpar-s390x.yaml) — the
  machine-plane bundle. It consumes control-plane offers and exports
  `storage-backend` and `ovsdb-cms`.
- [tools/lib.sh](tools/lib.sh) — logging, idempotency, `juju_wait_settle`, and
  architecture-report helpers.
- [tools/build_local_charms.sh](tools/build_local_charms.sh) — fresh-clone and
  build the s390x hybrid charms into `./charms/`.
- [tools/install_local_artifacts.sh](tools/install_local_artifacts.sh) — stage a
  phase-99 `local-artifacts` archive/directory into `./charms`, `./snaps`, and
  `./rocks`; optional `--install-snaps` and `--import-rocks`.
- [artifacts.py](artifacts.py) — unified CLI for listing, verifying, packaging,
  uploading, staging, installing, fetching, CSI-sideloading, and packing or
  uploading opendev mirrors.
- [tools/sideload_s390x_artifacts.sh](tools/sideload_s390x_artifacts.sh) — upload
  a local-artifacts archive to an SSH target as `local-artifacts.tar.zst`,
  stage/install it, and optionally sideload the CSI sidecar images. The old
  `tools/sideload_s390x_k8s_images.sh` is a wrapper for the `csi` command.
- [tools/build_snaps.sh](tools/build_snaps.sh) — discover snap patch directories
  and build every corresponding s390x snap into `./snaps/`.
- [tools/build_rock.sh](tools/build_rock.sh) — fresh-clone a rockcraft project,
  apply discovered rock patches, build it for s390x, and stage it in `./rocks/`.
- [rocks/README.md](rocks/README.md) — staging directory for built `.rock` files.
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
  references from bundles. Phase 08 also checks the images that are running in
  the cluster, because `juju export-bundle` records resource revisions rather
  than OCI references. It reads only `spec.containers[].image` and
  `spec.initContainers[].image`; pod status `image` fields are local
  `sha256:...` IDs, not pullable references. The report note records the
  namespace/pod and Juju application using each image, for example
  `used by openstack/keystone-0 (keystone)`. When the image is present in
  containerd, the note also says `remote image` for registry/cached images or
  `local image` for a single-platform `linux/s390x` tag, which is what a
  locally built/imported image looks like.
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

Phases 04 and 05 deploy the same topology from one of three charm sources,
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
  phase 04 or 05 and record the gaps. The phase 01 preflight reports these
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
./run.sh 04 && ./run.sh 05
# The published stack plus the unpublished Noble/s390x charms. Set
# RABBITMQ_IMAGE to an s390x RabbitMQ rock (the published tag has no s390x).
RABBITMQ_IMAGE=<your-s390x-rabbitmq-rock> \
CHARM_SOURCE=hybrid ./run.sh 04 && CHARM_SOURCE=hybrid ./run.sh 05
# 2026.2/Hibiscus hybrid mode. Pass OPENSTACK_SERIES to phase 05 too.
OPENSTACK_SERIES=hibiscus RABBITMQ_IMAGE=<s390x-rock> \
CHARM_SOURCE=hybrid ./run.sh 04 && \
OPENSTACK_SERIES=hibiscus CHARM_SOURCE=hybrid ./run.sh 05
# Local s390x charm builds.
CHARM_SOURCE=local ./run.sh 04 && CHARM_SOURCE=local ./run.sh 05
```

### Build the local hybrid charms

Use `./build.py charms` as the single entry point. The underlying builder is
[tools/build_local_charms.sh](tools/build_local_charms.sh); it builds the hybrid
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

Use `./build.py snaps` as the single entry point. The underlying builder is
[tools/build_snaps.sh](tools/build_snaps.sh); it builds every snap that has a
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

Phase 05 builds the local snaps by default before deploying the machine
bundle. It installs both the local `openstack-hypervisor` and
`cinder-volume` snaps before deploying the machine bundle; set
`CINDER_VOLUME_SNAP_PATH` or `HYPERVISOR_SNAP_PATH` explicitly to use
prebuilt snaps. Set `BUILD_LOCAL_SNAPS=0` to disable building. The build uses
`snapcraft pack --destructive-mode`; `NO_PROXY_DEFAULT` includes
`ubuntu-cloud.archive.canonical.com`, and `build_snaps.sh` also enforces that
bypass, because the Squid allowlist rejects the UCA while direct access works.

A locally built snap is not store-declared, so snapd does not auto-connect its
interfaces before the configure hook. Phase 05 installs it with
`snap install --dangerous --devmode` and then explicitly connects
`hardware-observe`, `system-observe`, `mount-observe`, `block-devices`,
`network-control`, `network-observe`, `process-control`,
`kernel-module-control`, `kernel-module-observe`, `hugepages-control`, `kvm`,
`libvirt`, `iscsi-initiator`, `nvme-control`, `raw-usb`, `firewall-control`,
`dm-multipath`, `microstack-support`, `etc-driverctl`, and `mdevctl-config`.
It also connects the `ovn-chassis` and `ovn-env` content interfaces to
`microovn` and links `microovn`'s switch socket under the hypervisor's
`SNAP_DATA`; without that path `nova-compute` cannot plug OVS VIFs. Because the
local snap is devmode, phase 05 sets the hypervisor charm's
`experimental-devmode` option to match; published strict snaps leave it unset.
For a local `cinder-volume` snap, phase 05 also sets
`snap-channel=""` and `experimental-devmode=true` on the `cinder-volume`
charm. A local snap has no store channel, so the charm's default
`snap-channel` would make it run `snap refresh --channel=...`, which snapd
rejects for a local snap. Phase 05 then connects
`hardware-observe`, `block-devices`, `network-observe`, `network-control`,
`mount-observe`, `process-control`, and `system-observe`, and restarts it.

Phase 05 also reconnects the `ovn-chassis` content interface of
`openstack-network-agents` and `ovn-exporter` after microovn creates its
`run/switch/db.sock`, then restarts `ovn-exporter`. snapd can leave those
content mounts empty when the charms connect before microovn bootstraps; the
reconnect prevents the network-agent `configure-snap` timeout and the
microovn `metrics endpoint is not reachable` block.

### Build a rock from ubuntu-openstack-rocks

Use `./build.py rocks --rock <name>` as the single entry point.
[tools/build_rock.sh](tools/build_rock.sh) is the generic builder for rocks in
`canonical/ubuntu-openstack-rocks`. It clones a fresh checkout into
`.rock-build/`, builds `rocks/<rock>` for s390x, stages the result as
`./rocks/<rock>_s390x.rock`, and optionally pushes it to an OCI registry with
`--push`.

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
./tools/build_rock.sh rabbitmq --ref main \
  --push <registry>/rabbitmq:2026.2-s390x
```

If you omit `--push`, the tool stages the `.rock` in
`./rocks/<rock>_s390x.rock` for a separate
`skopeo copy oci-archive:<rock> docker://<registry>/<image>:<tag>`.

The same tool builds other rocks, for example:

```bash
./tools/build_rock.sh rabbitmq --ref main \
  --push registry.example/rabbitmq:2026.2-s390x
./tools/build_rock.sh cinder-consolidated --ref main \
  --push registry.example/cinder-consolidated:2026.2-s390x
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
(preflight), phase 04 (control-plane rendering), and phase 05 (machine
rendering). `BASE_OS` and `MACHINE_BASE` can override the base, but the
published 2026.2 s390x charms support only `ubuntu@26.04`, so a different base
requires local builds.

## Useful environment overrides

| Variable | Default | Used by |
|----------|---------|---------|
| `TARGET_ARCH` | `s390x` | all phases (architecture checks and the guest image); only `s390x` is supported |
| `PROXY_URL` | unset | all (proxy setup) |
| `PROXY_ENV_FILE` | `proxy.env` if present | proxy manifest read by `setup_proxy.sh`/`proxy_env.sh` |
| `NO_PROXY_DEFAULT` | private ranges + cluster suffixes + Charmhub/Juju/UCA/Snap Store | all phases (proxy bypass; phase 04 appends the API host) |
| `SNAP_PROXY` | `0` | `setup_proxy.sh` — leave snapd's proxy unset so the Snap Store is reached directly; set `1` when snapd must use the proxy |
| `CHECK_NETWORK` | `1` | 00 — set `0` to skip endpoint reachability checks |
| `CHECK_NET_TIMEOUT` | `30` | 00 — curl timeout in seconds per endpoint |
| `CHECK_SNAP_API_TIMEOUT` | `30` | 01 — Snap Store API timeout in seconds |
| `CHECK_SNAP_CLI_TIMEOUT` | `30` | 01 — `snap info` timeout in seconds |
| `RUN_LOGGED_VERBOSE` | `0` | all `run_logged` commands — stream full command output to the terminal; full output is always in `phase_<phase>.log` |
| `CHARM_BUILD_DIR` | `.charm-build` | `tools/build_local_charms.sh` fresh checkout directory |
| `SNAP_HYPERVISOR_BRANCH` | `stable/<release from OPENSTACK_SERIES>` | `tools/build_snaps.sh`; falls back to `feat/<release>` and `main` |
| `SNAP_CINDER_BRANCH` | `main` | `tools/build_snaps.sh` |
| `SNAP_HYPERVISOR_REPO` / `SNAP_HYPERVISOR_FALLBACK_REPO` | canonical repo / unset | `tools/build_snaps.sh` |
| `SNAP_CINDER_REPO` / `SNAP_CINDER_FALLBACK_REPO` | canonical repo / unset | `tools/build_snaps.sh` |
| `SNAP_PATCH_ROOT` | `patches/snaps` | `tools/build_snaps.sh`; every subdirectory is built |
| `SNAP_BUILD_DIR` / `SNAP_OUT_DIR` | `.snap-build` / `snaps` | `tools/build_snaps.sh` |
| `ROCK_PATCH_ROOT` | `patches/rocks` | `tools/build_rock.sh`; patches are read from `<root>/<rock>` |
| `BUILD_LOCAL_SNAPS` | `1` | 05 — build all locally patched snaps; install the local hypervisor snap |
| `SUBSTRATE_STRICT` | `1` | 03 — fail if Calico/rawfile CSI/PVC/MetalLB readiness gates fail |
| `RAWFILE_LOCALPV_IMAGE` | `docker.io/library/rawfile-localpv:0.8.3-s390x` | 03 local-storage image tag |
| `RAWFILE_LOCALPV_ROCK` | auto-discovered under `rocks/` or `$HOME/builds/rawfile-localpv-rocks-s390x/` | 03 — `.rock` to import into Canonical Kubernetes containerd when the image is absent |
| `LB_CIDR` | derived `<host /24>.240-.250` | 03 load-balancer pool; set this explicitly to a reserved, unused L2 range |
| `K8S_CHANNEL` | `latest/edge` | 01/03 |
| `JUJU_CHANNEL` | `3/stable` | 01 |
| `JUJU_CONTROLLER` / `K8S_MODEL` / `MACHINE_MODEL` / `MANUAL_CLOUD` | `sunbeam-controller` / `openstack` / `machines` / `lpar-manual` | 04/05/06/08/09 |
| `CHARM_SOURCE` | `charmhub` | 04/05 — `charmhub`, `hybrid`, or `local` (see "Charm sources") |
| `BUNDLE` | per-phase `*-s390x.yaml` | 04/05 — explicit bundle path; overrides `CHARM_SOURCE` |
| `OPENSTACK_SERIES` | `hibiscus` (2026.2) | 01/04/05 — selects the release profile, core/machine charm channels, and `ubuntu@26.04`; `gazpacho` selects 2026.1/`ubuntu@24.04`; also selects `stable/<release>` in the local builders |
| `BASE_OS` | release profile (`ubuntu@26.04` / `ubuntu@24.04`) | 04/05 — Ubuntu base for the rendered control-plane and machine bundles |
| `RABBITMQ_IMAGE` | unset; required for hybrid | hybrid — OCI image from the same track as the RabbitMQ charm; must have an s390x manifest |
| `MACHINE_BASE` | unset; `ubuntu@26.04` for Hibiscus | 05 — explicit machine base override |
| `MACHINE_CHANNEL` / `MICROCEPH_CHARM_CHANNEL` / `MICROOVN_CHANNEL` / `OVN_PROXY_CHANNEL` / `TOKEN_DISTRIBUTOR_CHANNEL` | release profile (`2026.2/edge`, `tentacle/edge`, `26.03/edge`, `2026.2/edge`, `v1/stable`) | 05 — channel overrides for the rendered machine bundle |
| `HYPERVISOR_CHANNEL` / `CINDER_VOLUME_CHANNEL` / `MICROCEPH_CHANNEL` / `MICROOVN_SNAP_CHANNEL` / `OVN_EXPORTER_CHANNEL` | release profile (`2026.2/edge`, `2026.2/edge`, `tentacle/edge`, `26.03/stable`, `stable`) | 01 — snap arch checks |
| `ALLOW_UNSUPPORTED_HOST_BASE` | `0` | 01 preflight — allow a non-24.04 host for control-plane/tooling diagnostics |
| `HYPERVISOR_SNAP_PATH` | built by `tools/build_snaps.sh` when `BUILD_LOCAL_SNAPS=1` | 05 — install this local `openstack-hypervisor` snap with `snap install --dangerous` before the machine charm configures it; a local devmode snap also sets the charm's `experimental-devmode` so the charm accepts it (strict published snaps leave it unset) |
| `CINDER_VOLUME_SNAP_PATH` | built by `tools/build_snaps.sh` when `BUILD_LOCAL_SNAPS=1` | 05 — install this local `cinder-volume` snap with `snap install --dangerous --devmode` before the machine bundle is deployed; a local devmode snap also sets the charm's `snap-channel=""` and `experimental-devmode=true` so the charm does not try to refresh it from the store |
| `MICROOVN_EXPORTER_RISK` | `edge` on s390x | 05 — microovn `ovn_exporter_risk`; the stable exporter's `content: microovn-run-switch` plug does not match the microovn slot, while edge connects successfully |
| `HYPERVISOR_EXPECT_NOVA_ACPI_PATCH` | `auto` | 05 — on s390x, `auto` or `warn` issues a warning if the installed hypervisor snap does not stage Nova with the LP #2043987 ACPI workaround; set `1` to fail early |
| `HYPERVISOR_SKIP_CEPH_SECRET_CONFIG` | `auto` | 05 — seed `/var/snap/openstack-hypervisor/common/skip-ceph-secret-config` before deploy; `auto` enables it on s390x |
| `HYPERVISOR_DISABLE_SPICE` | `auto` | 05 — write a Nova config override disabling SPICE graphics on s390x QEMU |
| `HYPERVISOR_DISABLE_VTPM` | `auto` | 05 — write a Nova config override disabling vTPM on s390x; the current libvirt build reports no vTPM support and Nova otherwise refuses to start |
| `DEPLOY_TIMEOUT` | `3600` | 04/05 settle wait |
| `READINESS_TIMEOUT` | value of `DEPLOY_TIMEOUT` | 05 — final per-model wait for every unit workload to become active |
| `EXT_NET_NAME` / `EXT_SUBNET_RANGE` / `EXT_SUBNET_GW` / `EXT_SUBNET_POOL` / `EXT_PHYSNET` | external-network / 10.13.3.0/24 / .1 / .200-.230 / physnet1 | 05/06/07/09 |
| `EXT_NIC` | auto-discovered when exactly one safe candidate exists | 05 — physical host NIC mapped to `br-ex`/physnet1 by `openstack-network-agents`; set explicitly if discovery is ambiguous |
| `EXT_BRIDGE` | `br-ex` | 05 — OVS bridge name used in the network-agents mapping |
| `EXT_NET_TYPE` / `EXT_VLAN_ID` | `vlan` / `2893` | 06 — external network provider type and VLAN ID (`vlan` requires a trunked `EXT_NIC`) |
| `EXT_PROVIDER_ROUTER` | `provider-router` | 06 — router connected to the external gateway |
| `EXTERNAL_BRIDGE_ADDRESS` | unset | 05 — legacy local-bridge address (for example `172.16.2.1/24`); when `EXT_NIC` is set it configures `openstack-network-agents` instead of the hypervisor |
| `NETWORK_AGENTS_CHANNEL` / `NETWORK_AGENTS_SNAP_CHANNEL` | release profile (`2026.2/edge` for Hibiscus) | 01/05 — Charmhub channel and pre-install channel for `openstack-network-agents` |
| `IMAGE_URL` | release guest cloud image for `TARGET_ARCH` | 06 — overrides the complete guest image URL |
| `TEMPEST_IMAGE_URL` | release guest cloud image for `TARGET_ARCH` | 09 — overrides the image used by `discover-tempest-config` |
| `CINDER_READY_ATTEMPTS` / `CINDER_READY_INTERVAL` | `30` / `10` | 07 — wait for the `cinder-volume` service to become up before volume tests |
| `SMOKE_IMAGE` | `ubuntu` | 07 — Glance image used for the smoke guest |
| `SMOKE_VALIDATE_SSH` / `SMOKE_SSH_USER` | `1` / `ubuntu` | 07 — floating-IP SSH acceptance check |
| `SMOKE_SSH_NETNS` | `1` | 07 — run FIP SSH from a temporary veth/network namespace on the provider bridge; set `0` to use the host network |
| `SMOKE_CLIENT_IP` | derived from `EXT_SUBNET_RANGE` | 07 — address assigned to the temporary FIP client; override if it collides |
| `SMOKE_CONFIG_DRIVE` | `true` | 07 — pass Nova metadata/network data via config-drive; required for reliable s390x guest networking in the LPAR test cloud |
| `SMOKE_SSH_INITIAL_SLEEP` / `SMOKE_SSH_ATTEMPTS` / `SMOKE_SSH_INTERVAL` | `90` / `30` / `10` | 07 — SSH proof timing after floating-IP association |
| `TEMPEST_PLUGIN_MODE` | `distro` | 09 — `distro` installs/runs the distribution Tempest plugin set for legacy charmed OpenStack test-count parity; `upstream` uses upstream Tempest only |
| `TEST_SHARE_NOTES_FILE` | unset | 99 — optional Markdown file appended as "Notes and known issues" in the publishable report |

Phase 04 sets the Juju model constraint `arch=$TARGET_ARCH` before deploying
applications, so all CAAS pods are scheduled on the s390x LPAR.

The current `traefik-k8s` s390x revision on `latest/edge` uses `ubuntu@26.04`
and Python 3.14. It contains a `google._upb._message` extension that segfaults
while importing OpenTelemetry protobuf modules. Phase 04 disables that optional
accelerator inside Traefik's charm virtual environment, so that protobuf falls
back to its pure-Python implementation. Set `TRAEFIK_DISABLE_BROKEN_UPB=0` once
a fixed revision is published.

Phase 04 fails on unresolved `ErrImagePull` and `ImagePullBackOff` states, but
it does not require every workload to be active before phase 05. Cinder is
expected to block until the machine-plane storage offer exists. Nova may also
briefly report a conductor crash loop because its Pebble liveness check runs
while the service is deliberately disabled pending relations. Evaluate final
unit health after phase 05 connects both models.

Phase 05 discovers the actual Juju ID of the enrolled manual machine and maps
bundle machine `0` to it. Juju does not reuse IDs after a failed enrolment, so
hard-coding `0=0` can create an impossible extra machine on the manual provider.

On s390x, phase 05 seeds `skip-ceph-secret-config` before deployment to avoid
an early Ceph/libvirt ordering failure in the hypervisor snap. Set
`HYPERVISOR_SKIP_CEPH_SECRET_CONFIG=0` when testing a snap that should handle
this itself.

Phase 05 builds the local hypervisor snap automatically (see "Build the local
machine snaps"). To use an existing snap instead, set `BUILD_LOCAL_SNAPS=0` and
provide `HYPERVISOR_SNAP_PATH`. The script installs it with `--dangerous`, holds
refreshes, and lets the charm configure it:

```bash
BUILD_LOCAL_SNAPS=0 \
HYPERVISOR_SNAP_PATH=/path/openstack-hypervisor_s390x.snap \
HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1 \
OPENSTACK_SERIES=hibiscus CHARM_SOURCE=hybrid \
./run.sh --run-id <run-id> 08
```

For client-facing s390x validation, set `HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1`
so that the run fails before guest boot if the workaround is missing.

After the machine model settles, phase 05 also applies the current s390x
runtime fixes: it connects the `mdevctl-config` plug, disables SPICE, defines the
libvirt RBD secret, and restarts the hypervisor services.

On Resolute, the supported path is the 2026.2/Hibiscus profile:

```bash
OPENSTACK_SERIES=hibiscus ./run.sh all
# Or run only the machine plane in an existing run:
OPENSTACK_SERIES=hibiscus ./run.sh --run-id <run-id> 08
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

Phase 05 has two distinct gates. First, it waits for Juju agents to finish
their hooks; then it requires every unit in both the `machines` and `openstack`
models to report an active workload. An idle agent with a blocked, waiting, or
error workload therefore fails the phase instead of producing a false success.

The first s390x `openstack-hypervisor` revision tested on Noble
(`2026.1/edge`, snap revision 646, June 25, 2026) had a strict-confinement gap:
`libvirtd` could not monitor `/etc/mdevctl.d`, exited, and the configure hook
subsequently failed because `virtqemud-sock` did not exist. The correct
snap-side fix is a read-only `system-files` plug for `/etc/mdevctl.d` connected
to the `libvirtd` app. Phase 05 detects this exact failure and stops with a
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

Phase 05 warns by default if the patched Nova is missing; set
`HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1` to make that a hard failure.

The old `cinder-volume-ceph-library-triplet` patch is obsolete: current
upstream uses `$CRAFT_ARCH_TRIPLET_BUILD_FOR` in the app library path.
`tools/build_snaps.sh` now builds a local `cinder-volume` snap when patches are
present, but phase 05 only installs the hypervisor snap. Install the local
cinder-volume snap manually when validating the Ceph 20.2.4/aes256k fix; the
published snap remains the default otherwise.

Phase 06 uses Ubuntu's `python3-openstackclient` package. Installing the latest
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
- `source_provenance.txt` — source remotes, commit hashes, dirty state, and
  artifact checksums
- `image_package_versions.txt` — apt package inventory from running containers
- `manual-cloud.yaml`, `manual_host_ip`, `lb_cidr`, `get-admin-account.json`
- `cloud-admin-openrc`, `ca_bundle.pem` (if 04 ran)
- `tempest/` + `tempest_report/` (if 06 ran)
- `local-artifacts/` — local `charms/*.charm`, `snaps/*.snap`, and
  `rocks/*.rock`, plus `SHA256SUMS`, `README.md`, and `source_provenance.txt`
- `local-artifacts-<arch>-<run-id>.tar.zst` — standalone archive of
  `local-artifacts/` for sharing or re-use on another host

### Consuming local artifacts

```bash
# List and verify local artifacts
./artifacts.py list
./artifacts.py verify

# Package charms/snaps/rocks into a local-artifacts archive
./artifacts.py package

# From the workstation: upload, stage, install snaps/rocks, and sideload CSI
./artifacts.py all ubuntu@<lpar>

# Upload only, using the newest artifacts/*/local-artifacts-*.tar.zst
./artifacts.py upload ubuntu@<lpar>

# Stage only (after upload)
./artifacts.py stage ubuntu@<lpar>

# CSI sidecars only
./artifacts.py csi ubuntu@<lpar>

# Upload CSI sidecars before phase 03; phase 03 imports them
./artifacts.py csi ubuntu@<lpar> --upload-only

# Download the newest local-artifacts and CSI sidecars from the LPAR
# (rsync checksums skip unchanged files)
./artifacts.py fetch ubuntu@<lpar>

# Only selected components
./artifacts.py fetch ubuntu@<lpar> --only local-artifacts,test-share
./artifacts.py fetch ubuntu@<lpar> --only csi
./artifacts.py fetch ubuntu@<lpar> --only diagnostic,test-share

# Download a specific run, including the full run directory
./artifacts.py fetch ubuntu@<lpar> --run-id <run-id> --full

# Pack, upload, and unpack opendev mirrors
./artifacts.py mirrors pack
./artifacts.py mirrors all ubuntu@<lpar>
```

The remote archive is always named `local-artifacts.tar.zst`, so no run ID is
needed. On the LPAR, the equivalent local staging command is:

```bash
tools/install_local_artifacts.sh local-artifacts.tar.zst
```

Manual equivalent:

```bash
tar --zstd -xf local-artifacts-s390x-<run-id>.tar.zst
cd local-artifacts
sha256sum -c SHA256SUMS

# Charms
juju deploy ./charms/<name>_s390x.charm <application>

# Snaps
sudo snap install --dangerous --devmode ./snaps/<name>_s390x.snap

# Rocks
sudo k8s images import --base-name <repository> ./rocks/<name>_s390x.rock
```

The full diagnostic tarball also contains `local-artifacts/`; the standalone
archive is provided so the binaries can be shared without the rest of the
diagnostic data.
- `smoke_server.yaml`, `smoke_volume.yaml` (if 07 ran)
- `sunbeam-<arch>-<run-id>.tar.zst`
- `test-share/` and `test-share-<arch>-<run-id>.tar.zst`, containing a flat,
  human-reviewable report matching the legacy `openstack-charmers/test-share`
  s390x file names: `README.md`, `juju_status.txt`,
  `catalog_list.txt`, `hypervisor_list.txt`, `image_list.txt`,
  `network_list.txt`, `network_agent_list.txt`,
  `network_extension_list.txt`, `ceph_tests.txt`, `instance_launch.txt`,
  `instance_ssh.txt`, `openstack_origin.txt`, `source_provenance.txt`,
  `image_package_versions.txt`, and `tempest_smoke.txt`.

## Load balancer (most likely failure point)

`traefik-k8s` requires an external `LoadBalancer` IP. Without one, keystone's
`public_endpoint` (and therefore the openrc `OS_AUTH_URL`) never resolves, and
phases 06 and 09 cannot be used. Phase 03 enables the Canonical Kubernetes
load-balancer add-on and sets an L2 address pool (`LB_CIDR`). The bundle
requests a `LoadBalancer` Traefik service, so the add-on assigns an external
IP from its own pool. On s390x the
image rewrite also aligns the MetalLB probes with the upstream images: the
liveness/readiness paths become `/metrics` on the workload's `--port`, and the
speaker probe host is cleared because the upstream speaker binds the node IP.
Skipping that leaves the controller and speaker in `CrashLoopBackOff` even
though the upstream binaries are healthy. Verify the service addresses with
`sudo k8s kubectl get svc -A` before relying on phase 06.

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
(branch `c-k8s-and-calico-experimental`). Phase 03 implements that recipe:

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
7. Before phase 04 starts, a test PVC and its consumer pod must bind and become
   Ready, and MetalLB must have both its controller and speaker running.

Phase 03 writes the generated bootstrap configuration, resolved `LB_CIDR`,
rawfile image choice, Kubernetes resources, node descriptions, and recent events
into the run artifact directory. If phase 04 later fails in Juju, check those
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
LoadBalancer gates must also pass. Phase 03 exits non-zero if Calico, the
rawfile CSI workloads, the test PVC, or the MetalLB controller/speaker fail to
become ready. Fix the substrate, remove
`artifacts/<run-id>/.status/03_setup_s390x_cni.done`, and re-run phase 03.
`SUBSTRATE_STRICT=0` keeps the old diagnostic-only behaviour but must not be
used for a deployment run.

### Build rawfile-localpv locally on the LPAR

Use `./build.py csi` as the single entry point. A Launchpad remote build is not
required. On the Noble s390x LPAR, install Rockcraft and LXD, then run:

```bash
sudo snap install rockcraft --classic
sudo snap install lxd
sudo lxd init --auto
./build.py csi
```

This stages `rocks/rawfile-localpv_s390x.rock`. The underlying command is:

```bash
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

Phase 03 imports the resulting `.rock` through
`/run/containerd/containerd.sock` and tags it as
`docker.io/library/rawfile-localpv:0.8.3-s390x`. It discovers
`rocks/rawfile-localpv*.rock` first, then
`$HOME/builds/rawfile-localpv-rocks-s390x/`, or uses `RAWFILE_LOCALPV_ROCK` if
set.

Phase 01 preflight fails early if the default rawfile image is selected, the
image is not already in containerd, and no local rock or image tar is staged. Phase 03 rewrites the add-on's rawfile driver to that local tag. Override
the tag with `RAWFILE_LOCALPV_IMAGE` if needed. If rawfile CSI pods are already
running and stuck in ImagePullBackOff, phase 03 deletes them once so kubelet
retries the imported tag.

If the LPAR's proxy blocks the redirect from `registry.k8s.io` to `*.pkg.dev`,
sideload the registrar and provisioner from a workstation with Docker and
direct registry access:

```bash
./artifacts.py csi ubuntu@10.103.192.218
```

The helper uses containerized Skopeo to select the s390x manifests, transfers
OCI archives over SSH, imports them through Canonical Kubernetes' containerd
socket, and restarts the rawfile CSI pods. `tools/sideload_s390x_k8s_images.sh`
remains as a wrapper for this command. A successful result shows controller
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

Phase 09 follows the structure of the
[zopenstack](https://github.com/ubuntu-openstack/zopenstack) workflow (`grep
FAILED`, artifact and report capture, and per-test re-runs) with substitutions
appropriate for Sunbeam:

1. **`tempest.conf` is generated by upstream `python-tempestconf`** against the
   live cloud using the openrc produced in phase 06, without a charmed OpenStack
   template.
2. **No Kubernetes-charm-specific code.** Per-service diagnostics use the openrc
   and the `openstack` CLI instead of parsing `juju status keystone`.
3. **Distro Tempest is the default.** Phase 09 installs the distribution
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

The default phase 09 run uses distribution Tempest + plugins, matching the
legacy charmed OpenStack reports. To use upstream-only Tempest instead, run:

```bash
TEMPEST_PLUGIN_MODE=upstream ./run.sh 09
```

On Resolute, distribution Tempest currently needs a small Python compatibility
shim: `neutron-tempest-plugin` still imports `testtools.try_import` during
discovery, but Resolute's `testtools` package no longer provides that helper.
Phase 09 writes a temporary `sitecustomize.py` under the run's Tempest artifact
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
