#!/usr/bin/env bash
# Rebuild a two-node cluster, or a three-node cluster when WORKER2_* variables are supplied.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
IMAGE_DIR="$ROOT_DIR/images"
DISK_DIR="$ROOT_DIR/disks"
SEED_DIR="$ROOT_DIR/seed"
IMAGE="$IMAGE_DIR/ubuntu-24.04.img"
KEY="$HOME/.ssh/cka_lab"
KNOWN_HOSTS="$ROOT_DIR/.known_hosts"
K8S_MINOR="v1.35"
POD_CIDR="10.244.0.0/16"
LAB_NETWORK="${LAB_NETWORK:-default}"
CP_STATIC_IP="${CP_STATIC_IP:-}"
WORKER_STATIC_IP="${WORKER_STATIC_IP:-}"
WORKER2_STATIC_IP="${WORKER2_STATIC_IP:-}"
CP_MAC="${CP_MAC:-}"
WORKER_MAC="${WORKER_MAC:-}"
WORKER2_MAC="${WORKER2_MAC:-}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
KUBECONFIG_TARGET="${KUBECONFIG_TARGET:-}"
THREE_NODE=false
if [[ -n $WORKER2_STATIC_IP || -n $WORKER2_MAC ]]; then
  [[ -n $WORKER2_STATIC_IP && -n $WORKER2_MAC ]] || { echo "WORKER2_STATIC_IP and WORKER2_MAC must be supplied together" >&2; exit 2; }
  THREE_NODE=true
fi

require() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
for command in cloud-localds qemu-img virt-install virsh ssh ssh-keygen curl cloud-init setfacl timeout; do require "$command"; done
if [[ -n $KUBECONFIG_TARGET ]]; then require kubectl; fi

mkdir -p "$IMAGE_DIR" "$DISK_DIR" "$SEED_DIR" "$HOME/.ssh"
if [[ ! -f $KEY ]]; then
  ssh-keygen -t ed25519 -f "$KEY" -N ""
fi
if [[ ! -f $KEY.pub ]]; then
  ssh-keygen -y -f "$KEY" > "$KEY.pub"
fi
if [[ ! -f $IMAGE ]]; then
  curl -fL --retry 3 -o "$IMAGE" \
    https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
fi

if getent passwd libvirt-qemu >/dev/null; then
  sudo setfacl -m u:libvirt-qemu:--x "$HOME"
fi
sudo virsh net-start "$LAB_NETWORK" 2>/dev/null || true
sudo virsh net-autostart "$LAB_NETWORK"

"$ROOT_DIR/destroy.sh" --purge

LAB_KEY=$(< "$KEY.pub")
write_user_data() {
  local hostname=$1 output=$2
  {
    printf '%s\n' '#cloud-config'
    printf 'hostname: %s\n' "$hostname"
    printf '%s\n' 'manage_etc_hosts: true' 'users:'
    printf '%s\n' '  - name: lab' '    groups: [sudo]' '    shell: /bin/bash'
    printf '%s\n' '    sudo: ALL=(ALL) NOPASSWD:ALL' '    lock_passwd: true'
    printf '%s\n' '    ssh_authorized_keys:'
    printf '      - %s\n' "$LAB_KEY"
    printf '%s\n' 'packages:' '  - qemu-guest-agent'
    printf '%s\n' 'runcmd:' '  - systemctl enable --now qemu-guest-agent'
  } > "$output"
  cloud-init schema --config-file "$output" >/dev/null
}

write_user_data k8s-cp01 "$SEED_DIR/cp-user-data"
write_user_data k8s-worker01 "$SEED_DIR/worker-user-data"
if [[ $THREE_NODE == true ]]; then write_user_data k8s-worker02 "$SEED_DIR/worker02-user-data"; fi
printf 'instance-id: k8s-cp01\nlocal-hostname: k8s-cp01\n' > "$SEED_DIR/cp-meta-data"
printf 'instance-id: k8s-worker01\nlocal-hostname: k8s-worker01\n' > "$SEED_DIR/worker-meta-data"
if [[ $THREE_NODE == true ]]; then printf 'instance-id: k8s-worker02\nlocal-hostname: k8s-worker02\n' > "$SEED_DIR/worker02-meta-data"; fi

