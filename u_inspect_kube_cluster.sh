#!/usr/bin/env bash
set -euo pipefail

source ./preconfigured.sh

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required on the host machine." >&2
  exit 1
fi

ssh_dir="./.ssh"
known_hosts_file="$ssh_dir/known_hosts"
vpn_base_dir="./wireguard-client-config/wireguard-vpn"

ssh_extra_options=()
if ssh -G -T 127.0.0.1 -o WarnWeakCrypto=no-pq-kex >/dev/null 2>&1; then
  ssh_extra_options=(-o WarnWeakCrypto=no-pq-kex)
fi

shopt -s nullglob
mapfile -t priv_keys < <(
  find "$ssh_dir" -maxdepth 1 -type f \
    ! -name "*.pub" \
    ! -name "known_hosts" \
    | sort
)
shopt -u nullglob

if [ ${#priv_keys[@]} -eq 0 ]; then
  echo "ERROR: no SSH private keys found in $ssh_dir" >&2
  exit 1
fi

echo
echo "Select SSH key to connect to a control-plane VM:"
for i in "${!priv_keys[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${priv_keys[i]}"
done
read -rp "> " key_choice
if ! [[ "$key_choice" =~ ^[0-9]+$ ]] || [ "$key_choice" -lt 1 ] || [ "$key_choice" -gt "${#priv_keys[@]}" ]; then
  echo "ERROR: invalid SSH key selection: $key_choice" >&2
  exit 1
fi
ssh_key="${priv_keys[$((key_choice-1))]}"

shopt -s nullglob
ips=()
dirs=()
labels=()
for dir in "$vpn_base_dir"/*; do
  if [[ -f "$dir/using.lock" && -f "$dir/wg_ip_address.txt" ]]; then
    ips+=("$(<"$dir/wg_ip_address.txt")")
    dirs+=("$(basename "$dir")")
    labels+=("$(<"$dir/using.lock")")
  fi
done
shopt -u nullglob

if [ ${#ips[@]} -eq 0 ]; then
  echo "ERROR: no active WireGuard VPN configs found in $vpn_base_dir" >&2
  exit 1
fi

echo
echo "Select control-plane WireGuard IP:"
for i in "${!ips[@]}"; do
  printf "  [%d] %s (%s, %s)\n" "$((i+1))" "${ips[i]}" "${dirs[i]}" "${labels[i]}"
done
read -rp "> " vpn_choice
if ! [[ "$vpn_choice" =~ ^[0-9]+$ ]] || [ "$vpn_choice" -lt 1 ] || [ "$vpn_choice" -gt "${#ips[@]}" ]; then
  echo "ERROR: invalid WireGuard IP selection: $vpn_choice" >&2
  exit 1
fi
vm_ip="${ips[$((vpn_choice-1))]}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

ssh_base=(
  ssh
  -i "$ssh_key"
  -o UserKnownHostsFile="$known_hosts_file"
  -o StrictHostKeyChecking=accept-new
  "${ssh_extra_options[@]}"
  "core@$vm_ip"
)

echo
echo "Preparing temporary kubeconfig from $vm_ip..."
kubeconfig_tmp="$tmp_dir/kubeconfig"
"${ssh_base[@]}" 'sudo cat /etc/kubernetes/admin.conf' > "$kubeconfig_tmp"

cluster_name="$(KUBECONFIG="$kubeconfig_tmp" kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
KUBECONFIG="$kubeconfig_tmp" kubectl config set-cluster "$cluster_name" \
  --server="https://${CLUSTER_LOAD_BALANCER_END_POINT}:${API_SERVER_PORT}" \
  >/dev/null

run_kubectl() {
  echo
  echo "== kubectl $* =="
  KUBECONFIG="$kubeconfig_tmp" kubectl "$@"
}

if [ "$#" -gt 0 ]; then
  run_kubectl "$@"
  exit 0
fi

echo
echo "Cluster endpoint: https://${CLUSTER_LOAD_BALANCER_END_POINT}:${API_SERVER_PORT}"

run_kubectl cluster-info
run_kubectl get nodes -o wide
run_kubectl get pods -A -o wide
run_kubectl get svc -A -o wide
run_kubectl get deployments,daemonsets,statefulsets -A
run_kubectl -n kube-system get pods -o wide

echo
echo "== recent cluster events =="
KUBECONFIG="$kubeconfig_tmp" kubectl get events -A --sort-by=.lastTimestamp | tail -n 30

echo
echo "== active WireGuard assignments =="
for i in "${!ips[@]}"; do
  printf "%s\t%s\t%s\n" "${ips[i]}" "${dirs[i]}" "${labels[i]}"
done
