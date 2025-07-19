#!/usr/bin/env bash
set -euo pipefail

output_file="${1:-}"

tmpf="$(mktemp)"
trap 'rm -f "$tmpf"' EXIT

./u_kubeadm_join_command.sh "$tmpf"

join_cmd="$(<"$tmpf")"

hash="$(printf '%s\n' "$join_cmd" \
  | awk '{for(i=1;i<NF;i++) if($i=="--discovery-token-ca-cert-hash") print $(i+1)}')"

if [[ -z "$hash" ]]; then
  echo "❌ 해시를 찾을 수 없습니다." >&2
  exit 1
fi

# 출력
if [ -n "$output_file" ]; then
  echo "$hash" > "$output_file"
else
  echo "$hash"
fi