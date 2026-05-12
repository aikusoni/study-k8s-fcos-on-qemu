#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

source ./preconfigured.sh >/dev/null

version="${LOCAL_PATH_PROVISIONER_VERSION:-v0.0.27}"
storage_class="${LOCAL_STORAGE_CLASS:-local-path}"
manifest_url="${LOCAL_PATH_PROVISIONER_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/${version}/deploy/local-path-storage.yaml}"
wait_timeout="${LOCAL_PATH_PROVISIONER_WAIT_TIMEOUT:-180s}"

usage() {
  cat <<EOF
Usage:
  ./u_install_local_path_storage.sh

Installs Rancher local-path-provisioner and marks ${storage_class} as the default StorageClass.

Run this inside the shell opened by ./u_enter_kubectl_shell.sh, or any shell where kubectl
can reach this FCOS kubeadm cluster.

Environment overrides:
  LOCAL_PATH_PROVISIONER_VERSION=${version}
  LOCAL_PATH_PROVISIONER_URL=${manifest_url}
  LOCAL_STORAGE_CLASS=${storage_class}
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required." >&2
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach the cluster." >&2
  echo "Run ./u_enter_kubectl_shell.sh first, then run this script inside that shell." >&2
  exit 1
fi

echo "Installing local-path-provisioner from:"
echo "  $manifest_url"
kubectl apply -f "$manifest_url"

echo
echo "Waiting for local-path-provisioner rollout..."
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout="$wait_timeout"

echo
echo "Marking ${storage_class} as the default StorageClass..."
kubectl patch storageclass "$storage_class" -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo
echo "StorageClass status:"
kubectl get storageclass
