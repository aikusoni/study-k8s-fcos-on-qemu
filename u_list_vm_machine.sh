#!/usr/bin/env bash
set -euo pipefail

source ./preconfigured.sh >/dev/null

machines_dir="./machines"
wg_base_dir="./wireguard-client-config/wireguard-vpn"

process_list() {
  ps -axo pid=,command= 2>/dev/null
}

qemu_pids_for_vm() {
  local vm_name="$1"
  process_list | awk -v name="$vm_name" '
    index($0, "qemu-system-aarch64") && index($0, "-name " name) { print $1 }
  ' || true
}

qemu_processes() {
  local processes
  if ! processes="$(process_list)"; then
    echo "Process list unavailable in this environment."
    return 0
  fi

  printf "%s\n" "$processes" | awk '
    index($0, "qemu-system-aarch64") {
      found=1
      pid=$1
      name="-"
      if (match($0, /-name [^ ]+/)) {
        name=substr($0, RSTART + 6, RLENGTH - 6)
      }
      print pid "\t" name
    }
    END {
      if (!found) print "(none)"
    }
  '
}

wireguard_for_vm() {
  local vm_name="$1"
  local dir label wg_no wg_ip role

  if [ ! -d "$wg_base_dir" ]; then
    printf "%s\t%s\t%s\n" "-" "-" "-"
    return
  fi

  for dir in "$wg_base_dir"/*; do
    [ -d "$dir" ] || continue
    [ -f "$dir/using.lock" ] || continue
    [ -f "$dir/wg_ip_address.txt" ] || continue

    label="$(<"$dir/using.lock")"
    if [ "$label" = "$vm_name" ]; then
      wg_no="$(basename "$dir")"
      wg_ip="$(<"$dir/wg_ip_address.txt")"
      role="worker/unknown"
      if [ -f "$MAIN_ADDRESSES_FILE" ] && grep -Fxq "$wg_ip" "$MAIN_ADDRESSES_FILE"; then
        role="control-plane"
      fi
      printf "%s\t%s\t%s\n" "$wg_no" "$wg_ip" "$role"
      return
    fi
  done

  printf "%s\t%s\t%s\n" "-" "-" "-"
}

print_header() {
  printf "%-24s %-8s %-12s %-15s %-8s %-14s %s\n" \
    "VM" "STATE" "PID" "WG_IP" "WG_NO" "ROLE" "IMAGE"
  printf "%-24s %-8s %-12s %-15s %-8s %-14s %s\n" \
    "------------------------" "--------" "------------" "---------------" "--------" "--------------" "-----"
}

if [ ! -d "$machines_dir" ]; then
  echo "No VM machine directory found: $machines_dir"
  echo
  echo "Running QEMU processes:"
  qemu_processes || true
  exit 0
fi

mapfile -t vm_dirs < <(find "$machines_dir" -maxdepth 1 -mindepth 1 -type d | sort)

if [ ${#vm_dirs[@]} -eq 0 ]; then
  echo "No VM machines found under $machines_dir"
  exit 0
fi

print_header
for vm_dir in "${vm_dirs[@]}"; do
  vm_name="$(basename "$vm_dir")"
  pid_list="$(qemu_pids_for_vm "$vm_name" | paste -sd, -)"
  state="stopped"
  [ -n "$pid_list" ] && state="running"

  IFS=$'\t' read -r wg_no wg_ip role < <(wireguard_for_vm "$vm_name")

  image="-"
  if [ -f "$vm_dir/fcos-vm.qcow2" ]; then
    image="$(du -h "$vm_dir/fcos-vm.qcow2" | awk '{print $1}')"
  fi

  printf "%-24s %-8s %-12s %-15s %-8s %-14s %s\n" \
    "$vm_name" "$state" "${pid_list:--}" "$wg_ip" "$wg_no" "$role" "$image"
done

echo
echo "Running QEMU processes:"
qemu_processes || true
