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

# VPN 이름
vpn_name="wireguard-vpn"

# VPN 컨테이너 존재 확인
if podman container inspect "${vpn_name}" &>/dev/null; then
  echo "이미 '${vpn_name}' 컨테이너가 존재합니다."

  # 이미 컨테이너가 실행 중이면 종료
  if podman container inspect "${vpn_name}" --format '{{.State.Status}}' | grep -q "running"; then
    echo "'${vpn_name}' 컨테이너가 이미 실행 중입니다. 종료합니다."
    exit 0
  fi

  echo "'${vpn_name}' 컨테이너가 종료되어 있습니다. 시작합니다."
  podman start "${vpn_name}"
  exit 0
fi

# 컨테이너가 존재하지 않으면 생성
echo "'${vpn_name}' 컨테이너가 존재하지 않습니다. 새로 생성합니다."

read -rp "VPN에서 사용할 IP 범위(CIDR)를 입력하세요. (예: 10.117.0.0/16): " ip_cidr

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
mkdir -p "$config_dir/wg_confs"
cat <<EOF > "${config_dir}/wg_confs/wg0.conf"
[Interface]
Address = $vpn_server_ip/$cidr
ListenPort = 51820
PrivateKey = $server_priv

[Peer]
PublicKey = $client_pub
AllowedIPs = $ip_cidr
EOF

# WireGuard VPN 컨테이너 생성
echo "WireGuard VPN 컨테이너를 생성 중입니다..."
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

echo "'${vpn_name}' 컨테이너가 생성되었습니다. 로그나 설정 디렉토리를 확인해 주세요."

container_ip=$(podman inspect wireguard | jq -r ".[0].NetworkSettings.IPAddress")
echo "WireGuard 컨테이너 IP: ${container_ip}"

client_config_dir=./wireguard-client-config/${vpn_name}
client_config_file=${client_config_dir}/wg0.conf
mkdir -p "$client_config_dir"
cat <<EOF > "${client_config_file}"
[Interface]
PrivateKey = $client_priv
Address = ${ip_subnet}.2/${cidr}

[Peer]
PublicKey = $server_pub
Endpoint = localhost:51820
AllowedIPs = $ip_cidr
PersistentKeepalive = 25
EOF

echo "VPN 연결 테스트를 시작합니다..."
sudo wg-quick up "${client_config_file}"
echo "VPN 인터페이스가 활성화되었습니다. 연결 테스트를 진행합니다..."

# 잠시 대기하여 인터페이스 설정이 완료되도록 함
sleep 5

# VPN을 통해 서버에 ping 테스트 시도
if ping -c 4 "${vpn_server_ip}" &>/dev/null; then
  echo "VPN 연결 성공: 서버(${vpn_server_ip})에 ping 응답이 있습니다."
else
  echo "VPN 연결 실패: 서버(${vpn_server_ip})에 ping 응답이 없습니다."
fi

# VPN 인터페이스 비활성화
sudo wg-quick down "${client_config_file}"

echo "VPN 연결 테스트가 완료되었습니다."

# 키 저장
echo "테스트를 위한 키를 저장 중입니다..."
mkdir -p ./keys

echo "$server_pub" > "./keys/${vpn_name}_server_pubkey"
echo "$client_priv" > "./keys/${vpn_name}_client_privkey"

echo "키 저장이 완료되었습니다."
echo "경로: ./keys/${vpn_name}_server_pubkey, ./keys/${vpn_name}_client_privkey"