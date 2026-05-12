#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

source ./preconfigured.sh >/dev/null

endpoint="${LOCAL_REGISTRY_ENDPOINT:-${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}}"
endpoint_provided=false
assume_yes=false
dry_run=false
restart_containerd=true

usage() {
  cat <<'EOF'
Usage:
  ./u_configure_vm_containerd_registry.sh [--endpoint HOST:PORT] [--yes] [--dry-run] [--no-restart]

Configures every active FCOS VM node's containerd to trust the local insecure registry.
It writes:
  /etc/containerd/certs.d/<HOST:PORT>/hosts.toml

and ensures:
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --endpoint)
      endpoint="${2:-}"
      endpoint_provided=true
      shift
      ;;
    --endpoint=*)
      endpoint="${1#*=}"
      endpoint_provided=true
      ;;
    --yes|-y)
      assume_yes=true
      ;;
    --dry-run)
      dry_run=true
      ;;
    --no-restart)
      restart_containerd=false
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

if [ "$endpoint_provided" = false ]; then
  host_ip="${LOCAL_REGISTRY_HOST}"
  host_ip_file="./wireguard-client-config/wireguard-vpn/${PRECONFIGURED_HOST_WIREGUARD_CLIENT_NO}/wg_ip_address.txt"
  if [ -f "$host_ip_file" ]; then
    host_ip="$(<"$host_ip_file")"
  fi
  if [ "${LOCAL_REGISTRY_ENDPOINT:-}" = "${LOCAL_REGISTRY_HOST}:${LOCAL_REGISTRY_PORT}" ]; then
    endpoint="${host_ip}:${LOCAL_REGISTRY_PORT}"
  fi
fi

