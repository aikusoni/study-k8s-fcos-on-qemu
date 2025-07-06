#!/usr/bin/env bash
set -euo pipefail

# start_vm_manager.sh
# 현재 경로의 ./machines/*/start_vm.sh 스크립트를 찾아서 리스트업하고,
# 사용자가 선택한 VM의 start_vm.sh를 실행합니다.

# 스크립트 배열 검색
mapfile -t scripts < <(find ./machines -maxdepth 2 -type f -name start_vm.sh | sort)

if [ ${#scripts[@]} -eq 0 ]; then
  echo "❌ ./machines/*/start_vm.sh 스크립트를 찾을 수 없습니다."
  exit 1
fi

# 목록 출력
echo "Available VM start scripts:"
for i in "${!scripts[@]}"; do
  idx=$((i+1))
  printf "  [%d] %s\n" "$idx" "${scripts[i]}"
done

# 사용자 선택
read -rp "Select a VM to start (1-${#scripts[@]}): " choice

# 유효성 검사
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#scripts[@]}" ]; then
  echo "❌ Invalid selection: $choice"
  exit 1
fi

# 선택된 스크립트 실행
selected_script="${scripts[$((choice-1))]}"
echo "▶ Running $selected_script"
# 실행 권한 확인
if [ ! -x "$selected_script" ]; then
  echo "⚠️ Making script executable: $selected_script"
  chmod +x "$selected_script"
fi

# VM 실행
bash "$selected_script"
