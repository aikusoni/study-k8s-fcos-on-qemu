#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

source ./preconfigured.sh >/dev/null

recreate=false
print_endpoint=false

usage() {
  cat <<'EOF'
Usage:
  ./u_run_local_registry.sh [--recreate] [--print-endpoint]

Starts a local insecure registry for FCOS VM nodes.

Environment overrides:
  LOCAL_REGISTRY_HOST       Node-visible host IP. Default: LOCAL_REGISTRY_HOST from preconfigured.sh
  LOCAL_REGISTRY_BIND_HOST  Host bind IP for podman/docker -p. Default: LOCAL_REGISTRY_HOST
  LOCAL_REGISTRY_PORT       Host/container registry port. Default: 5000
  LOCAL_REGISTRY_NAME       Container name. Default: fcos-local-registry
  LOCAL_REGISTRY_STORAGE    volume or bind. Default: volume
  LOCAL_REGISTRY_VOLUME     Named volume when storage=volume. Default: fcos-local-registry-data
  LOCAL_REGISTRY_DATA_DIR   Registry data dir when storage=bind. Default: .registry-data
  CONTAINER_CLI             podman or docker. Default: podman if found, else docker
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --recreate)
      recreate=true
      ;;
    --print-endpoint)
      print_endpoint=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "${CONTAINER_CLI:-}" ]; then
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI=podman
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_CLI=docker
  else
    echo "ERROR: podman or docker is required." >&2
    exit 1
  fi
fi

host_ip="${LOCAL_REGISTRY_HOST}"
host_ip_file="./wireguard-client-config/wireguard-vpn/${PRECONFIGURED_HOST_WIREGUARD_CLIENT_NO}/wg_ip_address.txt"
if [ -f "$host_ip_file" ]; then
  host_ip="$(<"$host_ip_file")"
fi

bind_host="${LOCAL_REGISTRY_BIND_HOST:-$host_ip}"
port="${LOCAL_REGISTRY_PORT:-5000}"
name="${LOCAL_REGISTRY_NAME:-fcos-local-registry}"
image="${LOCAL_REGISTRY_IMAGE:-docker.io/library/registry:2.8}"
storage="${LOCAL_REGISTRY_STORAGE:-volume}"
volume_name="${LOCAL_REGISTRY_VOLUME:-${name}-data}"
data_dir="${LOCAL_REGISTRY_DATA_DIR:-.registry-data}"
endpoint="${LOCAL_REGISTRY_ENDPOINT:-${host_ip}:${port}}"
if [ "${LOCAL_REGISTRY_ENDPOINT:-}" = "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}" ]; then
  endpoint="${host_ip}:${port}"
fi

if [ "$print_endpoint" = true ]; then
  echo "$endpoint"
  exit 0
fi

echo "Local registry endpoint: $endpoint"
echo "Container runtime:       $CONTAINER_CLI"
echo "Container name:          $name"
echo "Bind address:            ${bind_host}:${port}"
echo "Storage mode:            $storage"
if [ "$storage" = "volume" ]; then
  echo "Registry volume:         $volume_name"
elif [ "$storage" = "bind" ]; then
  echo "Data directory:          $data_dir"
else
  echo "ERROR: LOCAL_REGISTRY_STORAGE must be 'volume' or 'bind'." >&2
  exit 1
fi
echo

volume_mount=""
if [ "$storage" = "volume" ]; then
  if ! "$CONTAINER_CLI" volume inspect "$volume_name" >/dev/null 2>&1; then
    "$CONTAINER_CLI" volume create "$volume_name" >/dev/null
  fi
  volume_mount="${volume_name}:/var/lib/registry"
else
  mkdir -p "$data_dir"
  data_abs="$(cd "$data_dir" && pwd -P)"
  if [ ! -d "$data_abs" ]; then
    echo "ERROR: registry data directory does not exist: $data_abs" >&2
    exit 1
  fi
  volume_mount="${data_abs}:/var/lib/registry"
fi

container_exists=false
if "$CONTAINER_CLI" container inspect "$name" >/dev/null 2>&1; then
  container_exists=true
fi

if [ "$container_exists" = true ] && [ "$recreate" = true ]; then
  echo "Recreating existing registry container: $name"
  "$CONTAINER_CLI" rm -f "$name" >/dev/null
  container_exists=false
fi

if [ "$container_exists" = true ]; then
  published="$("$CONTAINER_CLI" port "$name" 5000/tcp 2>/dev/null || true)"
  if [ -n "$published" ]; then
    echo "Existing port binding: $published"
  fi

  if [ -z "$published" ]; then
    echo "ERROR: existing container has no 5000/tcp port binding." >&2
    echo "Run ./u_run_local_registry.sh --recreate to rebuild it with ${bind_host}:${port}." >&2
    exit 1
  fi

  if ! printf '%s\n' "$published" | grep -Eq "(^|[[:space:]])(${bind_host}|\*|0\.0\.0\.0):${port}$"; then
    echo "ERROR: existing container has a different port binding." >&2
    echo "Run ./u_run_local_registry.sh --recreate to rebuild it with ${bind_host}:${port}." >&2
    exit 1
  fi

  status="$("$CONTAINER_CLI" container inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
  if [ "$status" != "running" ]; then
    echo "Starting existing registry container..."
    "$CONTAINER_CLI" start "$name" >/dev/null
  else
    echo "Registry container is already running."
  fi
else
  echo "Creating registry container..."
  "$CONTAINER_CLI" run -d \
    --name "$name" \
    -p "${bind_host}:${port}:5000" \
    -v "$volume_mount" \
    --restart=always \
    "$image" >/dev/null
fi

echo
if command -v curl >/dev/null 2>&1; then
  echo "Checking registry catalog..."
  if curl -fsS "http://${endpoint}/v2/_catalog"; then
    echo
    echo "Registry is reachable: http://${endpoint}"
  else
    echo "WARNING: registry container is running, but http://${endpoint}/v2/_catalog did not respond." >&2
    echo "Check WireGuard host IP and Podman/Docker port publishing." >&2
  fi
else
  echo "curl is not installed; skipping catalog check."
fi
