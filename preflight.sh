#!/usr/bin/env bash
# Read-only prerequisite validation for the KVM / libvirt CKA lab.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MODE="${1:---dedicated}"
case "$MODE" in
  --dedicated|--default) ;;
  *) echo "Usage: $0 [--dedicated|--default]" >&2; exit 2 ;;
esac

failures=0
warnings=0
ok() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

required_packages=(
  qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst qemu-utils
  cloud-image-utils cloud-init ovmf acl curl gpg openssh-client coreutils libosinfo-bin
)
missing_packages=()
for package in "${required_packages[@]}"; do
  dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed || missing_packages+=("$package")
done

if (( ${#missing_packages[@]} )); then
  fail "Missing WSL host packages: ${missing_packages[*]}"
  printf '      Install: sudo apt update && sudo apt install -y %s\n' "${missing_packages[*]}" >&2
else
  ok "Required WSL host packages are installed"
fi

if [[ -c /dev/kvm ]]; then ok "/dev/kvm is available"; else fail "/dev/kvm is unavailable; nested KVM is required"; fi

if sudo -v; then
  ok "sudo authentication is available"
else
  fail "sudo authentication is required for libvirt and node provisioning"
fi

if virsh -c qemu:///system uri >/dev/null 2>&1; then
  ok "libvirt qemu:///system connection is available"
else
  fail "libvirt qemu:///system is unavailable; start or repair libvirt"
fi

if getent passwd libvirt-qemu >/dev/null; then
  if getfacl -cp "$HOME" 2>/dev/null | grep -qx 'user:libvirt-qemu:--x'; then
    ok "libvirt-qemu can traverse the WSL home directory"
  else
    warn "libvirt-qemu cannot yet traverse $HOME; the recreation script will add the minimal ACL"
  fi
fi

available_mib=$(awk '/MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
if (( available_mib >= 7168 )); then ok "Available WSL memory: ${available_mib} MiB"; else warn "Available WSL memory: ${available_mib} MiB; 7 GiB+ is recommended"; fi

available_disk_mib=$(df -Pm "$ROOT_DIR" | awk 'NR == 2 {print $4}')
if (( available_disk_mib >= 51200 )); then ok "Available workspace disk: ${available_disk_mib} MiB"; else warn "Available workspace disk: ${available_disk_mib} MiB; 50 GiB+ is recommended"; fi

if curl -fsSI --connect-timeout 8 https://cloud-images.ubuntu.com/noble/current/ >/dev/null; then
  ok "Ubuntu cloud-image endpoint is reachable"
else
  warn "Ubuntu cloud-image endpoint was not reachable; an existing base image can still be used"
fi

if [[ $MODE == --default ]]; then
  if sudo virsh net-info default >/dev/null 2>&1; then ok "libvirt default network is defined"; else fail "libvirt default network is missing"; fi
else
  if sudo virsh net-info cka-net >/dev/null 2>&1; then
    warn "cka-net already exists; recreate-dedicated-network.sh will replace only that lab network"
  elif ip route show | grep -qE '(^| )192\.168\.56\.0/24'; then
    fail "192.168.56.0/24 already exists in the WSL routing table; choose another non-overlapping lab CIDR"
  else
    ok "192.168.56.0/24 is available for cka-net"
  fi
fi

active_domains=$(sudo virsh list --name 2>/dev/null | grep -E '^(k8s-cp01|k8s-worker01)$' || true)
if [[ -n $active_domains ]]; then
  warn "Existing lab domains will be destroyed by a recreate script: ${active_domains//$'\n'/, }"
else
  ok "No running lab domains detected"
fi

if (( failures )); then
  printf '\nPreflight failed with %d blocking issue(s). Resolve them before recreating.\n' "$failures" >&2
  exit 1
fi

printf '\nPreflight passed with %d warning(s). You may run the selected recreate workflow.\n' "$warnings"
