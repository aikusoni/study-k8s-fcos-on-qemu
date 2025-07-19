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
    bind *:${CLUSTER_PORT}
    default_backend k8s_masters

############################################
# backend pool of master nodes (auto from main-addresses.txt)
############################################
backend k8s_masters
    balance     roundrobin
    option      tcp-check
    tcp-check   connect port ${CLUSTER_PORT}
EOF

# append each master address if main-addresses.txt exists
if [ -f "$MAIN_ADDRESSES_FILE" ]; then
  idx=0
  while read -r ip; do
    echo "    server master${idx} ${ip}:${CLUSTER_PORT} check inter 5s fall 2 rise 3" >> "$HAPROXY_PATH"
    idx=$((idx + 1))
  done < "$MAIN_ADDRESSES_FILE"
else
  echo "[INFO] "$MAIN_ADDRESSES_FILE" not found, skipping backend entries"
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

# Ensure HAProxy container exists
if ! podman ps -a --format '{{.Names}}' | grep -qw haproxy; then
  echo "[INFO] Creating HAProxy container (paused)..."
  podman create \
    --name haproxy \
    -p ${CLUSTER_PORT}:${CLUSTER_PORT} \
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