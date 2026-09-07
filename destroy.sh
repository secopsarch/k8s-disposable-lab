#!/usr/bin/env bash
# Stop and remove only this lab's libvirt domains. --purge also deletes its named disposable artifacts.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PURGE=false

if [[ ${1:-} == "--purge" ]]; then
  PURGE=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--purge]" >&2
  exit 2
fi

for domain in k8s-worker01 k8s-cp01; do
  if sudo virsh dominfo "$domain" >/dev/null 2>&1; then
    state=$(sudo virsh domstate "$domain" | tr -d '\r')
    if [[ $state == running || $state == paused ]]; then
      sudo virsh destroy "$domain"
    fi
    sudo virsh undefine "$domain" --nvram 2>/dev/null || sudo virsh undefine "$domain"
  fi
done

if [[ $PURGE == true ]]; then
  # Explicit paths only: base image and SSH key are intentionally retained.
  rm -f -- \
    "$ROOT_DIR/disks/k8s-cp01.qcow2" \
    "$ROOT_DIR/disks/k8s-cp01-rebuild.qcow2" \
    "$ROOT_DIR/disks/k8s-worker01.qcow2" \
    "$ROOT_DIR/seed/cp-seed.iso" \
    "$ROOT_DIR/seed/cp-seed-fixed.iso" \
    "$ROOT_DIR/seed/worker-seed.iso" \
    "$ROOT_DIR/seed/worker-seed-fixed.iso"
  echo "Purged disposable VM overlays and generated seed ISOs."
else
  echo "Domains removed; VM disks retained. Run '$0 --purge' to remove disposable overlays."
fi
