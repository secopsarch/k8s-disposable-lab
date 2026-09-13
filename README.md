# KVM / libvirt Kubernetes CKA lab in WSL2

This lab runs a real Kubernetes cluster inside KVM virtual machines hosted by Ubuntu on WSL2. The default build is two nodes; the dedicated-network workflow can build one control plane and two workers:

```text
Windows 11
  └─ WSL2 Ubuntu
       └─ libvirt + QEMU/KVM (dedicated NAT network: 192.168.56.0/24)
            ├─ k8s-cp01       2 vCPU, 3 GiB RAM, 20 GiB qcow2
            └─ k8s-worker01   2 vCPU, 2 GiB RAM, 20 GiB qcow2
            └─ k8s-worker02   2 vCPU, 2 GiB RAM, 20 GiB qcow2 (three-node mode)
                 └─ Kubernetes v1.35 + containerd + Calico
                    Pod CIDR: 10.244.0.0/16
```

It is designed for CKA-style work: separate Linux nodes, SSH, systemd, kubelet, containerd, kubeadm, CNI, certificates, and ordinary node troubleshooting tools.

The target architecture, WSL-to-node connectivity, stable kubeconfig design, and controlled break/recover drills are documented in [Architecture and operations](docs/architecture-and-operations.md).

## Resource requirements

| Layer | CPU | Memory | Storage |
| --- | ---: | ---: | ---: |
| Windows host | 8 logical CPUs recommended | 16 GiB+ recommended | 50 GiB free |
| WSL2 allocation (two nodes) | 6+ vCPUs | 8–10 GiB | 50 GiB available |
| WSL2 allocation (three nodes) | 8+ vCPUs | 10–12 GiB | 70 GiB available |
| `k8s-cp01` | 2 vCPU | 3 GiB | 20 GiB thin-provisioned |
| `k8s-worker01` | 2 vCPU | 2 GiB | 20 GiB thin-provisioned |
| `k8s-worker02` (three-node mode) | 2 vCPU | 2 GiB | 20 GiB thin-provisioned |

Kubernetes requires at least 2 GiB of RAM per node and 2 CPUs for the control plane. This lab deliberately gives the control plane extra headroom.

## Prerequisites

Run these in the **WSL Ubuntu operator host**, never manually inside the two Ubuntu VM nodes. The host must expose `/dev/kvm`; the recreation script installs the Kubernetes/node packages inside each VM after cloud-init is complete.

```bash
ls -l /dev/kvm
free -h

sudo apt update
sudo apt install -y \
  qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst \
  qemu-utils cloud-image-utils cloud-init ovmf libosinfo-bin \
  acl curl gpg openssh-client coreutils bridge-utils wget

sudo systemctl enable --now libvirtd
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default
sudo virsh net-list --all
```

The expected libvirt network is `default`, normally `192.168.122.0/24`. Do not use an overlapping Pod CIDR. This lab uses `10.244.0.0/16`.

### WSL host dependency checklist

| Requirement | Why it is required | Installed by |
| --- | --- | --- |
| `/dev/kvm` and nested virtualization | Runs QEMU/KVM VMs at usable speed | Windows/WSL configuration; cannot be installed by the script |
| `qemu-system-x86`, `libvirt-*`, `virtinst`, `ovmf` | Creates and runs UEFI VMs and libvirt NAT networks | WSL host prerequisite command above |
| `cloud-image-utils`, `cloud-init`, `qemu-utils` | Generates/validates cloud-init seed ISOs and qcow2 overlays | WSL host prerequisite command above |
| `curl`, `gpg`, `openssh-client`, `coreutils`, `acl`, `libosinfo-bin` | Downloads the image, validates packages, connects by SSH, applies the minimal QEMU ACL, and selects the Ubuntu guest type | WSL host prerequisite command above |
| 7 GiB+ free WSL memory, 50 GiB+ disk | Supports both VMs and image/overlay storage | WSL allocation and host storage |
| Internet access | Downloads Ubuntu image, Kubernetes packages, container images, and Calico | Host network |
| `sudo` | Manages libvirt and provisions nodes | WSL user account |

### Ubuntu VM dependencies

Do **not** install Kubernetes prerequisites manually on `k8s-cp01` or `k8s-worker01` before a rebuild. Cloud-init creates the `lab` account, SSH key, and `qemu-guest-agent`; the recreation workflow then installs `containerd`, `kubelet`, `kubeadm`, `kubectl`, kernel modules, sysctls, and the Kubernetes v1.35 package repository on both nodes.

### Required preflight gate

Run the appropriate read-only check before any lifecycle action. `destroy.sh` itself only needs sudo and libvirt; the preflight additionally confirms that a subsequent recreate can complete:

```bash
chmod +x preflight.sh

# Current default-DHCP workflow
./preflight.sh --default

# Dedicated static-IP workflow (recommended)
./preflight.sh --dedicated

# Dedicated three-node workflow
./preflight.sh --dedicated --three-node
```

It validates host packages, `/dev/kvm`, sudo/libvirt access, image download reachability, memory, disk, CIDR availability, and warns if a recreation will remove active lab domains. It installs or changes nothing.

