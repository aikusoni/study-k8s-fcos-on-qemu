#!/usr/bin/env bash
set -euo pipefail

source ./preconfigured.sh

# Paths
declare -r CONFIG_FILE="./loadbalancing/control-plane.txt"
declare -r OUTPUT_DIR="./loadbalancing"
declare -r HAPROXY_CFG="$OUTPUT_DIR/haproxy.cfg"

# Podman container settings
declare -r CONTAINER_NAME="k8s-haproxy"
declare -r IMAGE="haproxy:2.8"
declare -r BIND_ADDR="127.0.0.1"
declare -r PORT="6443"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# No IPs? nothing to do
if [[ ! -s "$CONFIG_FILE" ]]; then
  echo "[INFO] No control-plane IPs found in $CONFIG_FILE, skipping load balancer setup."
  exit 0
fi

# Generate haproxy.cfg
cat > "$HAPROXY_CFG" <<EOF
global
    daemon
    maxconn 4096

defaults
    mode tcp
    log global
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend k8s_api
    bind *:$PORT
    default_backend k8s_masters

backend k8s_masters
    balance roundrobin
    option tcp-check
EOF

# Append servers from control-plane.txt
index=1
while IFS= read -r ip; do
  # Skip empty or commented lines
  [[ -z "$ip" || "$ip" =~ ^# ]] && continue
  echo "    server master$index $ip:$PORT check" >> "$HAPROXY_CFG"
  index=$((index + 1))
done < "$CONFIG_FILE"

# Remove existing container if present
if podman container exists "$CONTAINER_NAME"; then
  echo "[INFO] Removing existing container $CONTAINER_NAME"
  podman rm -f "$CONTAINER_NAME"
fi

# Run new HAProxy container
podman run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  -p "$BIND_ADDR:$PORT:$PORT/tcp" \
  -v "$(realpath "$HAPROXY_CFG")":/usr/local/etc/haproxy/haproxy.cfg:ro \
  "$IMAGE"

echo "[INFO] HAProxy load balancer '$CONTAINER_NAME' started, listening on $BIND_ADDR:$PORT"