#!/usr/bin/env bash
# Phase 02b: bring up Canonical K8s and a load-balancer pool.
#
# s390x-only: bootstrap with bundled CNI (cilium) disabled, install Calico from
# the vendored pe-ibm manifest, and rewrite addon images to upstream registries
# that have s390x builds. Then enable dns + local-storage, configure an L2
# load-balancer pool so traefik-k8s gets an external IP, and smoke-test pod
# scheduling/storage.
#
# Runs between phase 02 (host prep) and phase 03 (juju bootstrap) so that when
# juju registers the K8s cloud, it finds a working cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tools/lib.sh
source "${SCRIPT_DIR}/../tools/lib.sh"

PHASE=02b_setup_s390x_cni
init_phase "${PHASE}"

phase_skip_if_done "${PHASE}" && exit 0

ARCH="$(target_arch)"
# Phase 03 must not start against a cluster whose storage/LB substrate is
# broken. Set SUBSTRATE_STRICT=0 only for diagnostic runs that intentionally
# continue past a failed PVC/LoadBalancer check.
SUBSTRATE_STRICT="${SUBSTRATE_STRICT:-1}"
log_step "K8s setup for target arch: ${ARCH}"
if [[ "${ARCH}" != "s390x" ]]; then
    log "FATAL: unsupported target arch ${ARCH}; phase 02b is s390x-only"
    exit 1
fi

# Re-apply proxy config. setup_proxy.sh is idempotent; calling it here ensures
# the k8sd systemd drop-in gets installed once the k8s snap is on disk.
"${SCRIPT_DIR}/../tools/setup_proxy.sh"

# Install the k8s snap if absent (the bundle workflow has no separate snap phase).
if ! command -v k8s >/dev/null 2>&1; then
    K8S_CHANNEL="${K8S_CHANNEL:-latest/edge}"
    log_step "k8s snap not present; installing from ${K8S_CHANNEL}"
    "${SCRIPT_DIR}/../tools/check_snap_arch.sh" k8s "${K8S_CHANNEL}" "${ARCH}" || true
    if ! sudo snap install k8s --classic --channel="${K8S_CHANNEL}"; then
        log "FATAL: snap install k8s failed (no ${ARCH} revision on ${K8S_CHANNEL}?)"
        exit 1
    fi
    # Re-run setup_proxy now that k8sd exists so its systemd drop-in lands.
    # Do not restart/start the K8s services yet: pre-bootstrap containerd at
    # /run/containerd makes `k8s bootstrap` fail its conflict check.
    SETUP_PROXY_RESTART_K8S=0 "${SCRIPT_DIR}/../tools/setup_proxy.sh"
fi
command -v k8s >/dev/null 2>&1 || { log "FATAL: 'k8s' CLI missing and could not be installed."; exit 1; }

VENDOR_DIR="${REPO_ROOT}/vendor/pe-ibm"
CALICO_YAML="${VENDOR_DIR}/calico.yaml"
if [[ ! -s "${CALICO_YAML}" ]]; then
    log "FATAL: ${CALICO_YAML} missing. Run ./tools/refresh_pe_ibm.sh first to vendor it from canonical/pe-ibm-microk8s-validation."
    exit 1
fi

# 1. Bootstrap config: disable bundled CNI so Calico can take over.
k8s_cfg="${ARTIFACT_DIR}/k8s-bootstrap.yaml"
log_step "writing ${k8s_cfg} (cilium disabled for s390x)"
cat > "${k8s_cfg}" <<'EOF'
cluster-config:
  network:
    enabled: false
EOF
bootstrap_desc="k8s bootstrap (cilium disabled)"
bootstrap_args=(--file "${k8s_cfg}")

# 2. Bootstrap k8s.
if sudo k8s status >/dev/null 2>&1; then
    log "k8s already bootstrapped; skipping bootstrap step"