if ! [[ "$endpoint" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "ERROR: invalid registry endpoint: $endpoint" >&2
  exit 1
fi

ssh_dir="./.ssh"
known_hosts_file="$ssh_dir/known_hosts"
vpn_base_dir="./wireguard-client-config/wireguard-vpn"

ssh_extra_options=()
if ssh -G -T 127.0.0.1 -o WarnWeakCrypto=no-pq-kex >/dev/null 2>&1; then
  ssh_extra_options=(-o WarnWeakCrypto=no-pq-kex)
fi

priv_keys=()
while IFS= read -r key; do
  priv_keys+=("$key")
done < <(
  find "$ssh_dir" -maxdepth 1 -type f \
    ! -name "*.pub" \
    ! -name "known_hosts" \
    | sort
)

if [ ${#priv_keys[@]} -eq 0 ]; then
  echo "ERROR: no SSH private keys found in $ssh_dir" >&2
  exit 1
fi

echo "Available SSH private keys:"
echo "  [0] Try all keys"
for i in "${!priv_keys[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${priv_keys[i]}"
done
read -r -p "Select SSH key (0-${#priv_keys[@]}, default 0): " key_choice
key_choice="${key_choice:-0}"
if ! [[ "$key_choice" =~ ^[0-9]+$ ]] || [ "$key_choice" -lt 0 ] || [ "$key_choice" -gt "${#priv_keys[@]}" ]; then
  echo "ERROR: invalid SSH key selection: $key_choice" >&2
  exit 1
fi

selected_ssh_keys=()
if [ "$key_choice" -eq 0 ]; then
  selected_ssh_keys=("${priv_keys[@]}")
else
  selected_ssh_keys=("${priv_keys[$((key_choice-1))]}")
fi

node_numbers=()
node_ips=()
node_labels=()
while IFS=$'\t' read -r number ip label; do
  node_numbers+=("$number")
  node_ips+=("$ip")
  node_labels+=("$label")
done < <(
  for dir in "$vpn_base_dir"/*; do
    [ -d "$dir" ] || continue
    [ -f "$dir/using.lock" ] || continue
    [ -f "$dir/wg_ip_address.txt" ] || continue
    label="$(<"$dir/using.lock")"
    case "$label" in
      "This wg config file will be used by host machine."|"") continue ;;
    esac
    printf "%s\t%s\t%s\n" "$(basename "$dir")" "$(<"$dir/wg_ip_address.txt")" "$label"
  done | sort
)

if [ ${#node_ips[@]} -eq 0 ]; then
  echo "ERROR: no active VM WireGuard assignments found in $vpn_base_dir" >&2
  exit 1
fi

echo
echo "Registry endpoint to trust: http://${endpoint}"
echo "Target VM nodes:"
for i in "${!node_ips[@]}"; do
  printf "  [%s] %-15s %s\n" "${node_numbers[i]}" "${node_ips[i]}" "${node_labels[i]}"
done
echo

if [ "$dry_run" = true ]; then
  echo "Dry run only; no SSH changes made."
  exit 0
fi

if [ "$assume_yes" != true ]; then
  read -r -p "Configure all listed nodes? [yes/no/1]: " answer
  case "$answer" in
    1|y|Y|yes|YES|Yes) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

failed_nodes=()
for i in "${!node_ips[@]}"; do
  ip="${node_ips[i]}"
  label="${node_labels[i]}"
  echo
  echo "== Configuring ${label} (${ip}) =="

  configured=false
  last_status=0

  for ssh_key in "${selected_ssh_keys[@]}"; do
    echo "Trying SSH key: $ssh_key"

    set +e
    ssh -i "$ssh_key" \
      -o UserKnownHostsFile="$known_hosts_file" \
      -o StrictHostKeyChecking=accept-new \
      -o BatchMode=yes \
      -o ConnectTimeout=8 \
      "${ssh_extra_options[@]}" \
      "core@$ip" \
      "REGISTRY_ENDPOINT='$endpoint' RESTART_CONTAINERD='$restart_containerd' bash -s" <<'REMOTE'
set -euo pipefail

hosts_dir="/etc/containerd/certs.d/${REGISTRY_ENDPOINT}"
sudo mkdir -p "$hosts_dir"

tmp_hosts="$(mktemp)"
cat > "$tmp_hosts" <<HOSTS
server = "http://${REGISTRY_ENDPOINT}"

[host."http://${REGISTRY_ENDPOINT}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
HOSTS
sudo install -m 0644 "$tmp_hosts" "$hosts_dir/hosts.toml"
rm -f "$tmp_hosts"

if ! sudo grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
  backup="/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp /etc/containerd/config.toml "$backup"

  if sudo grep -q '^\[plugins\."io.containerd.grpc.v1.cri"\.registry\]' /etc/containerd/config.toml; then
    tmp_config="$(mktemp)"
    sudo awk '
      BEGIN { in_registry = 0; inserted = 0 }
      /^\[plugins\."io.containerd.grpc.v1.cri"\.registry\]/ {
        in_registry = 1
        print
        next
      }
      in_registry && /^\[/ {
        if (!inserted) {
          print "  config_path = \"/etc/containerd/certs.d\""
          inserted = 1
        }
        in_registry = 0
      }
      { print }
      END {
        if (in_registry && !inserted) {
          print "  config_path = \"/etc/containerd/certs.d\""
        }
      }
    ' /etc/containerd/config.toml > "$tmp_config"
    sudo install -m 0644 "$tmp_config" /etc/containerd/config.toml
    rm -f "$tmp_config"
  else
    cat <<'CONFIG' | sudo tee -a /etc/containerd/config.toml >/dev/null

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
CONFIG
  fi

  echo "Updated /etc/containerd/config.toml (backup: $backup)"
else
  echo "containerd config_path is already set."
fi

if [ "$RESTART_CONTAINERD" = true ]; then
  sudo systemctl restart containerd
  sudo systemctl restart kubelet || true
  echo "containerd restarted."
else
  echo "Skipped containerd restart. Restart it before pulling from the registry."
fi

echo "Installed $hosts_dir/hosts.toml"
REMOTE
    last_status=$?
    set -e

    if [ "$last_status" -eq 0 ]; then
      configured=true
      break
    fi

    echo "Key failed for ${label} (${ip}) with status ${last_status}."
  done

  if [ "$configured" != true ]; then
    failed_nodes+=("${label}(${ip})")
    echo "WARNING: skipped ${label} (${ip}); all selected SSH keys failed."
  fi
done

echo
if [ ${#failed_nodes[@]} -gt 0 ]; then
  echo "Completed with failures. Registry config was not applied to:"
  for failed in "${failed_nodes[@]}"; do
    echo "  - $failed"
  done
  exit 1
fi

echo "Done. Node containerd registry config points at http://${endpoint}."
