#!/bin/bash

# 필요한 도구 확인
command -v qemu-img >/dev/null 2>&1 || { echo >&2 "qemu-img가 필요합니다. 설치 후 다시 시도하세요."; exit 1; }

image_dir="./images"
temp_dir="./temp"

# 현재 디렉토리에서 사용 가능한 qcow2 이미지 선택
qcow2_files=($image_dir/fedora-coreos*.qcow2)
if [ ${#qcow2_files[@]} -eq 0 ]; then
    echo "Error: $image_dir 디렉토리에 'fedora-coreos*.qcow2' 파일이 없습니다."
    echo "https://fedoraproject.org/coreos/download?stream=stable#download_section 에서 다운로드 후 다시 시도하세요."
    exit 1
elif [ ${#qcow2_files[@]} -eq 1 ]; then
    qcow2_image="${qcow2_files[0]}"
    echo "선택된 qcow2 이미지: $qcow2_image"
else
    echo "사용 가능한 qcow2 이미지 목록:"
    select file in "${qcow2_files[@]}"; do
        if [ -n "$file" ]; then
            qcow2_image="$file"
            echo "선택된 qcow2 이미지: $qcow2_image"
            break
        else
            echo "유효하지 않은 선택입니다. 다시 시도하세요."
        fi
    done
fi

# 새로운 VM 이름 입력
read -p "Input your new virtual machine name: " vm_name

# VM 모드 입력 및 Ignition URL 설정
echo "사용가능한 모드: "
select vm_mode in "kube_main" "kube_worker"; do
  case "$vm_mode" in
    kube_main)
      ignition_url="http://localhost:8000/ignition_main.json"
      memory_size="4096"
      num_cpus="4"
      break
      ;;
    kube_worker)
      ignition_url="http://localhost:8000/ignition_worker.json"
      memory_size="2048"
      num_cpus="2"
      break
      ;;
    *)
      echo "오류: 지원되지 않는 선택입니다. 다시 시도하세요."
      ;;
  esac
done

mkdir -p "$temp_dir/$vm_name"

ignition_path="$temp_dir/$vm_name/ignition.json"
curl "$ignition_url" -o "$ignition_path"
if [ $? -eq 0 ]; then
    echo "파일 다운로드 성공!"
    cat "$ignition_path"
else
    echo "파일 다운로드 실패! ./ignition-server/ignition.sh를 실행해서 서버를 켜세요."
    exit 1
fi

# QEMU SSH 포트 포워딩 정보 입력
read -p "Input your QEMU SSH port forwarding (host:guest): " ssh_port
µ
# 디렉토리 설정
vm_dir="./machines/$vm_name"
mkdir -p "$vm_dir"

new_image="$vm_dir/fcos-vm.qcow2"
qemu_base="/opt/homebrew/Cellar/qemu"
qemu_version=$(ls "$qemu_base" | sort -V | tail -n 1)

echo "원본 qcow2 이미지: $qcow2_image"
echo "Ignition 파일: $ignition_path"
echo "새로운 VM 디렉토리: $vm_dir"
echo "새로운 VM 이미지: $new_image"
echo "QEMU 버전: $qemu_version" 

# qcow2 이미지를 복사해서 새로운 VM 디렉토리로 이동
qemu-img create -f qcow2 -F qcow2 -b "$(realpath $qcow2_image)" "$new_image"

echo "새로운 VM 이미지 생성 완료: $new_image"

/bin/dd if=/dev/zero conv=sync bs=1m count=64 of=$vm_dir/pflash.img

# QEMU 실행
echo "QEMU 실행시 vmnet-shared 네트워크를 사용하기 때문에 sudo 권한이 필요합니다."
sudo -v

echo "QEMU 실행 중..."
nohup sudo qemu-system-aarch64 \
    -cpu host \
    -smp $num_cpus \
    -m $memory_size \
    -accel hvf \
    -accel tcg \
    -device virtio-serial \
    -drive file=/opt/homebrew/Cellar/qemu/$qemu_version/share/qemu/edk2-aarch64-code.fd,if=pflash,format=raw,readonly=on \
    -drive file=$vm_dir/pflash.img,if=pflash,format=raw \
    -drive "if=virtio,file=$(realpath $new_image)" \
    -fw_cfg name=opt/com.coreos/config,file=$(realpath $ignition_path) \
    -machine virt,highmem=on \
    -vga std \
    -serial vc \
    -monitor none \
    -parallel none \
    -netdev vmnet-shared,id=kubenet -device virtio-net,netdev=kubenet \
    -name "$vm_name" > /dev/null 2> ./temp/vmerror.out &