else
    # The snap may have auto-started containerd on install. Bootstrap talks to
    # k8sd, so leave/start k8sd, but clear the pre-bootstrap runtime socket.
    # Otherwise bootstrap sees /run/containerd and treats it as a conflict.
    sudo systemctl start snap.k8s.k8sd.service >/dev/null 2>&1 || true
    sudo systemctl stop snap.k8s.containerd.service >/dev/null 2>&1 || true
    sudo rm -rf /run/containerd
    if ! run_logged "${bootstrap_desc}" -- sudo k8s bootstrap "${bootstrap_args[@]}"; then
        log "FATAL: k8s bootstrap failed"
        exit 1
    fi
fi

# 3. Apply vendored Calico and wait for it.
log_step "applying vendored Calico from ${CALICO_YAML}"
if ! run_logged "kubectl apply -f calico.yaml" -- sudo k8s kubectl apply -f "${CALICO_YAML}"; then
    log "FATAL: calico apply failed"
    exit 1
fi
log_step "waiting for calico pods Ready (up to 5 min)"
for calico_label in k8s-app=calico-node k8s-app=calico-kube-controllers; do
    # `kubectl wait` returns "no matching resources found" if it races the
    # DaemonSet/Deployment controller, so first wait for the pods to exist.
    for _ in $(seq 1 30); do
        if sudo k8s kubectl get pods -A -l "${calico_label}" -o name 2>/dev/null | grep -q .; then
            break
        fi
        sleep 2
    done
    if ! sudo k8s kubectl wait --for=condition=Ready pods -A -l "${calico_label}" \
            --timeout=300s 2>&1 | tee -a "${PHASE_LOG}"; then
        log "FATAL: ${calico_label} pods did not become Ready"
        sudo k8s kubectl get pods -A -l "${calico_label}" -o wide 2>&1 | tee -a "${PHASE_LOG}" || true
        sudo k8s kubectl describe pods -A -l "${calico_label}" 2>&1 | tee -a "${PHASE_LOG}" || true
        exit 1
    fi
done

# Metrics Server is not required by this deployment and its images are not
# consistently reachable/published for s390x. Remove it rather than carrying
# another architecture-specific dependency.
log_step "removing optional metrics-server components (s390x)"
sudo k8s kubectl -n kube-system delete deployment metrics-server \
    --ignore-not-found >/dev/null 2>&1 || true
sudo k8s kubectl -n kube-system delete service metrics-server \
    --ignore-not-found >/dev/null 2>&1 || true
sudo k8s kubectl delete apiservice v1beta1.metrics.k8s.io \
    --ignore-not-found >/dev/null 2>&1 || true

# The default local-storage driver is a local s390x image. If it is not in
# containerd, the CSI pods ImagePullBackOff and every control-plane PVC stays
# Pending; fail here instead of letting phase 03 fail later with a Juju timeout.
RAWFILE_IMAGE="${RAWFILE_LOCALPV_IMAGE:-docker.io/library/rawfile-localpv:0.8.3-s390x}"
if [[ "${RAWFILE_IMAGE}" == docker.io/library/rawfile-localpv* ]]; then
    ctr_bin=/snap/k8s/current/bin/ctr
    containerd_sock=/run/containerd/containerd.sock
    if [[ -x "${ctr_bin}" && -S "${containerd_sock}" ]]; then
        if ! sudo "${ctr_bin}" --address "${containerd_sock}" --namespace k8s.io images ls -q 2>/dev/null \
                | grep -Fxq "${RAWFILE_IMAGE}"; then
            rock="${RAWFILE_LOCALPV_ROCK:-}"
            if [[ -z "${rock}" ]]; then
                rock="$(find "${HOME}/builds/rawfile-localpv-rocks-s390x" \
                    -maxdepth 1 -type f -name '*.rock' -print -quit 2>/dev/null || true)"
            fi
            if [[ -n "${rock}" && -r "${rock}" ]]; then
                log "importing ${rock} into Kubernetes containerd"
                run_logged "import rawfile-localpv rock" -- \
                    sudo "${ctr_bin}" --address "${containerd_sock}" --namespace k8s.io \
                        images import --base-name docker.io/library/rawfile-localpv "${rock}" || {
                            log "FATAL: failed to import ${rock}"
                            exit 1
                        }
                run_logged "tag rawfile-localpv s390x image" -- \
                    sudo "${ctr_bin}" --address "${containerd_sock}" --namespace k8s.io \
                        images tag --force docker.io/library/rawfile-localpv:0.8.3 "${RAWFILE_IMAGE}" || {
                            log "FATAL: failed to tag ${RAWFILE_IMAGE}"
                            exit 1
                        }
                sudo k8s kubectl -n kube-system delete pod \
                    -l app.kubernetes.io/name=rawfile-csi --wait=false 2>/dev/null || true
            else
                log "FATAL: ${RAWFILE_IMAGE} is not present in the K8s containerd image store and no local rock was found."
                log "Build it first with tools/build_rock.sh, or set RAWFILE_LOCALPV_ROCK to the .rock path:"
                log "  ./tools/build_rock.sh rawfile-localpv --repo https://github.com/canonical/rawfile-localpv-rocks.git --source-dir $HOME/builds/rawfile-localpv-rocks-s390x --subdir . --tag docker.io/library/rawfile-localpv:0.8.3-s390x"
                log "or set RAWFILE_LOCALPV_IMAGE to a pullable s390x image and re-run phase 02b."
                exit 1
            fi
            if ! sudo "${ctr_bin}" --address "${containerd_sock}" --namespace k8s.io images ls -q 2>/dev/null \
                    | grep -Fxq "${RAWFILE_IMAGE}"; then
                log "FATAL: ${RAWFILE_IMAGE} is still absent after importing ${rock}."
                exit 1
            fi
        fi
    else
        log "WARN: cannot inspect containerd at ${containerd_sock}; skipping ${RAWFILE_IMAGE} presence check"
    fi
