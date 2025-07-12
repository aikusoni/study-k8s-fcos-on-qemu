#!/bin/bash
set -euo pipefail

source ./preconfigured.sh

mkdir -p "$lb_dir"

# 기존 컨테이너가 있으면 삭제
# 이전 HAProxy 컨테이너 제거
podman rm -f haproxy 2>/dev/null || true

./UT_renew_loadbalancer.sh