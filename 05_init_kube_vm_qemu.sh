#!/bin/bash

set -euo pipefail

# This script initializes a new virtual machine with Fedora CoreOS using QEMU.
# The script will download the ignition template file from the server (./ignition.sh).

# 필요한 도구 확인
command -v qemu-img >/dev/null 2>&1 || { echo >&2 "qemu-img is required. Please install qemu-img and try again."; exit 1; }

source ./preconfigured.sh

image_dir="./images"
temp_dir="./temp"
ssh_dir="./.ssh"

# 새로운 VM 이름 입력
read -p "Input your virtual machine name: " vm_name
vm_dir="./machines/$vm_name"

if [ -d "$vm_dir" ]; then
    echo "VM directory already exists: $vm_dir"
    echo "Run the script in $vm_dir/start_vm.sh to start the VM."
    exit 1
fi

echo "Start to initialize a new VM : $vm_name"

# 현재 디렉토리에서 사용 가능한 qcow2 이미지 선택
if ! compgen -G "$image_dir/fedora-coreos*.qcow2" >/dev/null; then
    echo "Error: No 'fedora-coreos*.qcow2' files in $image_dir directory."
    echo "Please download from https://fedoraproject.org/coreos/download?stream=stable#download_section and try again."
    exit 1
fi

qcow2_files=($image_dir/fedora-coreos*.qcow2)
if [ ${#qcow2_files[@]} -eq 1 ]; then
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

if [ ! -f "$KUBEADM_CERT_KEY_PATH" ]; then
    export INIT_CERT_KEY=$(openssl rand -hex 32)
    mkdir -p "$(dirname "$KUBEADM_CERT_KEY_PATH")"
    echo "$INIT_CERT_KEY" > "$KUBEADM_CERT_KEY_PATH"
else
    export INIT_CERT_KEY=$(cat "$KUBEADM_CERT_KEY_PATH")
fi

echo "Using INIT_CERT_KEY: $INIT_CERT_KEY"  

# VM 모드 입력 및 Ignition URL 설정
echo "Available modes: "
select vm_mode in "kube_first_main" "kube_other_main" "kube_worker"; do
  case "$vm_mode" in
    kube_first_main)
        ignition_url="http://localhost:8000/k8s_ignition_first_main.yml"
        memory_size="4096"
        num_cpus="4"

        break
        ;;
    kube_other_main)
        ignition_url="http://localhost:8000/k8s_ignition_other_main.yml"
        memory_size="4096"
        num_cpus="4"

        token_tmpfs="$(mktemp)"
        ./u_kubeadm_token.sh "$token_tmpfs"
        if [ ! -s "$token_tmpfs" ]; then
            echo "❌ Error: failed to generate kubeadm token" >&2
            exit 1
        fi
        export KUBEADM_TOKEN="$(<"$token_tmpfs")"
        rm "$token_tmpfs"

        hash_tmpfs="$(mktemp)"
        ./u_kubeadm_hash.sh "$hash_tmpfs"
        if [ ! -s "$hash_tmpfs" ]; then
            echo "❌ Error: failed to generate kubeadm hash" >&2
            exit 1
        fi
        export KUBEADM_HASH="$(<"$hash_tmpfs")"
        rm "$hash_tmpfs"
        break
        ;;
    kube_worker)
        ignition_url="http://localhost:8000/k8s_ignition_worker.yml"
        memory_size="2048"
        num_cpus="2"

        token_tmpfs="$(mktemp)"
        ./u_kubeadm_token.sh "$token_tmpfs"
        if [ ! -s "$token_tmpfs" ]; then
            echo "❌ Error: failed to generate kubeadm token" >&2
            exit 1
        fi
        export KUBEADM_TOKEN="$(<"$token_tmpfs")"
        rm "$token_tmpfs"

        hash_tmpfs="$(mktemp)"
        ./u_kubeadm_hash.sh "$hash_tmpfs"
        if [ ! -s "$hash_tmpfs" ]; then
            echo "❌ Error: failed to generate kubeadm hash" >&2
            exit 1
        fi
        export KUBEADM_HASH="$(<"$hash_tmpfs")"
        rm "$hash_tmpfs"
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
    echo "Failed to download file! Please run ./ignition.sh to start the server."
    exit 1
fi

echo "Wireguard client 1-10 are reserved for the wg hub, host machine and load balancer."
read -p "Input your wireguard client no (11-254): " wireguard_client_no
pad_wireguard_client_no=$(printf "%03d" $wireguard_client_no)

echo "Selected wireguard client no: $pad_wireguard_client_no"

SOURCE_WG_FILE=./wireguard-client-config/wireguard-vpn/${pad_wireguard_client_no}/wg0.conf
USING_WG_MARK_FILE=./wireguard-client-config/wireguard-vpn/${pad_wireguard_client_no}/using.lock
export WG_IP_ADDRESS=$(cat ./wireguard-client-config/wireguard-vpn/${pad_wireguard_client_no}/wg_ip_address.txt)

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

