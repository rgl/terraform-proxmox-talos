#!/bin/bash
set -euo pipefail

# see https://github.com/siderolabs/talos/releases
# renovate: datasource=github-releases depName=siderolabs/talos
talos_version="1.7.5"

# see https://github.com/siderolabs/extensions/pkgs/container/qemu-guest-agent
# see https://github.com/siderolabs/extensions/tree/main/guest-agents/qemu-guest-agent
# renovate: datasource=docker depName=siderolabs/qemu-guest-agent registryUrl=https://ghcr.io
talos_qemu_guest_agent_extension_version="9.0.1"

# see https://github.com/siderolabs/extensions/pkgs/container/drbd
# see https://github.com/siderolabs/extensions/tree/main/storage/drbd
# see https://github.com/LINBIT/drbd
# NB the full version version is actually $version-v$talos_version, which we
#    use in the talos systemExtension imageRef.
# renovate: datasource=docker depName=siderolabs/drbd extractVersion=^(?<version>.+)-v1\.7\.5 registryUrl=https://ghcr.io
talos_drbd_extension_version="9.2.8"

# see https://github.com/siderolabs/extensions/pkgs/container/spin
# see https://github.com/siderolabs/extensions/tree/main/container-runtime/spin
# renovate: datasource=docker depName=siderolabs/spin registryUrl=https://ghcr.io
talos_spin_extension_version="0.15.0"

# see https://github.com/piraeusdatastore/piraeus-operator/releases
# renovate: datasource=github-releases depName=piraeusdatastore/piraeus-operator
piraeus_operator_version="2.5.2"

export CHECKPOINT_DISABLE='1'
export TF_LOG='DEBUG' # TRACE, DEBUG, INFO, WARN or ERROR.
export TF_LOG_PATH='terraform.log'

export TALOSCONFIG=$PWD/talosconfig.yml
export KUBECONFIG=$PWD/kubeconfig.yml

function step {
  echo "### $* ###"
}

function build_talos_image {
  # see https://www.talos.dev/v1.7/talos-guides/install/boot-assets/
  # see https://www.talos.dev/v1.7/advanced/metal-network-configuration/
  # see Profile type at https://github.com/siderolabs/talos/blob/v1.7.5/pkg/imager/profile/profile.go#L22-L45
  local talos_version_tag="v$talos_version"
  rm -rf tmp/talos
  mkdir -p tmp/talos
  cat >"tmp/talos/talos-$talos_version.yml" <<EOF
arch: amd64
platform: nocloud
secureboot: false
version: $talos_version_tag
customization:
  extraKernelArgs:
    - net.ifnames=0
input:
  kernel:
    path: /usr/install/amd64/vmlinuz
  initramfs:
    path: /usr/install/amd64/initramfs.xz
  baseInstaller:
    imageRef: ghcr.io/siderolabs/installer:$talos_version_tag
  systemExtensions:
    - imageRef: ghcr.io/siderolabs/qemu-guest-agent:$talos_qemu_guest_agent_extension_version
    - imageRef: ghcr.io/siderolabs/drbd:$talos_drbd_extension_version-v$talos_version
    - imageRef: ghcr.io/siderolabs/spin:v$talos_spin_extension_version
output:
  kind: image
  imageOptions:
    diskSize: $((2*1024*1024*1024))
    diskFormat: raw
  outFormat: raw
EOF
  docker run --rm -i \
    -v $PWD/tmp/talos:/secureboot:ro \
    -v $PWD/tmp/talos:/out \
    -v /dev:/dev \
    --privileged \
    "ghcr.io/siderolabs/imager:$talos_version_tag" \
    - < "tmp/talos/talos-$talos_version.yml"
  local img_path="tmp/talos/talos-$talos_version.qcow2"
  qemu-img convert -O qcow2 tmp/talos/nocloud-amd64.raw $img_path
  qemu-img info $img_path
  cat >terraform.tfvars <<EOF
talos_version = "$talos_version"
EOF
}

function init {
  step 'build talos image'
  build_talos_image
  step 'terraform init'
  terraform init -lockfile=readonly
}

function plan {
  step 'terraform plan'
  terraform plan -out=tfplan
}

function apply {
  step 'terraform apply'
  terraform apply tfplan
  terraform output -raw talosconfig >talosconfig.yml
  terraform output -raw kubeconfig >kubeconfig.yml
  health
  piraeus-install
  export-kubernetes-ingress-ca-crt
  info
}

function health {
  step 'talosctl health'
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local c0="$(echo $controllers | cut -d , -f 1)"
  talosctl -e $c0 -n $c0 \
    health \
    --control-plane-nodes $controllers \
    --worker-nodes $workers
}

