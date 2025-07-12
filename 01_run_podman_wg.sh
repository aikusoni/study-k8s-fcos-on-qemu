#!/bin/bash

set -euo pipefail

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

  echo "'${vpn_name}' container is 
  . Starting..."
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
# Hub And Spoke Topology
echo "Creating WireGuard VPN container..."
podman run -d \
  --name "${vpn_name}" \
  --cap-add=NET_ADMIN \
  --sysctl net.ipv4.ip_forward=1 \
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
client_config_file="${client_config_dir}/${PRECONFIGURED_HOST_WIREGUARD_CLIENT_NO}/wg0.conf"
echo "This wg config file will be used by host machine." > "${client_config_dir}/${PRECONFIGURED_HOST_WIREGUARD_CLIENT_NO}/using.lock"
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