mkdir -p "$ssh_dir"

shopt -s nullglob
ssh_pub_key_files=("$ssh_dir"/*.pub)
shopt -u nullglob
need_new_ssh_key=false
if [ ${#ssh_pub_key_files[@]} -eq 0 ]; then
    echo "No SSH PUB KEY IN $ssh_dir directory."
    echo "Creating a new SSH key pair..."
    need_new_ssh_key=true
else
    echo "Some SSH PUB KEY IN $ssh_dir directory."
    echo "Do you want to create a new SSH key pair?"
    select yn in "Yes" "No"; do
        case $yn in
            Yes)
                need_new_ssh_key=true
                break
                ;;
            No)
                need_new_ssh_key=false
                break
                ;;
            *)
                echo "Error: Invalid selection. Please try again."
                ;;
        esac
    done
fi

if [ "$need_new_ssh_key" = true ]; then
  while true; do
    read -p "Input your key name [coreos]: " key_name
    key_name=${key_name:-coreos}

    # 이미 해당 이름의 키 파일이 존재하는지 검사
    if [ -e "$ssh_dir/$key_name" ] || [ -e "$ssh_dir/$key_name.pub" ]; then
      echo "❌ \"$key_name\" is already exists in $ssh_dir directory."
    else
      break
    fi
  done

  # 키 생성
  ssh-keygen -t rsa -b 4096 -C "$key_name" -f "$ssh_dir/$key_name"
fi

ssh_pub_key_files=($ssh_dir/*.pub)

echo "Available SSH public key files:"
select file in "${ssh_pub_key_files[@]}"; do
    if [ -n "$file" ]; then
        export SSH_PUB_KEY=$(cat $file | tr -d '\n')
        echo "Selected SSH public key: $file"
        break
    else
        echo "Error: Invalid selection. Please try again."
    fi
done

export ENC_WG0_CONF=$(openssl base64 -A -in "$DEST_WG_FILE")

mac_tz=$(sudo systemsetup -gettimezone 2>/dev/null | awk -F': ' '{print $2}')
if [ -z "$mac_tz" ]; then
    echo "Error: Unable to detect macOS timezone."
    exit 1
fi
export ZINCATI_TIMEZONE="$mac_tz"

read -p "Enter Zincati reboot window start time [HH:MM, default 00:00]: " ZINCATI_START
export ZINCATI_START=${ZINCATI_START:-00:00}

read -p "Enter Zincati reboot window length in minutes [default 60]: " ZINCATI_LENGTH
export ZINCATI_LENGTH=${ZINCATI_LENGTH:-60}

echo "Zincati timezone: $ZINCATI_TIMEZONE"
echo "Zincati reboot window start: $ZINCATI_START"
echo "Zincati reboot window length: $ZINCATI_LENGTH"

echo "Generating ignition file from template..."

export TIMESTAMP_NODE_NAME=$(date +%Y%m%d%H%M%S)
echo "Timestamp node name: $TIMESTAMP_NODE_NAME"
envsubst < $ignition_template_path > $ignition_bu_path

ignition_path="$temp_dir/$vm_name/ignition.ign"
butane --pretty < "$ignition_bu_path" > "$ignition_path"

echo "You can check the generated ignition file at: $ignition_path"

# vm 디렉토리 생성
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

mac_last_byte=$(printf "%02x" $wireguard_client_no)

echo "Making starting script... ($vm_dir/start_vm.sh)"
cat <<EOF > $vm_dir/start_vm.sh
#!/bin/bash

if ps aux | grep -v grep | grep "qemu-system-aarch64" | grep -q "$vm_name"; then
    echo "VM is already running: $vm_name"
    exit 1
fi

# QEMU 실행
echo "Next job needs sudo permission to run QEMU with vmnet-shared network."
sudo -v

echo "Running QEMU... $vm_name"
nohup sudo caffeinate -i qemu-system-aarch64 \
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
EOF
chmod +x $vm_dir/start_vm.sh

# If control-plane mode, register IP
if [[ "$vm_mode" =~ ^kube_.*_main$ ]]; then
  mkdir -p $LOADBALANCER_CONF_DIR
  touch "$MAIN_ADDRESSES_FILE"
  echo "$WG_IP_ADDRESS" >> "$MAIN_ADDRESSES_FILE"
  echo "[INFO] Added $WG_IP_ADDRESS to $MAIN_ADDRESSES_FILE"
  echo "[INFO] Load balancer updated with new main address. Run ./u_renew_loadbalancer.sh to apply changes."
  ./u_renew_loadbalancer.sh
else
  echo "[INFO] This is a worker node, no need to update load balancer."
fi

echo "Run the VM with the following command: $vm_dir/start_vm.sh"
echo "or use ./u_start_vm_machine.sh to start the VM."