function piraeus-install {
  # see https://github.com/piraeusdatastore/piraeus-operator
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.5.2/docs/how-to/talos.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.5.2/docs/tutorial/get-started.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.5.2/docs/tutorial/replicated-volumes.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.5.2/docs/explanation/components.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.5.2/docs/reference/linstorsatelliteconfiguration.md
  # see https://github.com/piraeusdatastore/piraeus-operator/blob/v2.5.2/docs/reference/linstorcluster.md
  # see https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/
  # see https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/#ch-kubernetes
  # see 5.7.1. Available Parameters in a Storage Class at https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/#s-kubernetes-sc-parameters
  # see https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
  # see https://www.talos.dev/v1.7/kubernetes-guides/configuration/storage/#piraeus--linstor
  step 'piraeus install'
  kubectl apply --server-side -k "https://github.com/piraeusdatastore/piraeus-operator//config/default?ref=v$piraeus_operator_version"
  step 'piraeus wait'
  kubectl wait pod --timeout=5m --for=condition=Ready -n piraeus-datastore -l app.kubernetes.io/component=piraeus-operator
  step 'piraeus configure'
  kubectl apply -n piraeus-datastore -f - <<'EOF'
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: talos-loader-override
spec:
  podTemplate:
    spec:
      initContainers:
        - name: drbd-shutdown-guard
          $patch: delete
        - name: drbd-module-loader
          $patch: delete
      volumes:
        - name: run-systemd-system
          $patch: delete
        - name: run-drbd-shutdown-guard
          $patch: delete
        - name: systemd-bus-socket
          $patch: delete
        - name: lib-modules
          $patch: delete
        - name: usr-src
          $patch: delete
        - name: etc-lvm-backup
          hostPath:
            path: /var/etc/lvm/backup
            type: DirectoryOrCreate
        - name: etc-lvm-archive
          hostPath:
            path: /var/etc/lvm/archive
            type: DirectoryOrCreate
EOF
  kubectl apply -f - <<EOF
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
EOF
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
provisioner: linstor.csi.linbit.com
metadata:
  name: linstor-lvm-r1
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  csi.storage.k8s.io/fstype: xfs
  linstor.csi.linbit.com/autoPlace: "1"
  linstor.csi.linbit.com/storagePool: lvm
EOF
  step 'piraeus configure wait'
  kubectl wait pod --timeout=5m --for=condition=Ready -n piraeus-datastore -l app.kubernetes.io/name=piraeus-datastore
  kubectl wait LinstorCluster/linstor --timeout=5m --for=condition=Available
  step 'piraeus create-device-pool'
  local workers="$(terraform output -raw workers)"
  local nodes=($(echo "$workers" | tr ',' ' '))
  for ((n=0; n<${#nodes[@]}; ++n)); do
    local node="w$((n))"
    step "piraeus wait node $node"
    while ! kubectl linstor storage-pool list --node "$node" >/dev/null 2>&1; do sleep 3; done
    step "piraeus create-device-pool $node"
    if ! kubectl linstor storage-pool list --node "$node" --storage-pool lvm | grep -q lvm; then
      kubectl linstor physical-storage create-device-pool \
        --pool-name lvm \
        --storage-pool lvm \
        lvm \
        "$node" \
        /dev/sdb
    fi
  done
}

function piraeus-info {
  step 'piraeus node list'
  kubectl linstor node list
  step 'piraeus storage-pool list'
  kubectl linstor storage-pool list
  step 'piraeus volume list'
  kubectl linstor volume list
}

function info {
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local nodes=($(echo "$controllers,$workers" | tr ',' ' '))
  step 'talos node installer image'
  for n in "${nodes[@]}"; do
    # NB there can be multiple machineconfigs in a machine. we only want to see
    #    the ones with an id that looks like a version tag.
    talosctl -n $n get machineconfigs -o json \
      | jq -r 'select(.metadata.id | test("v\\d+")) | .spec.machine.install.image' \
      | sed -E "s,(.+),$n: \1,g"
  done
  step 'talos node os-release'
  for n in "${nodes[@]}"; do
    talosctl -n $n read /etc/os-release \
      | sed -E "s,(.+),$n: \1,g"
  done
  step 'kubernetes nodes'
  kubectl get nodes -o wide
  piraeus-info
}

function export-kubernetes-ingress-ca-crt {
  kubectl get -n cert-manager secret/ingress-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d \
    > kubernetes-ingress-ca-crt.pem
}

function destroy {
  terraform destroy -auto-approve
}

case $1 in
  init)
    init
    ;;
  plan)
    plan
    ;;
  apply)
    apply
    ;;
  plan-apply)
    plan
    apply
    ;;
  health)
    health
    ;;
  info)
    info
    ;;
  destroy)
    destroy
    ;;
  *)
    echo $"Usage: $0 {init|plan|apply|plan-apply|health|info}"
    exit 1
    ;;
esac
