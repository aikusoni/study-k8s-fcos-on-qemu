#!/bin/bash

# This script initializes wireguard vpn server on host machine via podman.
# The script will generate wireguard vpn server configuration file.
# The script will generate vpn client configuration files. (./wireguard-client-config/*/wg0.conf)

set -euo pipefail

if ! command -v podman &>/dev/null; then
  echo "Podman is required. Please install Podman and try again."
  exit 1
fi

if ! command -v wg &>/dev/null; then
  echo "WireGuard Tools is required. Please install WireGuard Tools and try again."
  exit 1
fi

source ./preconfigured.sh

machine_name="${PODMAN_MACHINE_NAME}"

# Podman machine 목록에서 <machine_name>:true 형태로 Running 여부를 확인
# 만약 해당 machine이 없거나 실행 중이 아니면 초기화 & 시작
if ! podman machine list --format '{{.Name}}:{{.Running}}' \
   | grep "^${machine_name}" \
   | grep "true$"; then
  echo "Podman Vm is not running. Trying to start..."

  # machine 존재 여부 확인
  if ! podman machine list --format '{{.Name}}' | grep "${machine_name}"; then
    echo "Podman VM(${machine_name}) does not exist. Initializing..."
    podman machine init "${machine_name}"
  fi

  # machine 시작
  podman machine start "${machine_name}"
fi

# VPN 이름
vpn_name="wireguard-vpn"

# VPN 컨테이너 존재 확인
if podman container inspect "${vpn_name}" &>/dev/null; then
  echo "${vpn_name} already exists."

  # 이미 컨테이너가 실행 중이면 종료
  if podman container inspect "${vpn_name}" --format '{{.State.Status}}' | grep -q "running"; then
    echo "'${vpn_name}' container is already running. Exiting."
    exit 0
  fi

  echo "'${vpn_name}' container is stopped. Starting..."
  podman start "${vpn_name}"
  exit 0
fi

# 컨테이너가 존재하지 않으면 생성
echo "Creating '${vpn_name}' container..."

ip_cidr=$PRECONFIGURED_WIREGUARD_IP_CIDR

ip_base="${ip_cidr%%/*}"
ip_subnet="${ip_base%.*}"
vpn_server_ip="${ip_subnet}.1"
cidr="${ip_cidr##*/}"

# 서버 키 생성
server_priv=$(wg genkey)
server_pub=$(echo "$server_priv" | wg pubkey)

echo "Server Private Key: $server_priv"
echo "Server Public Key: $server_pub"

config_dir=~/podman-shared/wireguard-config/${vpn_name}
mkdir -p "$config_dir/wg_confs"
server_config_file="${config_dir}/wg_confs/wg0.conf"
cat <<EOF > "${server_config_file}"
[Interface]
Address = $vpn_server_ip/$cidr
ListenPort = 51820
PrivateKey = $server_priv

EOF

client_config_dir=./wireguard-client-config/${vpn_name}
for ((i=2; i<=254; i++)); do
  client_number=$(printf "%03d" "$i")

  echo "Generating client configuration for client $client_number..."

  client_priv=$(wg genkey)
  client_pub=$(echo "$client_priv" | wg pubkey)
  client_ip="${ip_subnet}.${i}"
  
  mkdir -p "$client_config_dir/$client_number"
  client_config_file=${client_config_dir}/${client_number}/wg0.conf
  
  cat <<EOF > "${client_config_file}"
[Interface]
PrivateKey = $client_priv
Address = $client_ip/$cidr

[Peer]
PublicKey = $server_pub
Endpoint = localhost:51820
AllowedIPs = $ip_cidr
PersistentKeepalive = 25
EOF

  echo "${client_ip}" > "${client_config_dir}/${client_number}/wg_ip_address.txt"

  echo "Client $client_number configuration generated."

  echo "Append client configuration to server configuration..."

  cat <<EOF >> "${server_config_file}"
[Peer]
PublicKey = $client_pub
AllowedIPs = $client_ip/32

EOF

  echo "Client $client_number configuration appended to server configuration."

done

# WireGuard VPN 컨테이너 생성
echo "Creating WireGuard VPN container..."
podman run -d \
  --name "${vpn_name}" \
  --cap-add=NET_ADMIN \
  -p=51820:51820/udp \
  -p=51821:51821/tcp \
  -v "$config_dir:/config" \
  -e PUID=1000 \
  -e PGID=1000 \
  -e SERVERPORT=51820 \
  -e INTERNAL_SUBNET="${ip_cidr}" \
  -e ALLOWEDIPS=0.0.0.0/0 \
  docker.io/linuxserver/wireguard:latest

echo "${vpn_name} container has been created. Please check the logs or configuration directory."

echo "Testing VPN connection..."
client_config_file="${client_config_dir}/${PRECONFIGURED_WIREGUARD_CHECK_CLIENT_NO}/wg0.conf"
echo "This wg config file will be used by host machine." > "${client_config_dir}/${PRECONFIGURED_WIREGUARD_CHECK_CLIENT_NO}/using.lock"
sudo wg-quick up "${client_config_file}"
echo "VPN interface is up. Testing connection..."

# 잠시 대기하여 인터페이스 설정이 완료되도록 함
sleep 5

# VPN을 통해 서버에 ping 테스트 시도
if ping -c 4 "${vpn_server_ip}" &>/dev/null; then
  echo "VPN connection successful: Server(${vpn_server_ip}) is reachable."
else
  echo "VPN connection failed: Server(${vpn_server_ip}) is unreachable."
fi

# VPN 인터페이스 비활성화
sudo wg-quick down "${client_config_file}"

echo "VPN connection test completed."
echo "Ip range: ${ip_cidr}"