fi

# 4. Sideload the CSI sidecar images before enabling local-storage. The
# upstream registry.k8s.io manifests redirect to a registry the lab proxy
# blocks, and the Canonical images do not publish s390x.
SIDELOAD_IMAGES_DIR="${SIDELOAD_IMAGES_DIR:-${HOME}/builds/s390x-k8s-images}"
sidecar_images=(
    registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0
    registry.k8s.io/sig-storage/csi-provisioner:v5.3.0
)
ctr_bin="${ctr_bin:-/snap/k8s/current/bin/ctr}"
containerd_sock="${containerd_sock:-/run/containerd/containerd.sock}"
if [[ -x "${ctr_bin}" && -S "${containerd_sock}" ]]; then
    if [[ -d "${SIDELOAD_IMAGES_DIR}" ]]; then
        for archive in "${SIDELOAD_IMAGES_DIR}"/*.tar; do
            [[ -e "${archive}" ]] || continue
            run_logged "import sideloaded image $(basename "${archive}")" -- \
                sudo "${ctr_bin}" --address "${containerd_sock}" --namespace k8s.io \
                    images import "${archive}" || {
                        log "FATAL: failed to import ${archive}"
                        exit 1
                    }
        done
    fi
    missing_sidecars=()
    for image in "${sidecar_images[@]}"; do
        if ! sudo "${ctr_bin}" --address "${containerd_sock}" --namespace k8s.io \
                images ls -q 2>/dev/null | grep -Fxq "${image}"; then
            missing_sidecars+=("${image}")
        fi
    done
    if (( ${#missing_sidecars[@]} > 0 )); then
        log "FATAL: required s390x CSI sidecar images are missing from ${containerd_sock}:"
        printf '  %s\n' "${missing_sidecars[@]}" >&2
        log "Sideload them with tools/sideload_s390x_k8s_images.sh from a host with registry access,"
        log "or place the image archives in ${SIDELOAD_IMAGES_DIR} and rerun phase 02b."
        exit 1
    fi
fi

# 4. Enable core addons. Rewrite their images to upstream only on s390x.
ADDONS=(dns local-storage)
for addon in "${ADDONS[@]}"; do
    log_step "enabling addon: ${addon}"
    run_logged "k8s enable ${addon}" -- sudo k8s enable "${addon}" || \
        log "WARN: k8s enable ${addon} returned non-zero"
    if [[ "${addon}" == "local-storage" ]]; then
        # Resizing and VolumeSnapshots are not needed for the smoke
        # deployment. Keep only the driver, registrar and provisioner.
        log_step "removing optional local-storage CSI sidecars (s390x)"
        sudo k8s kubectl -n kube-system patch statefulset \
            ck-storage-rawfile-csi-controller --type=json \
            -p='[{"op":"remove","path":"/spec/template/spec/containers/1"}]' \
            >/dev/null 2>&1 || true
        sudo k8s kubectl -n kube-system patch daemonset \
            ck-storage-rawfile-csi-node --type=json \
            -p='[{"op":"remove","path":"/spec/template/spec/containers/3"}]' \
            >/dev/null 2>&1 || true
    fi
    "${SCRIPT_DIR}/../tools/rewrite_k8s_addon_images.sh" "${addon}" || \
        log "WARN: rewrite_k8s_addon_images for ${addon} reported unmapped images"
done

# Updating a StatefulSet image does not replace an existing pod when the
# controller has already created it. Delete the rawfile CSI pods explicitly so
# they pick up the rewritten local s390x image; otherwise rollout status can
# time out with ImagePullBackOff on the old pod.
log_step "restarting rawfile CSI pods after image rewrites"
sudo k8s kubectl -n kube-system delete pod \
    -l app.kubernetes.io/name=rawfile-csi --wait=false 2>/dev/null || true

log_step "waiting for rawfile CSI controller and node pods"
if ! sudo k8s kubectl -n kube-system rollout status statefulset/ck-storage-rawfile-csi-controller \
        --timeout=180s 2>&1 | tee -a "${PHASE_LOG}"; then
    log "FATAL: rawfile CSI controller did not become ready"
    log "If the pod is ImagePullBackOff, import the local rawfile rock and/or sideload the CSI sidecars:"
    log "  ./tools/build_rock.sh rawfile-localpv --repo https://github.com/canonical/rawfile-localpv-rocks.git --source-dir $HOME/builds/rawfile-localpv-rocks-s390x --subdir . --tag docker.io/library/rawfile-localpv:0.8.3-s390x"
    log "  ./tools/sideload_s390x_k8s_images.sh ubuntu@<lpar>"
    sudo k8s kubectl -n kube-system get pods -l app.kubernetes.io/name=rawfile-csi -o wide 2>&1 \
        | tee -a "${PHASE_LOG}" || true
    exit 1
fi
if ! sudo k8s kubectl -n kube-system rollout status daemonset/ck-storage-rawfile-csi-node \
        --timeout=180s 2>&1 | tee -a "${PHASE_LOG}"; then
    log "FATAL: rawfile CSI node daemonset did not become ready"
    sudo k8s kubectl -n kube-system get pods -l app.kubernetes.io/name=rawfile-csi -o wide 2>&1 \
        | tee -a "${PHASE_LOG}" || true
    exit 1
fi

# 4b. Load-balancer addon WITH an explicit L2 address pool (both arches). Without
# an external IP pool, traefik-k8s never gets a LoadBalancer IP, keystone's
# public_endpoint never resolves, and the openrc (phase 04) is unusable -- the
# single most likely place a deploy stalls. The bundle's traefik annotation
# (metallb.universe.tf/address-pool=public) is a no-op for the Canonical K8s
# addon; we rely on the addon's own L2 pool. If the L2 announcer does not work
# (e.g. under Calico on s390x), install MetalLB with a pool named `public`.
#
# LB_CIDR must be a host-routable range on the node's L2 segment. Override via
# env; otherwise derive a small range from the primary /24 and warn loudly.
if [[ -z "${LB_CIDR:-}" ]]; then
    host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    if [[ -n "${host_ip}" ]]; then
        prefix="${host_ip%.*}"
        LB_CIDR="${prefix}.240-${prefix}.250"
        log "WARN: LB_CIDR not set; derived ${LB_CIDR} from host IP ${host_ip}. Verify this range is free + routable, or re-run with LB_CIDR set."
    else
        LB_CIDR="10.20.20.240-10.20.20.250"
        log "WARN: could not derive host IP; defaulting LB_CIDR=${LB_CIDR}. Almost certainly needs overriding."
    fi
fi
log_step "enabling load-balancer addon with L2 pool ${LB_CIDR}"
run_logged "k8s enable load-balancer" -- sudo k8s enable load-balancer || \
    log "WARN: k8s enable load-balancer returned non-zero"
run_logged "k8s set load-balancer pool" -- \
    sudo k8s set "load-balancer.l2-mode=true" "load-balancer.cidrs=${LB_CIDR}" || \
    log "WARN: k8s set load-balancer failed; traefik may not get an external IP"
"${SCRIPT_DIR}/../tools/rewrite_k8s_addon_images.sh" load-balancer || \
    log "WARN: rewrite_k8s_addon_images for load-balancer reported unmapped images"
echo "${LB_CIDR}" > "${ARTIFACT_DIR}/lb_cidr"

log_step "waiting for MetalLB controller and speaker"
if ! sudo k8s kubectl -n metallb-system rollout status deployment/metallb-controller \
        --timeout=180s 2>&1 | tee -a "${PHASE_LOG}"; then
    log "FATAL: MetalLB controller did not become ready"
    sudo k8s kubectl -n metallb-system get pods -o wide 2>&1 | tee -a "${PHASE_LOG}" || true
    exit 1
fi
if ! sudo k8s kubectl -n metallb-system rollout status daemonset/metallb-speaker \
        --timeout=180s 2>&1 | tee -a "${PHASE_LOG}"; then
    log "FATAL: MetalLB speaker did not become ready"
    sudo k8s kubectl -n metallb-system get pods -o wide 2>&1 | tee -a "${PHASE_LOG}" || true
    exit 1
fi

# Wait for the node/CNI before running workload checks.
log_step "waiting for the Kubernetes node and CNI to become Ready"
if ! sudo k8s kubectl wait --for=condition=Ready node --all --timeout=300s \
        2>&1 | tee -a "${PHASE_LOG}"; then
    log "FATAL: Kubernetes node did not become Ready"
    exit 1
fi

# 5. Smoke-test: schedule a pod and confirm it reaches Ready (CNI + image pull).
log_step "smoke test: scheduling an ubuntu pod"
sudo k8s kubectl delete pod k8s-smoke --ignore-not-found
if sudo k8s kubectl run k8s-smoke --image=ubuntu --restart=Never --command -- sleep 30 2>&1 | tee -a "${PHASE_LOG}"; then
    if sudo k8s kubectl wait --for=condition=Ready pod/k8s-smoke --timeout=120s 2>&1 | tee -a "${PHASE_LOG}"; then
        log "smoke pod reached Ready -- pod networking and image pull work on this node"
        arch_report_append k8s-smoke k8s-smoke ubuntu "yes (${ARCH})" "scheduled+pulled+ready"
    else
        log "WARN: smoke pod did not reach Ready"
        sudo k8s kubectl describe pod k8s-smoke 2>&1 | tee -a "${PHASE_LOG}" || true
        arch_report_append k8s-smoke k8s-smoke ubuntu "no (${ARCH})" "scheduled but not Ready -- see phase log"
    fi
    sudo k8s kubectl delete pod k8s-smoke --ignore-not-found
else
    arch_report_append k8s-smoke k8s-smoke ubuntu "no (${ARCH})" "kubectl run failed"
fi

# 6. Substrate readiness for the OpenStack control plane. The k8s charms need a
#    default StorageClass that actually binds PVCs (keystone fernet/credential
#    keys, glance image store, ovn db filesystems) and the load-balancer addon to
#    hand out external IPs (traefik). Verify both now; phase 03 must not start
#    against a broken substrate. The result is also recorded to arch_report.md.
substrate_failed=0
log_step "substrate check: default StorageClass binds a PVC"
default_sc=$(sudo k8s kubectl get sc \
    -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
    2>/dev/null || true)
log "default StorageClass: ${default_sc:-<none>}"
sudo k8s kubectl delete pod k8s-substrate-storage --ignore-not-found >/dev/null 2>&1 || true
sudo k8s kubectl delete pvc k8s-substrate-pvc --ignore-not-found >/dev/null 2>&1 || true
cat <<'EOF' | sudo k8s kubectl apply -f - 2>&1 | tee -a "${PHASE_LOG}" || true
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: k8s-substrate-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: k8s-substrate-storage
spec:
  restartPolicy: Never
  containers:
    - name: smoke
      image: ubuntu
      command: ["sleep", "300"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: k8s-substrate-pvc
EOF
if sudo k8s kubectl wait --for=jsonpath='{.status.phase}'=Bound \
        pvc/k8s-substrate-pvc --timeout=180s 2>&1 | tee -a "${PHASE_LOG}" \
        && sudo k8s kubectl wait --for=condition=Ready pod/k8s-substrate-storage \
            --timeout=180s 2>&1 | tee -a "${PHASE_LOG}"; then
    log "PVC bound and consumer pod is Ready -- local-storage provisioning works"
    arch_report_append k8s-substrate storage "${default_sc:-local-storage}" "yes (${ARCH})" "test PVC bound; consumer Ready"
else
    substrate_failed=1
    log "FATAL: PVC/consumer did not become ready -- control-plane storage (keystone/glance/ovn) will stall"
    sudo k8s kubectl describe pvc k8s-substrate-pvc 2>&1 | tee -a "${PHASE_LOG}" || true
    sudo k8s kubectl describe pod k8s-substrate-storage 2>&1 | tee -a "${PHASE_LOG}" || true
    arch_report_append k8s-substrate storage "${default_sc:-local-storage}" "no (${ARCH})" "PVC/consumer not ready -- see phase log"
fi
sudo k8s kubectl delete pod k8s-substrate-storage --ignore-not-found >/dev/null 2>&1 || true
sudo k8s kubectl delete pvc k8s-substrate-pvc --ignore-not-found >/dev/null 2>&1 || true

log_step "substrate check: load-balancer assigns an external IP"
sudo k8s kubectl delete svc k8s-substrate-lb --ignore-not-found >/dev/null 2>&1 || true
cat <<'EOF' | sudo k8s kubectl apply -f - 2>&1 | tee -a "${PHASE_LOG}" || true
apiVersion: v1
kind: Service
metadata:
  name: k8s-substrate-lb
spec:
  type: LoadBalancer
  selector:
    app: k8s-substrate-lb-unbacked
  ports:
    - port: 80
      targetPort: 80
EOF
lb_ip=""
for _ in $(seq 1 30); do
    lb_ip=$(sudo k8s kubectl get svc k8s-substrate-lb \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "${lb_ip}" ]] && break
    sleep 3
done
if [[ -n "${lb_ip}" ]]; then
    log "load-balancer assigned ${lb_ip} -- traefik will get an external IP"
    arch_report_append k8s-substrate loadbalancer metallb "yes (${ARCH})" "assigned ${lb_ip}"
else
    substrate_failed=1
    log "FATAL: no external IP assigned within 90s -- traefik ingress will stay pending (see README Load-balancer)"
    sudo k8s kubectl get svc k8s-substrate-lb -o yaml 2>&1 | tee -a "${PHASE_LOG}" || true
    sudo k8s kubectl -n metallb-system get pods -o wide 2>&1 | tee -a "${PHASE_LOG}" || true
    arch_report_append k8s-substrate loadbalancer metallb "no (${ARCH})" "no ingress IP within 90s"
fi
sudo k8s kubectl delete svc k8s-substrate-lb --ignore-not-found >/dev/null 2>&1 || true

if (( substrate_failed )); then
    if [[ "${SUBSTRATE_STRICT}" == "1" ]]; then
        log "FATAL: Kubernetes substrate gate failed; refusing to mark phase 02b done."
        log "Fix storage/load-balancer first (README: Kubernetes substrate), then remove"
        log "  ${PHASE_STATUS_DIR}/${PHASE}.done"
        log "and re-run phase 02b. Set SUBSTRATE_STRICT=0 only for diagnostics."
        exit 1
    fi
    log "WARN: SUBSTRATE_STRICT=0 -- continuing despite a failed substrate gate"
fi

phase_done "${PHASE}"
log_step "phase ${PHASE} complete"
