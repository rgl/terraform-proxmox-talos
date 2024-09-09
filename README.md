# About

[![Lint](https://github.com/rgl/terraform-proxmox-talos/actions/workflows/lint.yml/badge.svg)](https://github.com/rgl/terraform-proxmox-talos/actions/workflows/lint.yml)

An example [Talos Linux](https://www.talos.dev) Kubernetes cluster in Proxmox QEMU/KVM Virtual Machines using terraform.

[Cilium](https://cilium.io) is used to augment the Networking (e.g. the [`LoadBalancer`](https://cilium.io/use-cases/load-balancer/) and [`Ingress`](https://docs.cilium.io/en/stable/network/servicemesh/ingress/) controllers), Observability (e.g. [Service Map](https://cilium.io/use-cases/service-map/)), and Security (e.g. [Network Policy](https://cilium.io/use-cases/network-policy/)).

[LVM](https://en.wikipedia.org/wiki/Logical_Volume_Manager_(Linux)), [DRBD](https://linbit.com/drbd/), [LINSTOR](https://github.com/LINBIT/linstor-server), and the [Piraeus Operator](https://github.com/piraeusdatastore/piraeus-operator), are used for providing persistent storage volumes.

The [spin extension](https://github.com/siderolabs/extensions/tree/main/container-runtime/spin), which installs [containerd-shim-spin](https://github.com/spinkube/containerd-shim-spin), is used to provide the ability to run [Spin Applications](https://developer.fermyon.com/spin/v2/index) ([WebAssembly/Wasm](https://webassembly.org/)).

# Usage (Ubuntu 22.04 host)

Install terraform:

```bash
# see https://github.com/hashicorp/terraform/releases
# renovate: datasource=github-releases depName=hashicorp/terraform
terraform_version='1.9.5'
wget "https://releases.hashicorp.com/terraform/$terraform_version/terraform_${$terraform_version}_linux_amd64.zip"
unzip "terraform_${$terraform_version}_linux_amd64.zip"
sudo install terraform /usr/local/bin
rm terraform terraform_*_linux_amd64.zip
```

Install cilium cli:

```bash
# see https://github.com/cilium/cilium-cli/releases
# renovate: datasource=github-releases depName=cilium/cilium-cli
cilium_version='0.16.16'
cilium_url="https://github.com/cilium/cilium-cli/releases/download/v$cilium_version/cilium-linux-amd64.tar.gz"
wget -O- "$cilium_url" | tar xzf - cilium
sudo install cilium /usr/local/bin/cilium
rm cilium
```

Install cilium hubble:

```bash
# see https://github.com/cilium/hubble/releases
# renovate: datasource=github-releases depName=cilium/hubble
hubble_version='1.16.0'
hubble_url="https://github.com/cilium/hubble/releases/download/v$hubble_version/hubble-linux-amd64.tar.gz"
wget -O- "$hubble_url" | tar xzf - hubble
sudo install hubble /usr/local/bin/hubble
rm hubble
```

Install talosctl:

```bash
# see https://github.com/siderolabs/talos/releases
# renovate: datasource=github-releases depName=siderolabs/talos
talos_version='1.7.6'
wget https://github.com/siderolabs/talos/releases/download/v$talos_version/talosctl-linux-amd64
sudo install talosctl-linux-amd64 /usr/local/bin/talosctl
rm talosctl-linux-amd64
```

Set your Proxmox details:

```bash
# see https://registry.terraform.io/providers/bpg/proxmox/latest/docs#argument-reference
# see https://github.com/bpg/terraform-provider-proxmox/blob/v0.64.0/proxmoxtf/provider/provider.go#L49-L56
cat >secrets-proxmox.sh <<EOF
unset HTTPS_PROXY
#export HTTPS_PROXY='http://localhost:8080'
export TF_VAR_proxmox_pve_node_address='192.168.1.21'
export PROXMOX_VE_INSECURE='1'
export PROXMOX_VE_ENDPOINT="https://$TF_VAR_proxmox_pve_node_address:8006"
export PROXMOX_VE_USERNAME='root@pam'
export PROXMOX_VE_PASSWORD='vagrant'
EOF
source secrets-proxmox.sh
```

Build the talos image, and initialize terraform:

```bash
./do init
```

Create the infrastructure:

```bash
time ./do plan-apply
```

Show talos information:

```bash
export TALOSCONFIG=$PWD/talosconfig.yml
controllers="$(terraform output -raw controllers)"
workers="$(terraform output -raw workers)"
all="$controllers,$workers"
c0="$(echo $controllers | cut -d , -f 1)"
w0="$(echo $workers | cut -d , -f 1)"
talosctl -n $all version
talosctl -n $all dashboard
```

Show kubernetes information:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
kubectl cluster-info
kubectl get nodes -o wide
```

Show Cilium information:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

In another shell, open the Hubble UI:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
cilium hubble ui
```

Execute an example workload:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
kubectl apply -f example.yml
kubectl rollout status deployment/example
kubectl get ingresses,services,pods,deployments
example_ip="$(kubectl get ingress/example -o json | jq -r .status.loadBalancer.ingress[0].ip)"
example_fqdn="$(kubectl get ingress/example -o json | jq -r .spec.rules[0].host)"
example_url="http://$example_fqdn"
curl --resolve "$example_fqdn:80:$example_ip" "$example_url"
echo "$example_ip $example_fqdn" | sudo tee -a /etc/hosts
curl "$example_url"
xdg-open "$example_url"
kubectl delete -f example.yml
```

Execute the [example hello-etcd stateful application](https://github.com/rgl/hello-etcd):

```bash
# see https://github.com/rgl/hello-etcd/tags
# renovate: datasource=github-tags depName=rgl/hello-etcd
hello_etcd_version='0.0.3'
rm -rf tmp/hello-etcd
install -d tmp/hello-etcd
pushd tmp/hello-etcd
wget -qO- "https://raw.githubusercontent.com/rgl/hello-etcd/v$hello_etcd_version/manifest.yml" \
  | perl -pe 's,(storageClassName:).+,$1 linstor-lvm-r1,g' \
  | perl -pe 's,(storage:).+,$1 1Gi,g' \
  > manifest.yml
kubectl apply -f manifest.yml
kubectl rollout status deployment hello-etcd
kubectl rollout status statefulset hello-etcd-etcd
kubectl get service,statefulset,pod,pvc,pv,sc
kubectl linstor volume list
```

Access the `hello-etcd` service from a [kubectl port-forward local port](https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/):

```bash
kubectl port-forward service/hello-etcd 6789:web &
sleep 3
wget -qO- http://localhost:6789 # Hello World #1!
wget -qO- http://localhost:6789 # Hello World #2!
wget -qO- http://localhost:6789 # Hello World #3!
```

Delete the etcd pod:

```bash
# NB the used StorageClass is configured with ReclaimPolicy set to Delete. this
#    means that, when we delete the application PersistentVolumeClaim, the
#    volume will be deleted from the linstor storage-pool. please note that
#    this will only happen when the pvc finalizers list is empty. since the
#    pvc is created by the statefulset (due to having
#    persistentVolumeClaimRetentionPolicy set to Retain), and it adds the
#    kubernetes.io/pvc-protection finalizer, which means, the pvc will only be
#    deleted when you explicitly delete it (and nothing is using it as noted by
#    an empty finalizers list)
# NB although we delete the pod, the StatefulSet will create a fresh pod to
#    replace it. using the same persistent volume as the old one.
kubectl delete pod/hello-etcd-etcd-0
kubectl get pod/hello-etcd-etcd-0 # NB its age should be in the seconds range.
kubectl rollout status deployment hello-etcd
kubectl rollout status statefulset hello-etcd-etcd
kubectl get pvc,pv
kubectl linstor volume list
```

Access the application, and notice that the counter continues after the previously returned value, which means that although the etcd instance is different, it picked up the same persistent volume:

```bash
wget -qO- http://localhost:6789 # Hello World #4!
wget -qO- http://localhost:6789 # Hello World #5!
wget -qO- http://localhost:6789 # Hello World #6!
```

Delete everything:

```bash
kubectl delete -f manifest.yml
kill %1 && sleep 1 # kill the kubectl port-forward background command execution.
# NB the pvc will not be automatically deleted because it has the
#    kubernetes.io/pvc-protection finalizer (set by the statefulset, due to
#    having persistentVolumeClaimRetentionPolicy set to Retain), which prevents
#    it from being automatically deleted.
kubectl get pvc,pv
kubectl linstor volume list
# delete the pvc (which will also trigger the pv (persistent volume) deletion
# because the associated storageclass reclaim policy is set to delete).
kubectl delete pvc/etcd-data-hello-etcd-etcd-0
# NB you should wait until its actually deleted.
kubectl get pvc,pv
kubectl linstor volume list
popd
```

Execute an [example WebAssembly (Wasm) Spin workload](https://github.com/rgl/spin-http-rust-example):

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
kubectl apply -f example-spin.yml
kubectl rollout status deployment/example-spin
kubectl get ingresses,services,pods,deployments
example_spin_ip="$(kubectl get ingress/example-spin -o json | jq -r .status.loadBalancer.ingress[0].ip)"
example_spin_fqdn="$(kubectl get ingress/example-spin -o json | jq -r .spec.rules[0].host)"
example_spin_url="http://$example_spin_fqdn"
curl --resolve "$example_spin_fqdn:80:$example_spin_ip" "$example_spin_url"
echo "$example_spin_ip $example_spin_fqdn" | sudo tee -a /etc/hosts
curl "$example_spin_url"
xdg-open "$example_spin_url"
kubectl delete -f example-spin.yml
```

Access Gitea:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
export SSL_CERT_FILE="$PWD/kubernetes-ingress-ca-crt.pem"
gitea_ip="$(kubectl get -n gitea ingress/gitea -o json | jq -r .status.loadBalancer.ingress[0].ip)"
gitea_fqdn="$(kubectl get -n gitea ingress/gitea -o json | jq -r .spec.rules[0].host)"
gitea_url="https://$gitea_fqdn"
echo "gitea_url: $gitea_url"
echo "gitea_username: gitea"
echo "gitea_password: gitea"
curl --resolve "$gitea_fqdn:443:$gitea_ip" "$gitea_url"
echo "$gitea_ip $gitea_fqdn" | sudo tee -a /etc/hosts
xdg-open "$gitea_url"
```

Access Argo CD:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
argocd_server_ip="$(kubectl get -n argocd ingress/argocd-server -o json | jq -r .status.loadBalancer.ingress[0].ip)"
argocd_server_fqdn="$(kubectl get -n argocd ingress/argocd-server -o json | jq -r .spec.rules[0].host)"
argocd_server_url="https://$argocd_server_fqdn"
argocd_server_admin_password="$(
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \
    | base64 --decode)"
echo "argocd_server_url: $argocd_server_url"
echo "argocd_server_admin_password: $argocd_server_admin_password"
echo "$argocd_server_ip $argocd_server_fqdn" | sudo tee -a /etc/hosts
xdg-open "$argocd_server_url"
```

If the Argo CD UI is showing these kind of errors:

> Unable to load data: permission denied
> Unable to load data: error getting cached app managed resources: NOAUTH Authentication required.
> Unable to load data: error getting cached app managed resources: cache: key is missing
> Unable to load data: error getting cached app managed resources: InvalidSpecError: Application referencing project default which does not exist

Try restarting some of the Argo CD components, and after restarting them, the
Argo CD UI should start working after a few minutes (e.g. at the next sync
interval, which defaults to 3m):

```bash
kubectl -n argocd rollout restart statefulset argocd-application-controller
kubectl -n argocd rollout status statefulset argocd-application-controller --watch
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --watch
```

Create the `argocd-example` repository:

```bash
export SSL_CERT_FILE="$PWD/kubernetes-ingress-ca-crt.pem"
export GIT_SSL_CAINFO="$SSL_CERT_FILE"
curl \
  --silent \
  --show-error \
  --fail-with-body \
  -u gitea:gitea \
  -X POST \
  -H 'Accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "argocd-example",
    "private": true
  }' \
  https://gitea.example.test/api/v1/user/repos \
  | jq
rm -rf tmp/argocd-example
git init tmp/argocd-example
pushd tmp/argocd-example
git branch -m main
cp ../../example.yml .
git add .
git commit -m init
git remote add origin https://gitea.example.test/gitea/argocd-example.git
git push -u origin main
popd
```

Create the `argocd-example` argocd application:

```bash
# NB we have to access gitea thru the internal cluster service because the
#    external/ingress domains does not resolve inside the cluster.
argocd login \
  "$argocd_server_fqdn" \
  --username admin \
  --password "$argocd_server_admin_password"
argocd cluster list
# NB we have to access gitea thru the internal cluster service because the
#    external/ingress domains does not resolve inside the cluster.
# NB if git repository was hosted outside of the cluster, we might have
#    needed to execute the following to trust the certificate.
#     argocd cert add-tls gitea.example.test --from "$SSL_CERT_FILE"
#     argocd cert list --cert-type https
argocd repo add \
  http://gitea-http.gitea.svc:3000/gitea/argocd-example.git \
  --username gitea \
  --password gitea
argocd app create \
  argocd-example \
  --dest-name in-cluster \
  --dest-namespace default \
  --project default \
  --auto-prune \
  --self-heal \
  --sync-policy automatic \
  --repo http://gitea-http.gitea.svc:3000/gitea/argocd-example.git \
  --path .
argocd app list
argocd app wait argocd-example --health --timeout 300
kubectl get crd | grep argoproj.io
kubectl -n argocd get applications
kubectl -n argocd get application/argocd-example -o yaml
```

Access the example application:

```bash
kubectl rollout status deployment/example
kubectl get ingresses,services,pods,deployments
example_ip="$(kubectl get ingress/example -o json | jq -r .status.loadBalancer.ingress[0].ip)"
example_fqdn="$(kubectl get ingress/example -o json | jq -r .spec.rules[0].host)"
example_url="http://$example_fqdn"
curl --resolve "$example_fqdn:80:$example_ip" "$example_url"
echo "$example_ip $example_fqdn" | sudo tee -a /etc/hosts
curl "$example_url"
xdg-open "$example_url"
```

Modify the example application, by bumping the number of replicas:

```bash
pushd tmp/argocd-example
sed -i -E 's,(replicas:) .+,\1 3,g' example.yml
git diff
git add .
git commit -m 'bump replicas'
git push -u origin main
popd
```

Then go the Argo CD UI, and wait for it to eventually sync the example argocd
application, or click `Refresh` to sync it immediately.

Delete the example argocd application and repository:

```bash
argocd app delete \
  argocd-example \
  --yes
argocd repo rm \
  http://gitea-http.gitea.svc:3000/gitea/argocd-example.git
curl \
  --silent \
  --show-error \
  --fail-with-body \
  -u gitea:gitea \
  -X DELETE \
  -H 'Accept: application/json' \
  "$gitea_url/api/v1/repos/gitea/argocd-example" \
  | jq
```

Destroy the infrastructure:

```bash
time ./do destroy
```

List this repository dependencies (and which have newer versions):

```bash
GITHUB_COM_TOKEN='YOUR_GITHUB_PERSONAL_TOKEN' ./renovate.sh
```

Update the talos extensions to match the talos version:

```bash
./do update-talos-extensions
```

# Troubleshoot

Talos:

```bash
# see https://www.talos.dev/v1.7/advanced/troubleshooting-control-plane/
talosctl -n $all support && rm -rf support && 7z x -osupport support.zip && code support
talosctl -n $c0 service ext-qemu-guest-agent status
talosctl -n $c0 service etcd status
talosctl -n $c0 etcd status
talosctl -n $c0 etcd alarm list
talosctl -n $c0 etcd members
talosctl -n $c0 get members
talosctl -n $c0 health --control-plane-nodes $controllers --worker-nodes $workers
talosctl -n $c0 inspect dependencies | dot -Tsvg >c0.svg && xdg-open c0.svg
talosctl -n $c0 dashboard
talosctl -n $c0 logs controller-runtime
talosctl -n $c0 logs kubelet
talosctl -n $c0 disks
talosctl -n $c0 mounts | sort
talosctl -n $c0 get resourcedefinitions
talosctl -n $c0 get machineconfigs -o yaml
talosctl -n $c0 get staticpods -o yaml
talosctl -n $c0 get staticpodstatus
talosctl -n $c0 get manifests
talosctl -n $c0 get services
talosctl -n $c0 get extensions
talosctl -n $c0 get addresses
talosctl -n $c0 get nodeaddresses
talosctl -n $c0 netstat --extend --programs --pods --listening
talosctl -n $c0 list -l -r -t f /etc
talosctl -n $c0 list -l -r -t f /system
talosctl -n $c0 list -l -r -t f /var
talosctl -n $c0 list -l -r /dev
talosctl -n $c0 list -l /sys/fs/cgroup
talosctl -n $c0 read /proc/cmdline | tr ' ' '\n'
talosctl -n $c0 read /proc/mounts | sort
talosctl -n $w0 read /proc/modules | sort
talosctl -n $w0 read /sys/module/drbd/parameters/usermode_helper
talosctl -n $c0 read /etc/os-release
talosctl -n $c0 read /etc/resolv.conf
talosctl -n $c0 read /etc/containerd/config.toml
talosctl -n $c0 read /etc/cri/containerd.toml
talosctl -n $c0 read /etc/cri/conf.d/cri.toml
talosctl -n $c0 read /etc/kubernetes/kubelet.yaml
talosctl -n $c0 read /etc/kubernetes/kubeconfig-kubelet
talosctl -n $c0 read /etc/kubernetes/bootstrap-kubeconfig
talosctl -n $c0 ps
talosctl -n $c0 containers -k
```

Cilium:

```bash
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
cilium config view
cilium hubble ui
# **NB** cilium connectivity test is not working out-of-the-box in the default
# test namespaces and using it in kube-system namespace will leave garbage
# behind.
#cilium connectivity test --test-namespace kube-system
kubectl -n kube-system get leases | grep cilium-l2announce-
```

Kubernetes:

```bash
kubectl get events --all-namespaces --watch
kubectl --namespace kube-system get events --watch
kubectl --namespace kube-system debug node/w0 --stdin --tty --image=busybox:1.36 -- cat /host/etc/resolv.conf
kubectl --namespace kube-system get configmaps coredns --output yaml
pod_name="$(kubectl --namespace kube-system get pods --selector k8s-app=kube-dns --output json | jq -r '.items[0].metadata.name')"
kubectl --namespace kube-system debug $pod_name --stdin --tty --image=busybox:1.36 --target=coredns -- sh -c 'cat /proc/$(pgrep coredns)/root/etc/resolv.conf'
kubectl --namespace kube-system run busybox -it --rm --restart=Never --image=busybox:1.36 -- nslookup -type=a talos.dev
kubectl get crds
kubectl api-resources
```

Storage (lvm/drbd/linstor/piraeus):

```bash
# NB kubectl linstor node list is equivalent to:
#    kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor node list
kubectl linstor node list
kubectl linstor storage-pool list
kubectl linstor volume list
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- drbdadm status
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- lvdisplay
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- vgdisplay
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- pvdisplay
w0_csi_node_pod_name="$(
  kubectl -n piraeus-datastore get pods \
    --field-selector spec.nodeName=w0 \
    --selector app.kubernetes.io/component=linstor-csi-node \
    --output 'jsonpath={.items[*].metadata.name}')"
kubectl -n piraeus-datastore exec "pod/$w0_csi_node_pod_name" -- lsblk
kubectl -n piraeus-datastore exec "pod/$w0_csi_node_pod_name" -- bash -c 'mount | grep /dev/drbd'
kubectl -n piraeus-datastore exec "pod/$w0_csi_node_pod_name" -- bash -c 'df -h | grep -P "Filesystem|/dev/drbd"'
```
