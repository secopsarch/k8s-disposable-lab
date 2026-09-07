# Building a Disposable Kubernetes CKA Lab on Windows 11 with WSL2, KVM, and kubeadm

Kubernetes certification practice is most useful when the environment behaves like real infrastructure.

That is why I did not want another single-node development cluster or a throwaway Docker abstraction. I wanted separate Linux nodes, an actual container runtime, kubelet and systemd logs, kubeadm bootstrap, CNI behavior, certificates, and a safe place to break things deliberately.

The result is a compact, reproducible CKA practice lab:

```text
Windows 11
  └─ WSL2 Ubuntu 24.04
       └─ KVM / QEMU + libvirt
            └─ cka-net: 192.168.56.0/24
                 ├─ k8s-cp01      192.168.56.10
                 └─ k8s-worker01  192.168.56.11
                      └─ kubeadm + containerd + Calico
```

The operator workflow stays inside WSL. The control plane publishes a stable API endpoint at `192.168.56.10:6443`, and a refreshed kubeconfig gives the WSL host direct `kubectl` access after every rebuild.

## Why not kind, Minikube, or two WSL distributions?

Those tools are excellent for application development. They are not wrong choices; they simply optimize for a different goal.

For CKA-style administration, I wanted two independently booted Ubuntu machines with their own hostname, filesystem, IP address, process tree, systemd services, and container runtime. That makes the following investigations real rather than simulated:

```bash
systemctl status kubelet containerd
journalctl -u kubelet
crictl ps -a
ip addr
ip route
ss -lntp
```

KVM virtual machines provide a clean node boundary without leaving the Windows and WSL workflow.

## The architecture

The lab uses nested virtualization exposed by WSL2 through `/dev/kvm`.

```text
WSL Ubuntu operator host
  ├─ kubeconfig: ~/.kube/cka-lab
  ├─ libvirt NAT network: cka-net
  │    gateway: 192.168.56.1
  │
  ├─ k8s-cp01
  │    2 vCPU, 3 GiB RAM, 20 GiB qcow2
  │    192.168.56.10
  │    kube-apiserver, etcd, scheduler, controller-manager
  │
  └─ k8s-worker01
       2 vCPU, 2 GiB RAM, 20 GiB qcow2
       192.168.56.11
       kubelet, containerd, Calico
```

Three non-overlapping networks keep the design predictable:

| Purpose | CIDR |
| --- | --- |
| Libvirt node network | `192.168.56.0/24` |
| Kubernetes Services | `10.96.0.0/12` |
| Kubernetes Pods | `10.244.0.0/16` |

The nodes receive their stable addresses through libvirt DHCP reservations, not static guest configuration. Fixed MAC addresses map to `.10` and `.11`, while libvirt remains responsible for the virtual network.

## The important design choice: stable networking plus disposable certificates

The first version of the lab used libvirt's default DHCP network. It worked, but each new control-plane VM could receive a different IP address. That matters because `kubeadm` writes the API server endpoint and client certificates into `admin.conf`.

The dedicated network fixes the endpoint problem:

```bash
sudo kubeadm init \
  --control-plane-endpoint 192.168.56.10:6443 \
  --apiserver-advertise-address 192.168.56.10 \
  --pod-network-cidr 10.244.0.0/16
```

The address remains stable across rebuilds. The cluster CA and client credentials do not—and that is deliberate. A disposable cluster should receive a fresh identity. The workflow therefore replaces `~/.kube/cka-lab` only after both nodes, Calico, and CoreDNS are healthy.

```bash
kubectl --kubeconfig ~/.kube/cka-lab get nodes -o wide
```

This is a small detail with a large practical effect: the local administration experience stays simple without retaining stale credentials from a prior cluster.

## Reproducibility starts before the first VM

The lab has a read-only preflight gate. Before recreating anything, it validates the WSL host for the things that actually matter:

- `/dev/kvm` is available.
- libvirt can connect to `qemu:///system`.
- Required host packages, SSH, cloud-image tooling, OVMF, and ACL tools exist.
- Available memory and disk are sensible for two VMs.
- The Ubuntu cloud-image endpoint is reachable.
- `192.168.56.0/24` does not collide with an existing route.
- Existing lab VMs are identified before a recreation removes them.

The guest VMs do not need manual prerequisite installation. Cloud-init creates the lab account and SSH access, while the rebuild process configures kernel modules, sysctls, containerd with the systemd cgroup driver, and Kubernetes v1.35 packages.

## From empty disks to a Ready cluster

The build path is intentionally short:

1. Validate the WSL host.
2. Define `cka-net` with DHCP reservations.
3. Build thin qcow2 overlays from an Ubuntu 24.04 cloud image.
4. Create the control-plane and worker VMs with libvirt.
5. Wait for DHCP, SSH, and cloud-init.
6. Prepare containerd and Kubernetes packages on both nodes.
7. Run `kubeadm init` on the control plane.
8. Install Calico.
9. Run `kubeadm join` on the worker.
10. Wait for nodes, Calico, and CoreDNS to be Ready.
11. Label the worker and refresh the operator kubeconfig.

The validation is state-based rather than a single arbitrary sleep. That is important when package downloads or image pulls are slower than expected.

## The lab is for failure, not just success

The best reason to build separate nodes is the recovery practice they enable. A clean snapshot makes it safe to work through failures such as:

- stopping and recovering `kubelet` or `containerd`;
- disabling and restoring CNI configuration;
- scaling CoreDNS down and recovering DNS;
- inspecting certificate expiry and testing a broken *copy* of kubeconfig;
- temporarily removing API server, scheduler, or controller-manager static-Pod manifests and restoring them;
- breaking a worker's Pod-CIDR route and recovering it;
- practicing labels, taints, tolerations, drains, and scheduling behavior.

The principle is simple: move files instead of deleting them, preserve an SSH or libvirt-console recovery path, and verify every recovery with `kubectl`, `journalctl`, and runtime tools.

## What this project demonstrates

This is not a production Kubernetes blueprint. It is a focused personal lab for building administrator muscle memory:

- real node boundaries without a separate physical server;
- repeatable cluster bootstrap with kubeadm;
- stable networking for simple kubeconfig access;
- fresh credentials and overlays for disposable practice;
- controlled failure drills that resemble real operational work.

For anyone preparing for CKA, or simply wanting to understand what sits below `kubectl get pods`, this is a practical bridge between a local workstation and a multi-node Kubernetes environment.

Source updates and the lab project: [github.com/secopsarch](https://github.com/secopsarch)

---

**Suggested Medium tags:** `Kubernetes`, `CKA`, `DevOps`, `WSL`, `Homelab`
