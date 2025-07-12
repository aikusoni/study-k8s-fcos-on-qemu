#!/bin/bash

set -euo pipefail

if ! command -v podman &>/dev/null; then
  echo "Podman is required. Please install Podman and try again."
  exit 1
fi

if ! command -v wg &>/dev/null; then
  echo "WireGuard Tools is required. Please install WireGuard Tools and try again."
  exit 1
fi

source ./preconfigured.sh

machine_name="${PODMAN_MACHINE_NAME}"

# Podman machine 목록에서 <machine_name>:true 형태로 Running 여부를 확인
# 만약 해당 machine이 없거나 실행 중이 아니면 초기화 & 시작
if ! podman machine list --format '{{.Name}}:{{.Running}}' \
   | grep "^${machine_name}" \
   | grep "true$"; then
  echo "Podman Vm is not running. Trying to start..."

  # machine 존재 여부 확인
  if ! podman machine list --format '{{.Name}}' | grep "${machine_name}"; then
    echo "Podman VM(${machine_name}) does not exist. Initializing..."
    podman machine init "${machine_name}"
  fi

  # machine 시작
  podman machine start "${machine_name}"
fi