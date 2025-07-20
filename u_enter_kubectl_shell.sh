#!/usr/bin/env bash
# Launches a new shell (bash or zsh) with a temporary kubeconfig for kubectl.
set -euo pipefail

# Determine target shell (bash default)
target_shell="${1:-zsh}"
if ! command -v "$target_shell" &>/dev/null; then
  echo "❌ '$target_shell' shell not found. Only bash or zsh supported."
  exit 1
fi

# 1) Load preconfigured variables
source ./preconfigured.sh  # defines CLUSTER_LOAD_BALANCER_END_POINT, API_SERVER_PORT

# 2) SSH key selection
ssh_dir="./.ssh"
known_hosts_file="$ssh_dir/known_hosts"
shopt -s nullglob
mapfile -t priv_keys < <(
  find "$ssh_dir" -maxdepth 1 -type f ! -name "*.pub" ! -name "known_hosts" | sort
)
shopt -u nullglob
if [ ${#priv_keys[@]} -eq 0 ]; then
  echo "❌ No SSH private keys found in $ssh_dir"
  exit 1
fi

echo
printf "Select SSH key to connect to master VM:\n"
for i in "${!priv_keys[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${priv_keys[i]}"
done
read -rp "> " key_choice
ssh_key="${priv_keys[$((key_choice-1))]}"
echo "▶ Using SSH key: $ssh_key"

# 3) WireGuard VPN IP selection
vpn_base_dir="./wireguard-client-config/wireguard-vpn"
shopt -s nullglob
ips=(); dirs=()
for dir in "$vpn_base_dir"/*; do
  if [[ -f "$dir/using.lock" && -f "$dir/wg_ip_address.txt" ]]; then
    ips+=("$(<"$dir/wg_ip_address.txt")")
    dirs+=("$(basename "$dir")")
  fi
done
shopt -u nullglob
if [ ${#ips[@]} -eq 0 ]; then
  echo "❌ No active WireGuard VPN configs"
  exit 1
fi

echo
printf "Select WireGuard VPN IP:\n"
for i in "${!ips[@]}"; do
  printf "  [%d] %s (%s)\n" "$((i+1))" "${ips[i]}" "${dirs[i]}"
done
read -rp "> " vpn_choice
vm_ip="${ips[$((vpn_choice-1))]}"
echo "▶ Master VM IP: $vm_ip"

# 4) Generate or retrieve ServiceAccount token for kubectl
echo
printf "Ensuring cli-user ServiceAccount and binding...\n"
ssh -i "$ssh_key" -o UserKnownHostsFile="$known_hosts_file" core@"$vm_ip" bash -<<'EOF'
set -e
kubectl get sa cli-user -n kube-system >/dev/null 2>&1 || kubectl create sa cli-user -n kube-system
kubectl get clusterrolebinding cli-user-binding >/dev/null 2>&1 || kubectl create clusterrolebinding cli-user-binding --clusterrole=cluster-admin --serviceaccount=kube-system:cli-user
kubectl create token cli-user -n kube-system --duration=1h
EOF
KUBE_TOKEN=$(ssh -i "$ssh_key" -o UserKnownHostsFile="$known_hosts_file" core@"$vm_ip" 'kubectl create token cli-user -n kube-system --duration=1h')
echo "▶ ServiceAccount token: $KUBE_TOKEN"

# 5) Fetch admin.conf via sudo and extract CA
echo
printf "Copying admin.conf and extracting CA cert...\n"
TMPDIR=$(mktemp -d)
ssh -i "$ssh_key" -o UserKnownHostsFile="$known_hosts_file" \
  core@"$vm_ip" "sudo cp /etc/kubernetes/admin.conf /home/core/admin.conf && sudo chown core:core /home/core/admin.conf"
scp -i "$ssh_key" -o UserKnownHostsFile="$known_hosts_file" \
  core@"$vm_ip":/home/core/admin.conf "$TMPDIR/admin.conf"
grep 'certificate-authority-data:' "$TMPDIR/admin.conf" | awk '{print $2}' | base64 --decode > "$TMPDIR/ca.crt"
echo "▶ CA cert at $TMPDIR/ca.crt"

# 6) Create temporary kubeconfig
KUBE_SERVER="https://${CLUSTER_LOAD_BALANCER_END_POINT}:${API_SERVER_PORT}"
KUBE_CA="$TMPDIR/ca.crt"
KUBECONFIG_TMP="$TMPDIR/kubeconfig"
cat > "$KUBECONFIG_TMP" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: tmp
  cluster:
    server: $KUBE_SERVER
    certificate-authority: $KUBE_CA
users:
- name: tmp-user
  user:
    token: $KUBE_TOKEN
contexts:
- name: tmp-ctx
  context:
    cluster: tmp
    user: tmp-user
current-context: tmp-ctx
EOF

echo "▶ Temporary kubeconfig at $KUBECONFIG_TMP"

# 7) Launch new shell with KUBECONFIG
echo
printf "✅ Starting new $target_shell with Kubernetes env. Type 'exit' to return.\n"
exec env KUBECONFIG="$KUBECONFIG_TMP" $target_shell --login