## First build from scratch

The fastest reliable build uses the Ubuntu 24.04 cloud image plus cloud-init. It still leaves the Kubernetes bootstrap steps visible and reproducible.

```bash
mkdir -p ~/repolist/k8s-disposable-lab/{images,disks,seed}
cd ~/repolist/k8s-disposable-lab

ssh-keygen -t ed25519 -f ~/.ssh/cka_lab -N ""
wget -O images/ubuntu-24.04.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

Use `./recreate.sh` to create the cloud-init files, VM overlays, domains, Kubernetes packages, control plane, Calico CNI, and worker join. It waits for both nodes, Calico, and CoreDNS to become Ready before reporting success.

```bash
chmod +x destroy.sh recreate.sh recreate-dedicated-network.sh preflight.sh
./recreate.sh
```

The script pins the Kubernetes package repository to v1.35 to match the CKA exam environment at the time this lab was built. Update `K8S_MINOR` deliberately when the target exam version changes.

For the dedicated static network described in the architecture document, use `./recreate-dedicated-network.sh`. It creates `cka-net`, reserves `192.168.56.10` and `192.168.56.11` against fixed MAC addresses, labels the worker, and refreshes `~/.kube/cka-lab` after validation.

To build the recommended three-node topology, first run its stricter preflight and then use the opt-in flag. It adds `k8s-worker02` with the reservation `192.168.56.12` and MAC `52:54:00:56:00:12`; it does not reduce the resource allocation of any node.

```bash
./preflight.sh --dedicated --three-node
./recreate-dedicated-network.sh --three-node
kubectl --kubeconfig ~/.kube/cka-lab get nodes -o wide
```

### Automated wait and validation gates

`recreate.sh` does not rely on a fixed sleep to declare success. It waits for each state that must be true before moving on. The egress check runs SSH without stdin and has explicit SSH keepalive plus curl connection/total-time limits, so it cannot be stopped by terminal job control:

| Gate | Maximum wait | What it verifies |
| --- | ---: | --- |
| DHCP address per VM | 90 seconds | Libvirt has leased an IPv4 address to the new domain. |
| SSH per VM | 120 seconds | `sshd` accepts the lab key. |
| cloud-init per VM | 300 seconds | The hostname, SSH key, and guest agent configuration have completed. |
| DNS and HTTPS egress per VM | 45 seconds | Resolves `pkgs.k8s.io` and downloads its configured Kubernetes release metadata through libvirt NAT. |
| Kubernetes nodes | 300 seconds | Every requested node reports `Ready`. |
| Calico and CoreDNS | 300 seconds each | The Calico DaemonSet, Calico controllers, and CoreDNS Deployment finish their rollouts. |

Package downloads and `apt` installation depend on the available Internet connection, so they intentionally have no artificial timeout. A normal rebuild takes roughly 10–20 minutes. If a timed wait fails, the script exits non-zero rather than claiming the cluster is ready.

The dedicated `cka-net` uses libvirt NAT through gateway `192.168.56.1`; it does not need a Windows route or any guest-side static route. A successful build proves Internet access twice: the per-node Kubernetes repository HTTPS gate succeeds before `kubeadm init`, and Calico/CoreDNS readiness proves required container images were pulled. During bootstrap, the script changes the Ubuntu cloud-image mirror URIs from HTTP to HTTPS before its first `apt update`; this prevents a blocked outbound TCP/80 path from stalling package installation while retaining signed APT metadata verification.

### Predictable package-install timing

`cka-net` is IPv4-only. The bootstrap therefore configures APT to use IPv4, HTTPS Ubuntu mirrors, two retries, and 15-second HTTP/HTTPS connection timeouts. It uses `apt-get` with `DEBIAN_FRONTEND=noninteractive`, which prevents the non-TTY `debconf` frontend message from looking like an interactive prompt. The `needrestart` messages about services, containers, and VM guests are informational and do not block the build.

### Why `kubeadm upgrade plan` can show no newer version

The recreation scripts intentionally configure `pkgs.k8s.io` for `stable:v1.35`, so `kubeadm upgrade plan` reports the newest available patch release in the v1.35 series. `sudo apt-mark unhold kubeadm` only allows package changes; it does not switch that configured repository to a new minor version. The message that a newer remote version exists followed by `falling back to: stable-1.35` is expected and confirms it reached the Internet.

If an existing node predates this HTTPS-mirror bootstrap change and `apt-get update` waits indefinitely for headers, update its Ubuntu mirror URIs once, then retry. This affects only the guest's APT transport, not the dedicated network, cluster configuration, or Kubernetes package repository:

```bash
sudo sed -i \
  -e 's|http://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' \
  -e 's|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g' \
  /etc/apt/sources.list.d/ubuntu.sources
sudo apt-get update
```

## Daily lifecycle

```bash
# Show current state and DHCP-assigned node addresses
sudo virsh list --all
sudo virsh net-dhcp-leases default

# Stop and undefine the VMs; keep their disks for inspection or manual recovery
./destroy.sh

