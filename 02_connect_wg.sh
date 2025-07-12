#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="./wireguard-client-config/wireguard-vpn/002/wg0.conf"
PEER_IP="10.10.117.1"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  exit 1
fi

echo "Bringing down any existing interface from $CONFIG_FILE"
sudo wg-quick down "$CONFIG_FILE" >/dev/null 2>&1 || true

echo "Bringing up WireGuard interface"
sudo wg-quick up "$CONFIG_FILE"

echo "Waiting for handshake"
for i in {1..15}; do
  if sudo wg show | grep -q 'latest handshake'; then
    echo "Handshake OK"
    break
  fi
  echo "  ... retrying handshake check ($i/15)"
  sleep 1
done

echo "Testing connectivity to peer $PEER_IP"
if ping -c3 "$PEER_IP" >/dev/null; then
  echo "✔️  Ping $PEER_IP succeeded"
else
  echo "❌  Ping $PEER_IP failed" >&2
  exit 2
fi

echo "Done."