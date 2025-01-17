#!/bin/bash
set -euo pipefail

########################################
# 1) Podman 설치 확인
########################################
if ! command -v podman &>/dev/null; then
  echo "Podman이 설치되어 있지 않습니다. 설치 후 다시 시도하세요."
  exit 1
fi

if ! command -v wg &>/dev/null; then
  echo "WireGuard Tools가 설치되어 있지 않습니다. 설치 후 다시 시도하세요."
  exit 1
fi

########################################
# 2) Podman VM 실행 확인
########################################
machine_name="podman-machine-vpn"

# Podman machine 목록에서 <machine_name>:true 형태로 Running 여부를 확인
# 만약 해당 machine이 없거나 실행 중이 아니면 초기화 & 시작
if ! podman machine list --format '{{.Name}}:{{.Running}}' \
   | grep "^${machine_name}" \
   | grep "true$"; then
  echo "Podman VM이 실행 중이 아닙니다. 실행을 시도합니다..."

  # machine 존재 여부 확인
  if ! podman machine list --format '{{.Name}}' | grep "${machine_name}"; then
    echo "Podman VM(${machine_name})이 존재하지 않아 생성합니다."
    podman machine init "${machine_name}"
  fi

  # machine 시작
  podman machine start "${machine_name}"
fi

########################################
# 3) VPN 이름 입력받기
########################################
read -rp "생성/시작할 VPN(컨테이너) 이름을 입력하세요: " vpn_name

########################################
# 4) 해당 이름의 컨테이너 존재 여부 확인
########################################
if podman container inspect "${vpn_name}" &>/dev/null; then
  ########################################
  # 5) 이미 존재하면 해당 컨테이너 시작
  ########################################
  echo "이미 '${vpn_name}' 컨테이너가 존재합니다. 컨테이너를 시작합니다..."
  podman start "${vpn_name}"
else
  ########################################
  # 6) 존재하지 않으면 초기화 절차 시작
  ########################################
  echo "'${vpn_name}' 컨테이너가 존재하지 않습니다. 새로 생성합니다."

  ########################################
  # 7) IP 범위(CIDR) 설정값 입력받기
  ########################################
  vpn_network_name="${vpn_name}-network"

  read -rp "VPN에서 사용할 IP 범위(CIDR)를 입력하세요 (예: 10.117.0.0/16): " ip_cidr
  ip_base="${ip_cidr%%/*}"
  ip_subnet="${ip_base%.*}"
  gateway_ip="${ip_subnet}.1"
  vpn_server_ip="${ip_subnet}.128"
  cidr="${ip_cidr##*/}"

  # 서버 키 생성
  server_priv=$(wg genkey)
  server_pub=$(echo "$server_priv" | wg pubkey)

  # 클라이언트 키 생성
  client_priv=$(wg genkey)
  client_pub=$(echo "$client_priv" | wg pubkey)

  echo "Server Private Key: $server_priv"
  echo "Server Public Key: $server_pub"
  echo "Client Private Key: $client_priv"
  echo "Client Public Key: $client_pub"
  
  config_dir=~/podman-shared/wireguard-config/${vpn_name}
  mkdir -p "$config_dir"
  cat <<EOF > "${config_dir}/wg0.conf"
[Interface]
Address = $vpn_server_ip/$cidr
ListenPort = 51820
PrivateKey = $server_priv

[Peer]
PublicKey = $client_pub
AllowedIPs = $ip_cidr
EOF

  podman network create --subnet "${ip_cidr}" --gateway "${gateway_ip}" "${vpn_network_name}"

  # WireGuard VPN 컨테이너 생성
  echo "WireGuard VPN 컨테이너를 생성 중입니다..."
  podman run -d \
    --name "${vpn_name}" \
    --network "${vpn_network_name}" \
    --ip "$vpn_server_ip" \
    --cap-add=NET_ADMIN \
    -p 51820:51820/udp \
    -v "$config_dir:/config" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e SERVERURL=0.0.0.0 \
    -e SERVERPORT=51820 \
    -e INTERNAL_SUBNET="${ip_cidr}" \
    docker.io/linuxserver/wireguard:latest

  echo "'${vpn_name}' 컨테이너가 생성되었습니다. 로그나 설정 디렉토리를 확인해 주세요."
fi