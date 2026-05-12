#!/usr/bin/env bash
set -euo pipefail

source ./preconfigured.sh >/dev/null

include_logs=false
if [ "${1:-}" = "--logs" ]; then
  include_logs=true
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--logs]" >&2
  exit 1
fi

ssh_dir="./.ssh"
known_hosts_file="$ssh_dir/known_hosts"
vpn_base_dir="./wireguard-client-config/wireguard-vpn"

ssh_extra_options=()
if ssh -G -T 127.0.0.1 -o WarnWeakCrypto=no-pq-kex >/dev/null 2>&1; then
  ssh_extra_options=(-o WarnWeakCrypto=no-pq-kex)
fi

shopt -s nullglob
mapfile -t priv_keys < <(
  find "$ssh_dir" -maxdepth 1 -type f \
    ! -name "*.pub" \
    ! -name "known_hosts" \
    | sort
)
shopt -u nullglob

if [ ${#priv_keys[@]} -eq 0 ]; then
  echo "ERROR: no SSH private keys found in $ssh_dir" >&2
  exit 1
fi

echo
echo "Select SSH key:"
for i in "${!priv_keys[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${priv_keys[i]}"
done
read -rp "> " key_choice
if ! [[ "$key_choice" =~ ^[0-9]+$ ]] || [ "$key_choice" -lt 1 ] || [ "$key_choice" -gt "${#priv_keys[@]}" ]; then
  echo "ERROR: invalid SSH key selection: $key_choice" >&2
  exit 1
fi
ssh_key="${priv_keys[$((key_choice-1))]}"

shopt -s nullglob
ips=()
dirs=()
labels=()
for dir in "$vpn_base_dir"/*; do
  if [[ -f "$dir/using.lock" && -f "$dir/wg_ip_address.txt" ]]; then
    ips+=("$(<"$dir/wg_ip_address.txt")")
    dirs+=("$(basename "$dir")")
    labels+=("$(<"$dir/using.lock")")
  fi
done
shopt -u nullglob

if [ ${#ips[@]} -eq 0 ]; then
  echo "ERROR: no active WireGuard VPN configs found in $vpn_base_dir" >&2
  exit 1
fi

echo
echo "Select VM WireGuard IP for systemd inspection:"
for i in "${!ips[@]}"; do
  printf "  [%d] %s (%s, %s)\n" "$((i+1))" "${ips[i]}" "${dirs[i]}" "${labels[i]}"
done
read -rp "> " vpn_choice
if ! [[ "$vpn_choice" =~ ^[0-9]+$ ]] || [ "$vpn_choice" -lt 1 ] || [ "$vpn_choice" -gt "${#ips[@]}" ]; then
  echo "ERROR: invalid WireGuard IP selection: $vpn_choice" >&2
  exit 1
fi
vm_ip="${ips[$((vpn_choice-1))]}"

ssh -i "$ssh_key" \
  -o UserKnownHostsFile="$known_hosts_file" \
  -o StrictHostKeyChecking=accept-new \
  "${ssh_extra_options[@]}" \
  "core@$vm_ip" \
  bash -s -- "$include_logs" <<'EOF'
set -euo pipefail

include_logs="$1"
services=(
  NetworkManager.service
  wg-quick@wg0.service
  containerd.service
  kubelet.service
  kubeadm-init.service
  kubeadm-join.service
  kube-flannel.service
  sshd.service
)

echo "== host =="
hostnamectl --static 2>/dev/null || hostname

echo
echo "== addresses =="
ip -br addr || ip addr

echo
echo "== routes =="
ip route || true

echo
echo "== service states =="
printf "%-28s %-12s %-12s %s\n" "UNIT" "LOAD" "ACTIVE" "SUB"
for service in "${services[@]}"; do
  load="$(systemctl show -p LoadState --value "$service" 2>/dev/null || true)"
  active="$(systemctl show -p ActiveState --value "$service" 2>/dev/null || true)"
  sub="$(systemctl show -p SubState --value "$service" 2>/dev/null || true)"
  printf "%-28s %-12s %-12s %s\n" "$service" "${load:-unknown}" "${active:-unknown}" "${sub:-unknown}"
done

echo
echo "== failed units =="
systemctl --no-pager --failed || true

if [ "$include_logs" = "true" ]; then
  echo
  echo "== kubelet logs =="
  sudo journalctl -u kubelet -n 80 --no-pager || true

  echo
  echo "== kubeadm init logs =="
  sudo journalctl -u kubeadm-init -n 80 --no-pager || true

  echo
  echo "== kubeadm join logs =="
  sudo journalctl -u kubeadm-join -n 80 --no-pager || true
fi
EOF