# Delete only the disposable lab overlays and generated seed ISOs, then recreate a clean cluster
./recreate.sh

# Explicitly purge the disposable artifacts without rebuilding
./destroy.sh --purge
```

`destroy.sh` removes `k8s-cp01`, `k8s-worker01`, and (when present) `k8s-worker02`. `destroy.sh --purge` never deletes `images/ubuntu-24.04.img`, the repository, or `~/.ssh/cka_lab`. It deletes only the named VM overlays, generated seed ISOs, and libvirt definitions. The dedicated `cka-net` definition remains so its DHCP reservations stay reproducible; the next dedicated recreate replaces it safely.

If a prior interrupted network recreation leaves the fixed `virbr56` bridge behind, the dedicated script now removes that bridge automatically only when it has no attached interfaces. If it has attached interfaces, the script stops and prints them instead of deleting anything.

## Accessing the nodes

### From WSL (recommended)

```bash
CP_IP=$(sudo virsh domifaddr k8s-cp01 --source lease | awk '$3=="ipv4" {split($4,a,"/"); print a[1]}')
WORKER_IP=$(sudo virsh domifaddr k8s-worker01 --source lease | awk '$3=="ipv4" {split($4,a,"/"); print a[1]}')

ssh -i ~/.ssh/cka_lab lab@"$CP_IP"
ssh -i ~/.ssh/cka_lab lab@"$WORKER_IP"
```

The control-plane account has `kubectl` configured:

```bash
ssh -i ~/.ssh/cka_lab lab@"$CP_IP" 'kubectl get nodes -o wide'
```

### From the WSL operator host using kubeconfig

The current default-network build uses DHCP, so its kubeconfig must be refreshed after a rebuild. The target design in [Architecture and operations](docs/architecture-and-operations.md) replaces this with a dedicated static `192.168.56.0/24` libvirt network and a stable control-plane endpoint. Once that design is applied, use `kubectl` directly from WSL with `~/.kube/cka-lab`; no Windows-native command workflow is required.

`kubectl` is configured for `lab` only on `k8s-cp01`. Running it on the worker or WSL without a kubeconfig attempts `localhost:8080` and fails; that is expected, not a cluster fault.

## Network architecture

```text
Windows applications
       │  (no direct route to 192.168.122.0/24)
       ▼
WSL2 Ubuntu
       │
       ├─ libvirt default NAT network / virbr0: 192.168.122.1/24
       │       ├─ k8s-cp01: DHCP address, API server TCP/6443
       │       └─ k8s-worker01: DHCP address
       │
       └─ NAT to WSL/Windows network and the Internet

Kubernetes overlay inside the VMs
       └─ Calico Pod CIDR: 10.244.0.0/16
```

The VMs can reach package registries through libvirt NAT. Node-to-node Kubernetes traffic stays on the libvirt network. Calico supplies Pod networking; CoreDNS and workload Pods are not healthy until the CNI is installed.

## What went wrong during the first build—and the fixes

| Symptom | Cause | Permanent fix |
| --- | --- | --- |
| `cloud-localds: command not found` | Cloud-image tooling was absent | Install `cloud-image-utils`. |
| SSH returned `Permission denied (publickey)` | User-data still contained a literal key placeholder | Generate user-data from `~/.ssh/cka_lab.pub`; `recreate.sh` does this every time. |
| Cloud-init YAML looked valid but packages did not install | YAML indentation placed `packages` / `runcmd` inside the user item | Generate YAML using `printf` in the script, then validate with `cloud-init schema`. |
| QEMU could not read files under `/home/devops` | The libvirt QEMU account could not traverse the private home directory | Grant only traversal: `sudo setfacl -m u:libvirt-qemu:--x "$HOME"`. |
| `libvirtd` or `virtqemud` reported inactive | Ubuntu can use socket activation for modular libvirt daemons | Confirm `virsh -c qemu:///system uri`; the service activates when a domain starts. |
| `virsh domifaddr` initially had no address | Guest agent had not reported yet | Use `sudo virsh net-dhcp-leases default`; cloud-init enables `qemu-guest-agent`. |
| Worker was `NotReady` just after join | Calico and kube-proxy were still starting | Wait briefly and check `kubectl get pods -A`; this is normal during CNI initialization. |

## Troubleshooting commands

```bash
# WSL / libvirt
sudo virsh list --all
sudo virsh dominfo k8s-cp01
sudo virsh net-dhcp-leases default
sudo virsh domiflist k8s-cp01

# On either VM
systemctl status kubelet containerd
journalctl -u kubelet -n 100 --no-pager
crictl ps -a
ip addr; ip route; ss -lntp

# On the control plane
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp
```

## Optional next improvements

- Add DHCP reservations for stable node IPs.
- Snapshot a clean, Ready cluster with libvirt before failure drills.
- Practice `kubeadm reset`, certificate inspection, node drains, CNI failures, kubelet failures, and container runtime failures.
- Keep the base Ubuntu image read-only; all VM changes belong in disposable qcow2 overlays.
