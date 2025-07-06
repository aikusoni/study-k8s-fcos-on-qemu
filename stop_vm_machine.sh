#!/usr/bin/env bash
set -euo pipefail

# stop_vm_manager.sh
# ./machines 디렉토리에서 VM 이름을 리스트업하고,
# 선택한 VM을 qemu 프로세스를 찾아 종료합니다.

# 1) VM 디렉토리 목록
mapfile -t vm_dirs < <(find ./machines -maxdepth 1 -mindepth 1 -type d | sort)
if [ ${#vm_dirs[@]} -eq 0 ]; then
  echo "❌ ./machines 디렉토리에 VM이 없습니다."
  exit 1
fi

echo "Available VMs:"
for i in "${!vm_dirs[@]}"; do
  idx=$((i+1))
  name=$(basename "${vm_dirs[i]}")
  printf "  [%d] %s\n" "$idx" "$name"
done

# 2) 사용자 선택
read -rp "Select a VM to stop (1-${#vm_dirs[@]}): " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#vm_dirs[@]}" ]; then
  echo "❌ Invalid selection: $choice"
  exit 1
fi
vm_name=$(basename "${vm_dirs[$((choice-1))]}")

echo "▶ Stopping VM: $vm_name"

# 3) QEMU 프로세스 찾기
pids=$(pgrep -f "qemu-system.*-name $vm_name" || true)
if [ -z "$pids" ]; then
  echo "ℹ️ VM '$vm_name' is not running or process not found."
  exit 0
fi

echo "Found QEMU PIDs: $pids"

# 4) 종료 확인
read -rp "Do you want to kill these processes? (yes/no): " confirm
case "$confirm" in
  [Yy]|[Yy][Ee][Ss])
    # 5) 프로세스 종료
    kill $pids
    sleep 1
    echo "✅ VM '$vm_name' stopped."
    ;;
  *)
    echo "❌ Aborted by user."
    exit 1
    ;;
esac