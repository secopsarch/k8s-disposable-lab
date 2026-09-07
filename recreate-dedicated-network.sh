#!/usr/bin/env bash
# Recreate the CKA lab on a dedicated libvirt NAT network with stable DHCP reservations.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NETWORK="cka-net"
NETWORK_XML=$(mktemp)
trap 'rm -f "$NETWORK_XML"' EXIT

CP_IP="192.168.56.10"
WORKER_IP="192.168.56.11"
CP_MAC="52:54:00:56:00:10"
WORKER_MAC="52:54:00:56:00:11"
KUBECONFIG_FILE="$HOME/.kube/cka-lab"

command -v virsh >/dev/null || { echo "Missing required command: virsh" >&2; exit 1; }

# Domains must be absent before their private network can be recreated safely.
"$ROOT_DIR/destroy.sh" --purge

cat > "$NETWORK_XML" <<EOF
<network>
  <name>${NETWORK}</name>
  <forward mode='nat'/>
  <bridge name='virbr56' stp='on' delay='0'/>
  <ip address='192.168.56.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.56.100' end='192.168.56.254'/>
      <host mac='${CP_MAC}' name='k8s-cp01' ip='${CP_IP}'/>
      <host mac='${WORKER_MAC}' name='k8s-worker01' ip='${WORKER_IP}'/>
    </dhcp>
  </ip>
</network>
EOF

if sudo virsh net-info "$NETWORK" >/dev/null 2>&1; then
  sudo virsh net-destroy "$NETWORK" 2>/dev/null || true
  sudo virsh net-undefine "$NETWORK"
fi
sudo virsh net-define "$NETWORK_XML"
sudo virsh net-autostart "$NETWORK"
sudo virsh net-start "$NETWORK"

LAB_NETWORK="$NETWORK" \
CP_STATIC_IP="$CP_IP" \
WORKER_STATIC_IP="$WORKER_IP" \
CP_MAC="$CP_MAC" \
WORKER_MAC="$WORKER_MAC" \
CONTROL_PLANE_ENDPOINT="${CP_IP}:6443" \
KUBECONFIG_TARGET="$KUBECONFIG_FILE" \
exec "$ROOT_DIR/recreate.sh"
