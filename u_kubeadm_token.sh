#!/usr/bin/env bash
set -euo pipefail

output_file="${1:-}"

tmpf="$(mktemp)"
trap 'rm -f "$tmpf"' EXIT

./u_kubeadm_join_command.sh "$tmpf"

join_cmd="$(<"$tmpf")"

token="$(printf '%s\n' "$join_cmd" \
  | awk '{for(i=1;i<NF;i++) if($i=="--token") print $(i+1)}')"

if [[ -z "$token" ]]; then
  echo "❌ 토큰을 찾을 수 없습니다." >&2
  exit 1
fi

# 출력
if [ -n "$output_file" ]; then
  echo "$token" > "$output_file"
else
  echo "$token"
fi