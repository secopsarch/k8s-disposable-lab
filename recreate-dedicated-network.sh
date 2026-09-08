#!/usr/bin/env bash
# Recreate the CKA lab on a dedicated libvirt NAT network with stable DHCP reservations.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NETWORK="cka-net"
BRIDGE="virbr56"
NETWORK_XML=$(mktemp)
trap 'rm -f "$NETWORK_XML"' EXIT

CP_IP="192.168.56.10"
WORKER_IP="192.168.56.11"
CP_MAC="52:54:00:56:00:10"
WORKER_MAC="52:54:00:56:00:11"
KUBECONFIG_FILE="$HOME/.kube/cka-lab"
THREE_NODE=false
WORKER2_IP=""
WORKER2_MAC=""
if [[ ${1:-} == "--three-node" ]]; then
  THREE_NODE=true
  WORKER2_IP="192.168.56.12"
  WORKER2_MAC="52:54:00:56:00:12"
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--three-node]" >&2
  exit 2
fi

command -v virsh >/dev/null || { echo "Missing required command: virsh" >&2; exit 1; }
command -v ip >/dev/null || { echo "Missing required command: ip" >&2; exit 1; }

# Domains must be absent before their private network can be recreated safely.
"$ROOT_DIR/destroy.sh" --purge

cat > "$NETWORK_XML" <<EOF
<network>
  <name>${NETWORK}</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='192.168.56.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.56.100' end='192.168.56.254'/>
      <host mac='${CP_MAC}' name='k8s-cp01' ip='${CP_IP}'/>
      <host mac='${WORKER_MAC}' name='k8s-worker01' ip='${WORKER_IP}'/>
EOF

if [[ $THREE_NODE == true ]]; then
  printf "      <host mac='%s' name='k8s-worker02' ip='%s'/>\n" "$WORKER2_MAC" "$WORKER2_IP" >> "$NETWORK_XML"
fi

cat >> "$NETWORK_XML" <<'EOF'
    </dhcp>
  </ip>
</network>
EOF

if sudo virsh net-info "$NETWORK" >/dev/null 2>&1; then
  sudo virsh net-destroy "$NETWORK" 2>/dev/null || true
  sudo virsh net-undefine "$NETWORK"
fi

# A failed/aborted libvirt network teardown can leave the fixed lab bridge
# behind. It is safe to remove only when it has no attached interfaces.
if ip link show dev "$BRIDGE" >/dev/null 2>&1; then
  bridge_ports=$(ip -o link show master "$BRIDGE" 2>/dev/null || true)
  if [[ -n $bridge_ports ]]; then
    echo "Refusing to remove $BRIDGE: interfaces are still attached:" >&2
    printf '%s\n' "$bridge_ports" >&2
    exit 1
  fi
  sudo ip link delete dev "$BRIDGE" type bridge
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
WORKER2_STATIC_IP="$WORKER2_IP" \
WORKER2_MAC="$WORKER2_MAC" \
exec "$ROOT_DIR/recreate.sh"