cloud-localds "$SEED_DIR/cp-seed.iso" "$SEED_DIR/cp-user-data" "$SEED_DIR/cp-meta-data"
cloud-localds "$SEED_DIR/worker-seed.iso" "$SEED_DIR/worker-user-data" "$SEED_DIR/worker-meta-data"
if [[ $THREE_NODE == true ]]; then cloud-localds "$SEED_DIR/worker02-seed.iso" "$SEED_DIR/worker02-user-data" "$SEED_DIR/worker02-meta-data"; fi

qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$DISK_DIR/k8s-cp01.qcow2" 20G
qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$DISK_DIR/k8s-worker01.qcow2" 20G
if [[ $THREE_NODE == true ]]; then qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$DISK_DIR/k8s-worker02.qcow2" 20G; fi

create_vm() {
  local name=$1 memory=$2 disk=$3 seed=$4 mac=$5
  local network_arg="network=$LAB_NETWORK,model=virtio"
  [[ -n $mac ]] && network_arg+=",mac=$mac"
  sudo virt-install \
    --name "$name" --memory "$memory" --vcpus 2 --import --boot uefi \
    --disk path="$disk",format=qcow2 \
    --disk path="$seed",device=cdrom,readonly=on \
    --network "$network_arg" --os-variant ubuntu24.04 \
    --graphics none --noautoconsole
}
create_vm k8s-cp01 3072 "$DISK_DIR/k8s-cp01.qcow2" "$SEED_DIR/cp-seed.iso" "$CP_MAC"
create_vm k8s-worker01 2048 "$DISK_DIR/k8s-worker01.qcow2" "$SEED_DIR/worker-seed.iso" "$WORKER_MAC"
if [[ $THREE_NODE == true ]]; then create_vm k8s-worker02 2048 "$DISK_DIR/k8s-worker02.qcow2" "$SEED_DIR/worker02-seed.iso" "$WORKER2_MAC"; fi

