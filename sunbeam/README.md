# Sunbeam s390x single-LPAR core-charm verifier (2026.1 Gazpacho)

A set of idempotent shell scripts that deploy the **core Sunbeam charms** on a
single Z LPAR **as plain Juju bundles** (no `sunbeam` CLI), capture every
architecture-availability signal along the way, and run an upstream Tempest pass.

This is **diagnostic-first**: the scripts bring up Canonical K8s, deploy two Juju
bundles (a K8s control plane + a machine plane), and record what worked and what
didn't (including which snaps/OCI images have no s390x build), producing a tarball
of artifacts whether or not the deployment fully succeeds.

> **Why bundles instead of `sunbeam`?** The Sunbeam CLI couples the whole exercise
> to snap-openstack working end-to-end on s390x. Deploying the charms directly
> with `juju deploy <bundle>` lets us validate the core charm topology, isolate
> machine-plane issues, and feed precise per-image/per-snap arch gaps back
> upstream.

> **Realistic outcome:** this workflow has completed on Noble and Resolute s390x
> LPARs. A fresh run still depends on the selected channels publishing the needed
> s390x charms, rocks, and snaps; missing artifacts are reported in
> `arch_report.md`.

## What gets deployed

Two Juju models on one controller (mirrors how Sunbeam splits things internally):

- **`openstack`** — a CAAS model on the Canonical K8s cloud, from
  [manifests/control-plane-k8s-s390x.yaml](manifests/control-plane-k8s-s390x.yaml):
  `mysql`, `rabbitmq`, `self-signed-certificates`, `traefik`, `ovn-central`,
  `ovn-relay`, `keystone`, `glance`, `placement`, `nova`, `neutron`, `cinder`
  (+`cinder-router`). Exports cross-model **offers** (amqp, identity-*, send-ca-cert,
  ovsdb-cms, certificates, nova-service, cinder-database).
- **`machines`** — an IAAS model on a **manual** cloud whose machine `0` is this LPAR,
  from [manifests/machine-lpar-s390x.yaml](manifests/machine-lpar-s390x.yaml):
  `sunbeam-machine`, `openstack-hypervisor`, `microceph`, `cinder-volume`,
  `cinder-volume-ceph`. Consumes the control-plane offers and exports
  `storage-backend` back to `cinder`.

