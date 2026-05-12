#!/usr/bin/env bash
set -euo pipefail

source ./preconfigured.sh >/dev/null

section() {
  echo
  echo "== $1 =="
}

run_or_note() {
  local description="$1"
  shift
  echo "$description"
  "$@" || echo "  unavailable"
}

section "Tools"
for tool in podman wg qemu-img qemu-system-aarch64 butane kubectl; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf "%-20s %s\n" "$tool" "$(command -v "$tool")"
  else
    printf "%-20s %s\n" "$tool" "missing"
  fi
done

section "Podman Machine"
if command -v podman >/dev/null 2>&1; then
  run_or_note "podman machine list:" podman machine list
else
  echo "podman is not installed."
fi

section "Podman Containers"
if command -v podman >/dev/null 2>&1; then
  if ! podman info >/dev/null 2>&1; then
    echo "Podman API is unavailable. Start the Podman machine first or run outside a restricted sandbox."
  else
    for container in wireguard-vpn haproxy; do
      if podman container exists "$container" >/dev/null 2>&1; then
        podman inspect "$container" \
          --format '{{.Name}} status={{.State.Status}} image={{.ImageName}} ports={{range $k,$v := .HostConfig.PortBindings}}{{$k}} {{end}}'
      else
        echo "$container: missing"
      fi
    done
  fi
else
  echo "podman is not installed."
fi

section "Host WireGuard"
if command -v wg >/dev/null 2>&1; then
  if sudo -n wg show >/dev/null 2>&1; then
    sudo -n wg show
  elif wg show >/dev/null 2>&1; then
    wg show
  else
    echo "WireGuard status unavailable without sudo or no interface is active."
  fi
else
  echo "wg is not installed."
fi

section "Load Balancer Backends"
if [ -f "$MAIN_ADDRESSES_FILE" ]; then
  nl -ba "$MAIN_ADDRESSES_FILE"
else
  echo "No control-plane backend file found: $MAIN_ADDRESSES_FILE"
fi

section "VM Machines"
if [ -x ./u_list_vm_machine.sh ]; then
  ./u_list_vm_machine.sh
else
  echo "u_list_vm_machine.sh is not executable."
fi