vm_ip() {
  local name=$1 expected_ip=$2 ip=""
  for _ in {1..45}; do
    ip=$(sudo virsh domifaddr "$name" --source lease 2>/dev/null | awk '$3=="ipv4" {split($4,a,"/"); print a[1]}')
    if [[ -n $ip && ( -z $expected_ip || $ip == "$expected_ip" ) ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for a DHCP address for $name" >&2
  exit 1
}

CP_IP=$(vm_ip k8s-cp01 "$CP_STATIC_IP")
WORKER_IP=$(vm_ip k8s-worker01 "$WORKER_STATIC_IP")
WORKER2_IP=""
if [[ $THREE_NODE == true ]]; then WORKER2_IP=$(vm_ip k8s-worker02 "$WORKER2_STATIC_IP"); fi
# VM IPs can be recycled after recreation. Keep their fingerprints separate from
# the user's normal known_hosts and clear only the two new lab addresses.
touch "$KNOWN_HOSTS"
ssh-keygen -R "$CP_IP" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
ssh-keygen -R "$WORKER_IP" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
if [[ -n $WORKER2_IP ]]; then ssh-keygen -R "$WORKER2_IP" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true; fi
SSH=(ssh -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new)
wait_for_ssh() {
  local node=$1
  for _ in {1..60}; do
    "${SSH[@]}" -o ConnectTimeout=5 lab@"$node" true 2>/dev/null && return 0
    sleep 2
  done
  echo "Timed out waiting 120 seconds for SSH on $node" >&2
  exit 1
}
wait_for_cloud_init() {
  local node=$1
  timeout 300 "${SSH[@]}" -o ConnectTimeout=10 lab@"$node" 'cloud-init status --wait'
}
wait_for_ssh "$CP_IP"
wait_for_ssh "$WORKER_IP"
if [[ -n $WORKER2_IP ]]; then wait_for_ssh "$WORKER2_IP"; fi
wait_for_cloud_init "$CP_IP"
wait_for_cloud_init "$WORKER_IP"
if [[ -n $WORKER2_IP ]]; then wait_for_cloud_init "$WORKER2_IP"; fi

setup_node() {
  "${SSH[@]}" lab@"$1" 'bash -s' <<EOF
set -euo pipefail
sudo swapoff -a
sudo sed -ri '/\\sswap\\s/s/^#?/#/' /etc/fstab
# Some upstream or corporate paths block plaintext HTTP. Ubuntu cloud images
# use HTTP mirrors by default, while HTTPS remains available through libvirt NAT.
sudo sed -i \
  -e 's|http://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' \
  -e 's|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g' \
  /etc/apt/sources.list.d/ubuntu.sources
cat <<'APT' | sudo tee /etc/apt/apt.conf.d/99cka-lab-network >/dev/null
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "15";
Acquire::https::Timeout "15";
APT
printf '%s\\n' overlay br_netfilter | sudo tee /etc/modules-load.d/k8s.conf
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<'SYSCTL' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL
sudo sysctl --system
sudo env DEBIAN_FRONTEND=noninteractive apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gpg containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
sudo systemctl restart containerd
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo env DEBIAN_FRONTEND=noninteractive apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
EOF
}
setup_node "$CP_IP"
setup_node "$WORKER_IP"
if [[ -n $WORKER2_IP ]]; then setup_node "$WORKER2_IP"; fi

validate_node_egress() {
  local node=$1
  echo "Validating DNS and HTTPS egress from $node"
  "${SSH[@]}" -n -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 lab@"$node" \
    "getent hosts pkgs.k8s.io >/dev/null && curl -4fsSL --connect-timeout 10 --max-time 30 -o /dev/null https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release"
}
validate_node_egress "$CP_IP"
validate_node_egress "$WORKER_IP"
if [[ -n $WORKER2_IP ]]; then validate_node_egress "$WORKER2_IP"; fi

INIT_COMMAND="sudo kubeadm init --apiserver-advertise-address=$CP_IP --pod-network-cidr=$POD_CIDR"
if [[ -n $CONTROL_PLANE_ENDPOINT ]]; then
  INIT_COMMAND+=" --control-plane-endpoint $CONTROL_PLANE_ENDPOINT"
fi
"${SSH[@]}" lab@"$CP_IP" "$INIT_COMMAND"
"${SSH[@]}" lab@"$CP_IP" 'mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config'
"${SSH[@]}" lab@"$CP_IP" 'kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml'
JOIN_CMD=$("${SSH[@]}" lab@"$CP_IP" 'sudo kubeadm token create --print-join-command')
"${SSH[@]}" lab@"$WORKER_IP" "sudo $JOIN_CMD"
if [[ -n $WORKER2_IP ]]; then "${SSH[@]}" lab@"$WORKER2_IP" "sudo $JOIN_CMD"; fi
"${SSH[@]}" lab@"$CP_IP" 'kubectl wait --for=condition=Ready nodes --all --timeout=300s && kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s && kubectl rollout status deployment/calico-kube-controllers -n kube-system --timeout=300s && kubectl rollout status deployment/coredns -n kube-system --timeout=300s && kubectl get nodes -o wide && kubectl get pods -A'

"${SSH[@]}" lab@"$CP_IP" 'kubectl label node k8s-worker01 node-role.kubernetes.io/worker="" --overwrite'
if [[ -n $WORKER2_IP ]]; then "${SSH[@]}" lab@"$CP_IP" 'kubectl label node k8s-worker02 node-role.kubernetes.io/worker="" --overwrite'; fi
if [[ -n $KUBECONFIG_TARGET ]]; then
  mkdir -p "$(dirname "$KUBECONFIG_TARGET")"
  temporary_kubeconfig=$(mktemp "${KUBECONFIG_TARGET}.XXXXXX")
  "${SSH[@]}" lab@"$CP_IP" 'sudo cat /etc/kubernetes/admin.conf' > "$temporary_kubeconfig"
  chmod 600 "$temporary_kubeconfig"
  mv -f "$temporary_kubeconfig" "$KUBECONFIG_TARGET"
  kubectl --kubeconfig "$KUBECONFIG_TARGET" get nodes >/dev/null
fi

echo "Cluster ready. Control plane: $CP_IP; worker: $WORKER_IP${WORKER2_IP:+; worker: $WORKER2_IP}"
