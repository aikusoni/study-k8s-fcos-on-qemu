#!/usr/bin/env bash
set -euo pipefail

# ssh_to_vm.sh
# ./machines 디렉토리에서 VM에 SSH로 접속하는 스크립트

# 환경 설정 파일 로드 (PRECONFIGURED_VM_IP_START 등)
source ./preconfigured.sh
ssh_dir="./.ssh"
known_hosts_file="$ssh_dir/known_hosts"

# 1) SSH 키 목록 (known_hosts 제외)
shopt -s nullglob
mapfile -t priv_keys < <(
  find "$ssh_dir" -maxdepth 1 -type f \
    ! -name "*.pub" \
    ! -name "known_hosts" \
    | sort
)
shopt -u nullglob

if [ ${#priv_keys[@]} -eq 0 ]; then
  echo "❌ SSH 개인키를 $ssh_dir 에서 찾을 수 없습니다."
  exit 1
fi

echo "Available SSH private keys:"
for i in "${!priv_keys[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${priv_keys[i]}"
done
read -rp "Select SSH key (1-${#priv_keys[@]}): " key_choice
if ! [[ "$key_choice" =~ ^[0-9]+$ ]] || [ "$key_choice" -lt 1 ] || [ "$key_choice" -gt "${#priv_keys[@]}" ]; then
  echo "❌ Invalid selection: $key_choice"
  exit 1
fi
ssh_key="${priv_keys[$((key_choice-1))]}"
echo "▶ Using SSH key: $ssh_key"

# 2) WireGuard VPN IP 목록 선택
vpn_base_dir="./wireguard-client-config/wireguard-vpn"
shopt -s nullglob
ips=()
dirs=()
for dir in "$vpn_base_dir"/*; do
  if [[ -f "$dir/using.lock" ]] && [[ -f "$dir/wg_ip_address.txt" ]]; then
    ip=$(<"$dir/wg_ip_address.txt")
    ips+=("$ip")
    dirs+=("$(basename "$dir")")
  fi
done
shopt -u nullglob

if [ ${#ips[@]} -eq 0 ]; then
  echo "❌ 사용 중인 WireGuard VPN이 없습니다."
  exit 1
fi

echo "Available WireGuard VPN IPs:"
for i in "${!ips[@]}"; do
  printf "  [%d] %s (%s)\n" "$((i+1))" "${ips[i]}" "${dirs[i]}"
done
read -rp "Select VPN IP (1-${#ips[@]}): " vpn_choice
if ! [[ "$vpn_choice" =~ ^[0-9]+$ ]] || [ "$vpn_choice" -lt 1 ] || [ "$vpn_choice" -gt "${#ips[@]}" ]; then
  echo "❌ Invalid selection: $vpn_choice"
  exit 1
fi
vm_ip="${ips[$((vpn_choice-1))]}"
echo "▶ Connecting to VPN VM at $vm_ip"

# 3) SSH 접속
ssh -i "$ssh_key" \
    -o UserKnownHostsFile="$known_hosts_file" \
    -o StrictHostKeyChecking=accept-new \
    core@"$vm_ip"