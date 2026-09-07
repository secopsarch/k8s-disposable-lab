# LinkedIn post

I built a disposable, two-node Kubernetes lab on Windows 11 without relying on a cloud account or a single-node development cluster.

The stack is:

`Windows 11 → WSL2 Ubuntu → KVM/libvirt → Ubuntu VMs → kubeadm + containerd + Calico`

The core use case is CKA-style administration practice with real node boundaries: separate systemd services, kubelet and containerd logs, networking, certificates, CNI behavior, and a safe environment to deliberately break and recover components.

The lab uses a dedicated libvirt network with stable DHCP reservations:

- Control plane: `192.168.56.10`
- Worker: `192.168.56.11`
- Stable API endpoint: `192.168.56.10:6443`
- Refreshed WSL kubeconfig after every rebuild

That last part matters: the cluster remains disposable, but the operator experience stays simple. A preflight check validates KVM, libvirt, dependencies, capacity, and network availability before recreation; the workflow then waits for nodes, Calico, and CoreDNS before declaring success.

The result is a compact lab for practicing the things that matter when Kubernetes is not healthy: kubelet, containerd, CNI, DNS, certificates, API server static Pods, scheduler/controller-manager behavior, routes, taints, and labels.

I wrote up the architecture, tradeoffs, and build approach here: **[insert Medium article URL]**

Project updates: [https://github.com/secopsarch](https://github.com/secopsarch)

#Kubernetes #CKA #DevOps #Homelab #WSL #Kubeadm
