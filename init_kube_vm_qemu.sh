#!/bin/bash

# This script initializes a new virtual machine with Fedora CoreOS using QEMU.
# The script will download the ignition template file from the server (./ignition-server/ignition.sh).

# 필요한 도구 확인
command -v qemu-img >/dev/null 2>&1 || { echo >&2 "qemu-img is required. Please install qemu-img and try again."; exit 1; }

source ./preconfigured.sh

image_dir="./images"
temp_dir="./temp"

# 현재 디렉토리에서 사용 가능한 qcow2 이미지 선택
qcow2_files=($image_dir/fedora-coreos*.qcow2)
if [ ${#qcow2_files[@]} -eq 0 ]; then
    echo "Error: No 'fedora-coreos*.qcow2' files in $image_dir directory."
    echo "Please download from https://fedoraproject.org/coreos/download?stream=stable#download_section and try again."
    exit 1
elif [ ${#qcow2_files[@]} -eq 1 ]; then
    qcow2_image="${qcow2_files[0]}"
    echo "Selected qcow2 image: $qcow2_image"
else
    echo "List of available qcow2 images:"
    select file in "${qcow2_files[@]}"; do
        if [ -n "$file" ]; then
            qcow2_image="$file"
            echo "Selected qcow2 image: $qcow2_image"
            break
        else
            echo "Error: Invalid selection. Please try again."
        fi
    done
fi

# 새로운 VM 이름 입력
read -p "Input your new virtual machine name: " vm_name

# VM 모드 입력 및 Ignition URL 설정
echo "Available modes: "
select vm_mode in "kube_main" "kube_worker"; do
  case "$vm_mode" in
    kube_main)
      ignition_url="http://localhost:8000/k8s_main_ignition_template.yml"
      memory_size="4096"
      num_cpus="4"
      break
      ;;
    kube_worker)
      ignition_url="http://localhost:8000/k8s_worker_ingition_template.yml"
      memory_size="2048"
      num_cpus="2"
      break
      ;;
    *)
      echo "Error: Invalid selection. Please try again."
      ;;
  esac
done

mkdir -p "$temp_dir/$vm_name"

ignition_template_path="$temp_dir/$vm_name/ignition_template.bu"
curl "$ignition_url" -o "$ignition_template_path"
if [ $? -eq 0 ]; then
    echo "Downloaded ignition template file successfully!"
    cat "$ignition_template_path"
else
    echo "Failed to download file! Please run ./ignition-server/ignition.sh to start the server."
    exit 1
fi

read -p "Input your wireguard client no (3-254): " wireguard_client_no
pad_wireguard_client_no=$(printf "%03d" $wireguard_client_no)

echo "Selected wireguard client no: $pad_wireguard_client_no"

SOURCE_WG_FILE=./wireguard-client-config/wireguard-vpn/${pad_wireguard_client_no}/wg0.conf
USING_WG_MARK_FILE=./wireguard-client-config/wireguard-vpn/${pad_wireguard_client_no}/using.lock

if [ ! -f $SOURCE_WG_FILE ]; then
    echo "Error: Wireguard configuration file not found: $SOURCE_WG_FILE"
    exit 1
fi

if [ -f $USING_WG_MARK_FILE ]; then
    echo "Error: Wireguard configuration file is already in use: $SOURCE_WG_FILE by $(cat $USING_WG_MARK_FILE)"
    exit 1
fi

echo "$vm_name" > $USING_WG_MARK_FILE

DEST_WG_FILE="$temp_dir/$vm_name/wg0.conf"
HOST_IP=$PRECONFIGURED_VM_IP_START
sed "s|localhost|${HOST_IP}|g" $SOURCE_WG_FILE > $DEST_WG_FILE

ignition_bu_path="$temp_dir/$vm_name/ignition.bu"
export ENCODED_WG0_CONF_CONTENT=$(base64 -i "$DEST_WG_FILE" | tr -d '\n')
envsubst < $ignition_template_path > $ignition_bu_path

ignition_path="$temp_dir/$vm_name/ignition.ign"
butane --pretty < "$ignition_bu_path" > "$ignition_path"

# 디렉토리 설정
vm_dir="./machines/$vm_name"
mkdir -p "$vm_dir"

new_image="$vm_dir/fcos-vm.qcow2"
qemu_base="/opt/homebrew/Cellar/qemu"
qemu_version=$(ls "$qemu_base" | sort -V | tail -n 1)

echo "Original qcow2 image: $qcow2_image"
echo "Ignition file: $ignition_path"
echo "New VM directory: $vm_dir"
echo "New VM image: $new_image"
echo "QEMU version: $qemu_version"

# qcow2 이미지를 복사해서 새로운 VM 디렉토리로 이동
qemu-img create -f qcow2 -F qcow2 -b "$(realpath $qcow2_image)" "$new_image"

echo "New VM image created: $new_image"

/bin/dd if=/dev/zero conv=sync bs=1m count=64 of=$vm_dir/pflash.img

# QEMU 실행
echo "Next job needs sudo permission to run QEMU with vmnet-shared network."
sudo -v

mac_last_byte=$(printf "%02x" $wireguard_client_no)
echo "Running QEMU..."
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
    -netdev vmnet-shared,id=kubenet,start-address=$PRECONFIGURED_VM_IP_START,end-address=$PRECONFIGURED_VM_IP_END,subnet-mask=$PRECONFIGURED_VM_IP_SUBNET \
    -device virtio-net,netdev=kubenet,mac=52:54:00:12:34:${mac_last_byte} \
    -name "$vm_name" > /dev/null 2> ./temp/vmerror.out &