#!/usr/bin/env bash
set -euo pipefail

source ./preconfigured.sh

# 기존 static config 생성 블록 삭제하고, 아래와 같이 교체
# ------------------------------------------------------------------
# Generate HAProxy config from main-addresses.txt
echo "$HAPROXY_PATH"
cat << EOF > "$HAPROXY_PATH" 
############################################
# global settings
############################################
global
    log stdout format raw local0
    maxconn 4096
    tune.ssl.default-dh-param 2048

############################################
# default proxy settings
############################################
defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  50s
    timeout server  50s

############################################
# frontend for Kubernetes API server
############################################
frontend kubernetes_api
    bind *:${API_SERVER_PORT}
    default_backend k8s_masters

############################################
# frontend for etcd client connections
############################################
frontend etcd_client
    bind *:${ETCD_CLIENT_PORT}
    default_backend etcd_clients

############################################
# frontend for etcd peer communications
############################################
frontend etcd_peer
    bind *:${ETCD_PEER_PORT}
    default_backend etcd_peers

############################################
# backend pool of master nodes for API server
############################################
backend k8s_masters
    balance     roundrobin
    option      tcp-check
    tcp-check   connect port ${API_SERVER_PORT}
EOF

# append each master address into k8s_masters
if [ -f "$MAIN_ADDRESSES_FILE" ]; then
  idx=0
  while read -r ip; do
    echo "    server master${idx} ${ip}:${API_SERVER_PORT} check inter 5s fall 2 rise 3" \
      >> "$HAPROXY_PATH"
    idx=$((idx + 1))
  done < "$MAIN_ADDRESSES_FILE"
else
  echo "[INFO] \"$MAIN_ADDRESSES_FILE\" not found, skipping API backends"
fi

# etcd client backend
cat << EOF >> "$HAPROXY_PATH"

############################################
# backend pool of master nodes for etcd client
############################################
backend etcd_clients
    balance     roundrobin
    option      tcp-check
    tcp-check   connect port ${ETCD_CLIENT_PORT}
EOF

if [ -f "$MAIN_ADDRESSES_FILE" ]; then
  idx=0
  while read -r ip; do
    echo "    server master${idx} ${ip}:${ETCD_CLIENT_PORT} check inter 5s fall 2 rise 3" \
      >> "$HAPROXY_PATH"
    idx=$((idx + 1))
  done < "$MAIN_ADDRESSES_FILE"
else
  echo "[INFO] \"$MAIN_ADDRESSES_FILE\" not found, skipping etcd client backends"
fi

# etcd peer backend
cat << EOF >> "$HAPROXY_PATH"

############################################
# backend pool of master nodes for etcd peer
############################################
backend etcd_peers
    balance     roundrobin
    option      tcp-check
    tcp-check   connect port ${ETCD_PEER_PORT}
EOF

if [ -f "$MAIN_ADDRESSES_FILE" ]; then
  idx=0
  while read -r ip; do
    echo "    server master${idx} ${ip}:${ETCD_PEER_PORT} check inter 5s fall 2 rise 3" \
      >> "$HAPROXY_PATH"
    idx=$((idx + 1))
  done < "$MAIN_ADDRESSES_FILE"
else
  echo "[INFO] \"$MAIN_ADDRESSES_FILE\" not found, skipping etcd peer backends"
fi

# optional stats section (unchanged)
cat << EOF >> "$HAPROXY_PATH"

############################################
# optional: HAProxy 통계 페이지
############################################
listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /
    stats refresh 10s
    stats auth ${HAPROXY_STAT_USER}:${HAPROXY_STAT_PASSWORD}
EOF

REQUIRED_PORTS=( \
  "${API_SERVER_PORT}" \
  "${ETCD_CLIENT_PORT}" \
  "${ETCD_PEER_PORT}" \
  "9000" \
)

# helper: check if haproxy container has a given host port bound
container_has_port() {
  local port="$1"
  podman inspect haproxy \
    --format '{{range $k,$v := .HostConfig.PortBindings}}{{$k}} {{end}}' \
    | grep -qw "${port}/tcp"
}

# if container exists, verify all REQUIRED_PORTS are present
if podman container exists haproxy; then
  for p in "${REQUIRED_PORTS[@]}"; do
    if ! container_has_port "$p"; then
      echo "[INFO] Port $p not found in existing haproxy container; recreating it"
      podman rm -f haproxy
      break
    fi
  done
fi

# Ensure HAProxy container exists
if ! podman ps -a --format '{{.Names}}' | grep -qw haproxy; then
  echo "[INFO] Creating HAProxy container (paused)..."
  podman create \
    --name haproxy \
    -p ${API_SERVER_PORT}:${API_SERVER_PORT} \
    -p ${ETCD_CLIENT_PORT}:${ETCD_CLIENT_PORT} \
    -p ${ETCD_PEER_PORT}:${ETCD_PEER_PORT} \
    -p 9000:9000 \
    haproxy:latest
fi

# Copy new config into HAProxy container
echo "[INFO] Copying new config into HAProxy container..."
podman cp "$HAPROXY_PATH" haproxy:/usr/local/etc/haproxy/haproxy.cfg

# Start or reload HAProxy container
if ! podman ps --format '{{.Names}}' | grep -qw haproxy; then
  echo "[INFO] Starting HAProxy container..."
  podman start haproxy
else
  echo "[INFO] Reloading HAProxy with HUP..."
  podman kill --signal HUP haproxy
fi

# Test and reload HAProxy
podman exec haproxy haproxy -f /usr/local/etc/haproxy/haproxy.cfg -c || {
  echo "[ERROR] HAProxy configuration test failed"
  exit 1
}
podman kill --signal HUP haproxy
echo "[INFO] HAProxy reloaded with new backend entries"
# ------------------------------------------------------------------