The set mirrors the previous charmed-OpenStack LPAR validation bundle
([zopenstack noble-flamingo-edge](https://github.com/ubuntu-openstack/zopenstack/blob/main/bundles/lpar/noble-flamingo-edge.yaml))
— keystone/glance/nova/neutron/placement/cinder + a real compute hypervisor + ceph
block storage — but with the Sunbeam charms. **No feature charms** (horizon, heat,
octavia, magnum, manila, barbican, designate, ironic, telemetry, object storage). And
**no `tempest-k8s`** in the bundle: that charm has no s390x OCI image, so Tempest runs
via upstream `tox` (phase 06) instead.

## Kubernetes substrate

This deployment uses **Canonical K8s** (`k8s` snap), not MicroK8s. Phase 02b
creates a single-node cluster on the LPAR and phase 03 registers it with Juju as
the CAAS cloud for the `openstack` model.

On s390x, phase 02b uses a modified bootstrap path because the default Cilium
CNI and some Canonical addon images are not available for s390x:

- bootstrap Canonical K8s with networking disabled;
- apply the vendored PE/IBM Calico manifest;
- enable only the required addons: DNS, local-storage, and load-balancer;
- use a locally built or sideloaded s390x `rawfile-localpv` image for local
  persistent volumes;
- configure the load-balancer L2 pool from `LB_CIDR`.

Do not proceed to Juju until the node is `Ready`, Calico is running, a PVC can
bind, and a `LoadBalancer` service receives an IP from the configured pool.

## Prerequisites

- Ubuntu 24.04 LTS (Noble) on s390x for the default complete two-model
  workflow.
- Ubuntu 26.04 LTS (Resolute) is supported for validation, but run phase 03b
  with `MACHINE_BASE=ubuntu@26.04` so the host-facing machine charms are placed
  on a Resolute manual machine. This requires published or local machine charms
  for `s390x/ubuntu/26.04`.
- A user with passwordless `sudo` **and** key-based SSH back to the host (phase 02
  sets this up — it's needed to enrol the LPAR as a Juju manual machine).
- Outbound internet (Snap Store, ghcr.io, docker.io, charmhub) — see "Behind a proxy".
- ~32 GB RAM, ~200 GB disk.
- `/dev/kvm` (s390x KVM) for Nova to actually launch instances. Phase 02 records
  whether it's present.
- On s390x, plan for the Nova ACPI workaround described in
  [Nova ACPI on s390x](#nova-acpi-on-s390x).

## Behind a proxy

Set `PROXY_URL` before running anything; the phase scripts configure shell env,
`/etc/environment`, apt, snap, and the K8s snap's containerd via
[tools/setup_proxy.sh](tools/setup_proxy.sh):

```bash
export PROXY_URL=http://squid.internal:3128
export NO_PROXY_DEFAULT='localhost,127.0.0.1,::1,<host-ip>,<host-subnet>,10.1.0.0/16,10.152.183.0/24,.svc,.cluster.local,.charmhub.io,charmhub.io,.jujucharms.com,registry.jujucharms.com,streams.canonical.com'
./run.sh all
```

Define `NO_PROXY_DEFAULT` before deriving `NO_PROXY`. A combined assignment
such as `export NO_PROXY_DEFAULT=... NO_PROXY="$NO_PROXY_DEFAULT"` expands the
old value and can leave `NO_PROXY` empty. The symptom is `juju add-k8s`
failing with `Get "https://<node>:6443/...": Forbidden` because the Kubernetes
API request went through Squid. Phase 03 now applies `NO_PROXY_DEFAULT`
defensively.

The ps6 Squid currently rejects CONNECT requests to `api.charmhub.io`, while
the LPAR can reach it directly. Keep `.charmhub.io,charmhub.io` in
`NO_PROXY_DEFAULT`; phase 03 propagates that bypass into both Juju models.
The same applies to `registry.jujucharms.com`, which containerd uses for charm
OCI resources. Include `.jujucharms.com,registry.jujucharms.com`, then rerun
`tools/setup_proxy.sh` so the updated bypass reaches the containerd service.
Manual-machine enrolment also downloads the Juju agent index from
`streams.canonical.com`, which must bypass this Squid deployment.

Both `snap.k8s.k8sd.service` and `snap.k8s.containerd.service` need the proxy:
`k8sd` reconciles addons, while containerd pulls OCI images. Verify with:

```bash
sudo systemctl show snap.k8s.k8sd.service -p Environment --no-pager
sudo systemctl show snap.k8s.containerd.service -p Environment --no-pager
curl -I --connect-timeout 15 https://ghcr.io/v2/
```

The helper can also be run directly after exporting `PROXY_URL` and
`NO_PROXY_DEFAULT`; it derives its repository/run context automatically.

On ps6 the Squid allowlist must cover the OCI registries (`ghcr.io`, `docker.io`,
`registry.k8s.io`, `quay.io`) and registry redirects such as
`*.docker.pkg.dev`. The `ps6_s390x_openstack` ACL in
[canonical-is-internal-proxy-configs](https://launchpad.net/canonical-is-internal-proxy-configs)
already covers special18-22 (10.103.192.218-.222); other LPARs need a follow-up MP.

## Quickstart

```bash
cd s390x-sunbeam
./run.sh all
```

This creates `artifacts/<UTC-timestamp>/`, runs every phase in order, and on
completion gives two deliverables:

- `sunbeam-<arch>-<run-id>.tar.zst` — complete diagnostic archive.
- `test-share-<arch>-<run-id>.tar.zst` — compact, publishable validation report
  modelled on the
  [openstack-charmers/test-share s390x results](https://github.com/openstack-charmers/test-share/tree/master/s390x/2025-dec/noble-flamingo-ovn/multi-lpar).

### Running a single phase

```bash
./run.sh 00          # host-fitness check
./run.sh 02b         # K8s + Calico bring-up
./run.sh 03          # control-plane bundle deploy
./run.sh 03b         # machine-plane bundle deploy
./run.sh --run-id 20260617T120000Z 04   # re-run configure in an existing run dir
```

Phases are idempotent: each writes `.status/<phase>.done` and short-circuits on
re-run unless you delete the sentinel.

## Phases

| #   | Script                          | Does                                                                                  |
|-----|---------------------------------|---------------------------------------------------------------------------------------|
| 00  | `00_check_host.sh`              | Assert target architecture + supported Ubuntu base; dump env/network/KVM facts         |
| 01  | `01_install_prereqs.sh`         | Install prerequisites and Juju; check target-arch snaps and bundles                    |
| 02  | `02_prepare_node.sh`            | Host prep (kernel modules, `/dev/kvm` check) + key-based SSH-to-self for manual cloud |
| 02b | `02b_setup_s390x_cni.sh`        | Bootstrap Canonical K8s, validate networking/storage, and **configure LB pool**         |
| 03  | `03_bootstrap.sh`               | `juju add-k8s` + `bootstrap` + `add-model openstack` + deploy control-plane bundle    |
| 03b | `03b_deploy_machine_plane.sh`   | Manual cloud + `machines` model + enrol LPAR as machine 0 + deploy machine bundle + wire `storage-backend` |
| 04  | `04_configure.sh`               | openrc via `keystone get-admin-account`; external network, flavors, s390x image (openstack CLI) |
| 04b | `04b_smoke_cloud.sh`             | Boot a guest, attach a Cinder volume, assign a floating IP, and prove SSH access       |
| 05  | `05_capture_state.sh`           | Per-model `juju export bundle`/`status`/`offers`, k8s dump, OCI/snap s390x sweep       |
| 06  | `06_validate_tempest.sh`        | Upstream tempest: `discover-tempest-config` → `tempest.conf`, `tox -e smoke`, failures |
| 99  | `99_collect_artifacts.sh`       | Build full diagnostics plus a compact test-share-compatible report                    |

In `./run.sh all` mode, a blocking failure skips dependent phases and proceeds
directly to 05 + 99 so you always get a post-mortem tarball.

## Key files

- [run.sh](run.sh) — entry point (LC_ALL=C sort runs `03` before `03b`, `02` before `02b`)
- [manifests/control-plane-k8s-s390x.yaml](manifests/control-plane-k8s-s390x.yaml) —
  K8s control-plane bundle + cross-model offers
- [manifests/machine-lpar-s390x.yaml](manifests/machine-lpar-s390x.yaml) — machine-plane
  bundle (consumes offers, exports `storage-backend`)
- [tools/lib.sh](tools/lib.sh) — logging, idempotency, `juju_wait_settle`, arch-report helpers
- [tools/check_snap_arch.sh](tools/check_snap_arch.sh) / [tools/check_oci_arch.sh](tools/check_oci_arch.sh) —
  s390x availability per snap channel / per OCI image
- [tools/extract_oci_images.sh](tools/extract_oci_images.sh) — scrape image refs from the exported bundle
- [tools/refresh_pe_ibm.sh](tools/refresh_pe_ibm.sh) — re-vendor the Calico manifest + coredns rewrite
  from [canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
- [tools/rewrite_k8s_addon_images.sh](tools/rewrite_k8s_addon_images.sh) — patch addon
  `ghcr.io/canonical/...` images to upstream registries with s390x builds
- [tools/run_tempest_test.sh](tools/run_tempest_test.sh) — re-run a single tempest test
- [vendor/pe-ibm/](vendor/pe-ibm/), [vendor/zopenstack/](vendor/zopenstack/) — pinned snapshots

> The old `manifests/sunbeam-2026.1-s390x.yaml` was a *Sunbeam manifest* for the
> retired CLI path; it's kept only as a channel-pin reference. The live channel pins
> now live in the two bundle files.

## Charm source: Charmhub, hybrid, or local

Phases 03/03b deploy the same topology from one of three sources, selected by
`CHARM_SOURCE`:

- **`charmhub`** (default) — published charms on their `2026.1/edge` (etc.)
  channels, OCI images omitted so Juju pulls each revision's image. This is the
  diagnostic mode that surfaces per-image s390x gaps. Bundles:
  `manifests/control-plane-k8s-s390x.yaml`, `manifests/machine-lpar-s390x.yaml`.
- **`hybrid`** — the Noble/s390x qualification path while publication catches
  up. It generates bundles into the run artifact directory, using Charmhub for
  published components and these local artifacts:
  `rabbitmq-k8s_s390x.charm`, `microceph_s390x.charm`, and
  `cinder-volume-ceph_s390x.charm`. It also selects the currently available
  s390x TLS/Traefik channels and pins the RabbitMQ multi-architecture rock.
  Generated bundles use absolute paths for local charms because Juju resolves
  them relative to the bundle file under `artifacts/<run-id>/`.
- **`local`** — the Sunbeam charms we build for s390x, deployed from
  `./charms/*_s390x.charm` with their workload OCI images pinned to s390x rocks.
  This actually exercises our builds on the modified K8s substrate. Bundles:
  `manifests/control-plane-k8s-s390x-local.yaml`,
  `manifests/machine-lpar-s390x-local.yaml`. External dependencies we do **not**
  build (`mysql-k8s`, `rabbitmq-k8s`, `self-signed-certificates`, `traefik-k8s`,
  `mysql-router-k8s`, `microceph`) stay on charmhub in both modes.

```bash
# diagnostic, published charms (default)
./run.sh 03 && ./run.sh 03b
# published stack plus the three unpublished Noble/s390x charms
CHARM_SOURCE=hybrid ./run.sh 03 && CHARM_SOURCE=hybrid ./run.sh 03b
# our s390x builds
CHARM_SOURCE=local ./run.sh 03 && CHARM_SOURCE=local ./run.sh 03b
```

Hybrid mode fails preflight unless all three local charm files exist and declare
Ubuntu 24.04/s390x. Their expected location is `./charms/`.

For `local`: first stage the `.charm` files in `charms/` (see
[charms/README.md](charms/README.md)) and replace the `REPLACE-ME/...:s390x`
resource placeholders in `control-plane-k8s-s390x-local.yaml` with real s390x rock
refs. Heads-up: the external charmhub charms above still need their own s390x
images — check with `tools/check_oci_arch.sh` first, as a missing one there will
stall the deploy regardless of our charms.

## Useful environment overrides

| Variable | Default | Used by |
|----------|---------|---------|
| `TARGET_ARCH` | `s390x` | all (arch checks, guest image); only `s390x` is supported |
| `PROXY_URL` | unset | all (proxy setup) |
| `LB_CIDR` | derived `<host /24>.240-.250` | 02b load-balancer pool; set this explicitly to a reserved, unused L2 range |
| `K8S_CHANNEL` | `latest/edge` | 01/02b |
| `JUJU_CHANNEL` | `3/stable` | 01 |
| `JUJU_CONTROLLER` / `K8S_MODEL` / `MACHINE_MODEL` / `MANUAL_CLOUD` | `sunbeam-controller` / `openstack` / `machines` / `lpar-manual` | 03/03b/04/05/06 |
| `CHARM_SOURCE` | `charmhub` | 03/03b — `charmhub`, `hybrid`, or `local` (see "Charm source") |
| `BUNDLE` | per-phase `*-s390x.yaml` | 03/03b — explicit bundle path; overrides `CHARM_SOURCE` |
| `MACHINE_BASE` | unset | 03b — render a temporary machine bundle with this base, e.g. `ubuntu@26.04` for Resolute manual machines |
| `HYPERVISOR_SNAP_PATH` | unset | 03b — install this local `openstack-hypervisor` snap with `snap install --dangerous` before the machine charm configures it |
| `HYPERVISOR_EXPECT_NOVA_ACPI_PATCH` | `auto` | 03b — on s390x, `auto`/`warn` warns if the installed hypervisor snap does not stage Nova with the LP #2043987 ACPI workaround; set `1` to fail early |
| `HYPERVISOR_SKIP_CEPH_SECRET_CONFIG` | `auto` | 03b — seed `/var/snap/openstack-hypervisor/common/skip-ceph-secret-config` before deploy; `auto` enables it on s390x |
| `HYPERVISOR_DISABLE_SPICE` | `auto` | 03b — write a Nova config override disabling SPICE graphics on s390x QEMU |
| `DEPLOY_TIMEOUT` | `3600` | 03/03b settle wait |
| `READINESS_TIMEOUT` | value of `DEPLOY_TIMEOUT` | 03b — final per-model wait for every unit workload to become active |
| `EXT_NET_NAME` / `EXT_SUBNET_RANGE` / `EXT_SUBNET_GW` / `EXT_SUBNET_POOL` / `EXT_PHYSNET` | external-network / 172.16.2.0/24 / .1 / .50-.200 / physnet1 | 04 |
| `EXTERNAL_BRIDGE_ADDRESS` | unset | 03b — optional routed-provider address applied to the hypervisor's `br-ex` (for example `172.16.2.1/24` on a single-NIC nested VM) |
| `IMAGE_URL` | Noble cloud image for `TARGET_ARCH` | 04 |
| `SMOKE_VALIDATE_SSH` / `SMOKE_SSH_USER` | `1` / `ubuntu` | 04b — floating-IP SSH acceptance check |
| `SMOKE_CONFIG_DRIVE` | `true` | 04b — pass Nova metadata/network data via config-drive; required for reliable s390x guest networking in the LPAR test cloud |
| `SMOKE_SSH_INITIAL_SLEEP` / `SMOKE_SSH_ATTEMPTS` / `SMOKE_SSH_INTERVAL` | `90` / `30` / `10` | 04b — SSH proof timing after floating-IP association |
| `TEMPEST_PLUGIN_MODE` | `upstream` | 06 — set to `distro` to install and run the distro Tempest plugin set for legacy charmed-openstack test-count parity |
| `TEST_SHARE_NOTES_FILE` | unset | 99 — optional Markdown file appended as “Notes and known issues” in the publishable report |

Phase 03 sets the Juju model constraint `arch=$TARGET_ARCH` before deploying
applications so all CAAS pods are scheduled for the s390x LPAR.

The current `traefik-k8s` s390x revision on `latest/edge` uses
`ubuntu@26.04`/Python 3.14 and contains a `google._upb._message` extension that
segfaults while importing OpenTelemetry protobuf modules. Phase 03 disables
that optional accelerator inside Traefik's charm venv so protobuf falls back
to its pure-Python implementation. Set `TRAEFIK_DISABLE_BROKEN_UPB=0` once a
fixed revision is published.

Phase 03 fails on unresolved `ErrImagePull`/`ImagePullBackOff` states, but it
does not require every workload to be active before phase 03b. Cinder is
expected to block until the machine-plane storage offer exists. Nova may also
briefly report a conductor crash loop because its Pebble liveness check runs
while the service is deliberately disabled pending relations; evaluate final
unit health after phase 03b wires both models together.

Phase 03b discovers the actual Juju ID of the enrolled manual machine and maps
bundle machine `0` to it. Juju does not reuse IDs after failed enrolment, so
hard-coding `0=0` can otherwise create an impossible extra machine on the
manual provider.

On s390x, phase 03b seeds `skip-ceph-secret-config` before deployment to avoid
an early Ceph/libvirt ordering failure in the hypervisor snap. Set
`HYPERVISOR_SKIP_CEPH_SECRET_CONFIG=0` when testing a snap that should handle
this itself.

If you need a locally built hypervisor snap, including for the Nova ACPI
workaround, set `HYPERVISOR_SNAP_PATH` before phase 03b. The script installs
the snap with `--dangerous`, holds refreshes, and lets the charm configure it:

```bash
HYPERVISOR_SNAP_PATH=/home/ubuntu/resolute-reuse-artifacts/snaps/openstack-hypervisor_2026.1-nova33-s390x-acpi-skip-ceph_s390x.snap \
HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1 \
CHARM_SOURCE=hybrid MACHINE_BASE=ubuntu@26.04 \
./run.sh --run-id <run-id> 03b
```

For client-facing s390x validation, set `HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1`
so the run fails before guest boot if the workaround is missing.

After the machine model settles, phase 03b also applies the current s390x
runtime fixups: connect the `mdevctl-config` plug, disable SPICE, define the
libvirt RBD secret, and restart hypervisor services.

On Resolute, run phase 03b with an explicit machine base:

```bash
CHARM_SOURCE=charmhub MACHINE_BASE=ubuntu@26.04 ./run.sh --run-id <run-id> 03b
```

This validates the host-facing machine charms against the 26.04 manual machine.
If `juju add-machine` reports `machine is already provisioned` after a failed
attempt, destroy the failed `machines` model and remove stale Juju machine-agent
state before re-enrolling the LPAR.

Phase 03b has two distinct gates. It first waits for Juju agents to finish
hooks, then requires every unit in both the `machines` and `openstack` models
to report an active workload. An idle agent with a blocked, waiting, or error
workload is therefore a failed phase rather than a false success.

The first s390x `openstack-hypervisor` revision tested on Noble
(`2026.1/edge`, snap revision 646 on June 25, 2026) had a strict-confinement
gap: `libvirtd` could not monitor `/etc/mdevctl.d`, exited, and the configure
hook subsequently failed because `virtqemud-sock` did not exist. The correct
snap-side fix is a read-only `system-files` plug for `/etc/mdevctl.d` connected
to the `libvirtd` app. Phase 03b detects this exact failure and stops with a
packaging error; do not disable AppArmor to hide it. The tested source patch is
kept at `patches/openstack-hypervisor-mdevctl-system-files.patch` until an
equivalent fix is published.

The same initial s390x build also staged the non-DPDK `ovs-vswitchd` binary at
`usr/lib/openvswitch-switch/ovs-vswitchd` without the package-maintainer-created
`usr/sbin/ovs-vswitchd` link. This causes `ovsdb-server` startup to fail while
setting the OVS version. The source patch also creates that fallback symlink
when the DPDK binary is unavailable.

The initial QEMU build list also omitted `s390x-softmmu`, leaving libvirt
without a native s390x emulator and causing Nova compute to fail its QEMU
minimum-version check. Apply
`patches/openstack-hypervisor-qemu-s390x-target.patch` when building the local
s390x snap.

### Nova ACPI on s390x

The first guest boot can fail with:

```text
machine type 's390-ccw-virtio-*' does not support ACPI
```

This is the Nova s390x ACPI bug tracked as LP #2043987. Treat it as a manual
s390x requirement unless the selected `openstack-hypervisor` snap is known to
stage a Nova build with the workaround.

For local validation builds, use
`patches/openstack-hypervisor-nova-acpi-ppa.patch` so the snap stages Nova from
`ppa:mylesjp/nova-acpi-patch`. Verify the installed snap with:

```bash
zgrep -m1 '^nova (' /snap/openstack-hypervisor/current/usr/share/doc/python3-nova/changelog.Debian.gz
```

Phase 03b warns by default if the patched Nova is missing; set
`HYPERVISOR_EXPECT_NOVA_ACPI_PATCH=1` to make that a hard failure.

The first s390x `cinder-volume` snap retained an app-level
`x86_64-linux-gnu/ceph` library path, so its bundled `rados` and `rbd` Python
modules could not load `libceph-common.so.2`. Apply
`patches/cinder-volume-ceph-library-triplet.patch` for an
architecture-correct Ceph library path.

Phase 04 uses Ubuntu's `python3-openstackclient` package. Installing the latest
client from PyPI on s390x can fall back to compiling `cryptography` with Rust
because upstream wheels are unavailable; this is slower, less reproducible,
and may fail on restricted-egress hosts.

## Artifact bundle contents

Each `artifacts/<run-id>/` contains:

- `env.txt`, `arch_report.md` (the headline s390x availability matrix)
- `phase_<N>_<name>.log` — per-phase timestamped output
- `juju_bundle_<model>.yaml`, `juju_status_<model>.txt`, `juju_status_relations_<model>.txt`, `juju_offers.txt`
- `juju_status_watch.log` — background status during deploy
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
  Sunbeam-specific bundle/K8s evidence remains in the full diagnostic archive.

## Load-balancer (most likely stall point)

`traefik-k8s` needs an external `LoadBalancer` IP, or keystone's `public_endpoint`
(hence the openrc `OS_AUTH_URL`) never resolves and phase 04/06 are unusable. Phase
02b enables the Canonical K8s load-balancer addon and sets an L2 pool (`LB_CIDR`). The
bundle's traefik `metallb.universe.tf/address-pool=public` annotation is a no-op for
that addon — we rely on the addon's own pool. If the addon's L2 announcer (Cilium
based) does not function under Calico on your LPAR, install MetalLB and create a pool
named `public` to match the annotation. Verify with `sudo k8s kubectl get svc -A`
before trusting phase 04.

## Reset between runs

```bash
juju destroy-controller sunbeam-controller --destroy-all-models --no-prompt || true
juju remove-cloud lpar-manual --client || true
juju remove-cloud sunbeam-k8s --client || true
sudo k8s kubectl delete pod s390x-smoke --ignore-not-found || true
sudo snap remove --purge k8s juju openstack-hypervisor microceph cinder-volume || true
sudo rm -rf /var/snap/k8s ~/.local/share/juju
```

Then start fresh: `./run.sh all`.

## K8s s390x prerequisites

The Canonical K8s snap does not work out-of-the-box on s390x — its default CNI
(cilium) has no z/power build, and several bundled addon images at
`ghcr.io/canonical/...` are also not published for s390x. The Performance Engineering /
IBM Z alliances team has a working recipe in
[canonical/pe-ibm-microk8s-validation](https://github.com/canonical/pe-ibm-microk8s-validation)
(branch `c-k8s-and-calico-experimental`). Phase 02b encodes it:

1. `sudo k8s bootstrap --file <cfg>` with `network.enabled: false` (no cilium).
2. `sudo k8s kubectl apply -f vendor/pe-ibm/calico.yaml` — the *patched* Calico manifest.
3. Remove Metrics Server on s390x; it is not required by OpenStack.
4. Enable dns, local-storage, and load-balancer. The s390x path removes the
   unused CSI resizer/snapshotter sidecars and rewrites required CSI/MetalLB
   sidecars to upstream multi-architecture images.
5. Use a locally built `rawfile-localpv:0.8.3` s390x image. Canonical's
   `ghcr.io/canonical/rawfile-localpv:0.8.3-ck2` does not currently publish a
   s390x image. The source recipe is
   [canonical/rawfile-localpv-rocks](https://github.com/canonical/rawfile-localpv-rocks).
6. A smoke pod confirms scheduling, image pull, and pod networking on the LPAR.
7. A PVC/consumer pod must bind and reach Ready, and MetalLB must have both its
   controller and speaker running, before phase 03.

Phase 02b writes the generated bootstrap config, resolved `LB_CIDR`, rawfile
image choice, Kubernetes resources, node descriptions, and recent events into
the run artifact directory. If phase 03 later fails in Juju, check those files
first; many apparent charm failures are actually image-pull, PVC, or
LoadBalancer problems in the underlying K8s layer.

Useful live diagnostics:

```bash
sudo k8s kubectl get nodes
sudo k8s kubectl get pods -A
sudo k8s kubectl get events -A --sort-by=.lastTimestamp | tail -40
sudo k8s status
```

Do not continue to Juju merely because the node is `Ready`: the PVC and
LoadBalancer gates must also pass.

### Build rawfile-localpv locally on the LPAR

Launchpad remote-build is not required. On the Noble s390x LPAR, install
Rockcraft and LXD, then run the repository helper:

```bash
sudo snap install rockcraft --classic
sudo snap install lxd
sudo lxd init --auto
./tools/build_rawfile_localpv_rock.sh
```

The patch carried in `patches/rawfile-localpv-s390x.patch` adds the s390x
platform and makes `grpcio` use Ubuntu's OpenSSL. Its bundled BoringSSL
otherwise fails with `Unknown target CPU` on s390x. The generated protobuf
modules are committed upstream, so the runtime image does not need
`grpcio-tools`.

When Canonical K8s is already running, the helper also imports the resulting
`.rock` through `/run/containerd/containerd.sock` and tags it as
`docker.io/library/rawfile-localpv:0.8.3-s390x`. Phase 02b rewrites the
addon's rawfile driver to that local tag. Override it, if needed, with
`RAWFILE_LOCALPV_IMAGE`.

If the LPAR's proxy blocks the redirect from `registry.k8s.io` to
`*.pkg.dev`, sideload the registrar and provisioner from a workstation with
Docker and direct registry access:

```bash
./tools/sideload_s390x_k8s_images.sh ubuntu@10.103.192.218
```

The helper uses containerized Skopeo to select the s390x manifests, transfers
OCI archives over SSH, imports them through Canonical K8s's containerd socket,
and restarts the rawfile CSI pods. A successful result is controller `1/1`
and node `3/3`:

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

Phase 06 follows the [zopenstack](https://github.com/ubuntu-openstack/zopenstack)
workflow shape (`grep FAILED`, artifact/report capture, per-test re-runs) with
Sunbeam-appropriate substitutions:

1. **`tempest.conf` is generated by upstream `python-tempestconf`** against the live
   cloud via the openrc phase 04 produced — no charmed-OpenStack template.
2. **No K8s-charm-specific bits.** Per-service diagnostics use the openrc +
   `openstack` CLI instead of parsing `juju status keystone`.
3. **Direct smoke execution is the default.** The phase runs
   `tempest run --smoke --serial` from its validation venv. Set
   `TEMPEST_USE_TOX=1` if you specifically want to exercise upstream Tempest's
   tox environment; on lab hosts behind internal proxies, tox may fail while
   fetching OpenStack upper-constraints.

`python-tempestconf` debug logging is disabled by default because it may echo
auth material into `tempestconf.log`. Set `TEMPESTCONF_DEBUG=1` only when you
need verbose config-generation traces and will handle the resulting artifacts as
sensitive.

With compute + block storage deployed, full smoke (boot an instance, create a volume)
is meaningful. We vendor only the **exclude-list** from zopenstack (under
[vendor/zopenstack/](vendor/zopenstack/)). The default excludes currently cover:

- charmed-keystone policy tests inherited from zopenstack; re-evaluate these
  against keystone-k8s as policy coverage improves.
- `tempest.scenario.test_network_basic_ops.TestNetworkBasicOps.test_network_basic_ops`,
  because it requires the validation host to ping floating IPs allocated from
  `EXT_SUBNET_POOL`. Many LPAR lab networks can create provider-network
  resources but do not route that floating-IP range back to the runner. Remove
  this exclusion when your external network is genuinely reachable from the
  Tempest host.

The default phase 06 run uses upstream Tempest in the phase venv. Legacy
charmed-openstack reports install distro Tempest plugin packages, so they run
more smoke-discovered tests, including plugin setup classes for services that
are intentionally absent. To compare against that legacy count, run:

```bash
TEMPEST_PLUGIN_MODE=distro ./run.sh 06
```

On Resolute, distro Tempest currently needs a narrow Python compatibility shim:
`neutron-tempest-plugin` still imports `testtools.try_import` during discovery,
but Resolute's `testtools` package no longer provides that helper. Phase 06 writes
a temporary `sitecustomize.py` under the run's Tempest artifact directory and
adds it only to the `TEMPEST_PLUGIN_MODE=distro` process. This avoids modifying
system packages and lets unavailable-service plugin classes be discovered and
reported as skips, matching the legacy report style.

### Re-running a single test

```bash
./tools/run_tempest_test.sh 'test_dashboard_basic_ops.TestDashboardBasicOps.test_basic_scenario'
```

Defaults to the most recent run-id; pass `--run-id <id>` to target a specific one.

## Channel pins (subject to change)

Set in the two bundle files (and the `*_CHANNEL` defaults in
[scripts/01_install_prereqs.sh](scripts/01_install_prereqs.sh)) if Sunbeam publishes
2026.1 to a non-edge risk level.

| Component             | Default                |
|-----------------------|------------------------|
| `juju` snap           | `3/stable`             |
| `k8s` snap            | `latest/edge`          |
| Core `*-k8s` charms   | `2026.1/edge`          |
| `ovn-*-k8s` charms    | `26.03/edge`           |
| `mysql-k8s`           | `8.0/stable`           |
| `mysql-router-k8s`    | `8.0/edge`             |
| `rabbitmq-k8s`        | `3.12/edge`            |
| `traefik-k8s`         | `latest/candidate` (`latest/edge` in hybrid s390x mode) |
| `self-signed-certificates` | `1/beta` (`1/edge` in hybrid s390x mode) |
| `openstack-hypervisor`/`cinder-volume`/`cinder-volume-ceph`/`sunbeam-machine` | `2026.1/edge` |
| `microceph` snap      | `squid/stable`         |
