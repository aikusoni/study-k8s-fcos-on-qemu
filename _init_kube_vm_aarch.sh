#!/bin/bash

# 필요한 도구 확인
command -v qemu-img >/dev/null 2>&1 || { echo >&2 "qemu-img가 필요합니다. 설치 후 다시 시도하세요."; exit 1; }
command -v vmrun >/dev/null 2>&1 || { echo >&2 "vmrun이 필요합니다. VMware Fusion이 설치되어 있어야 합니다."; exit 1; }
# command -v ovftool >/dev/null 2>&1 || { echo >&2 "ovftool이 필요합니다. VMware Fusion이 설치되어 있어야 합니다."; exit 1; }

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
      break
      ;;
    kube_worker)
      ignition_url="http://localhost:8000/ignition_worker.json"
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
fi

# 디렉토리 설정
vm_dir="./machines/$vm_name"
mkdir -p "$vm_dir"

# 파일 경로 설정
# original_vmx_path="$temp_dir/$vm_name/original.vmx"
vmx_path="${vm_dir}/${vm_name}.vmx"
vmdk_path="${vm_dir}/${vm_name}.vmdk"
# ovf_path="$temp_dir/$vm_name/${vm_name}.ovf"
# mf_path="$temp_dir/${vm_name}.mf"
# ova_path="${vm_dir}/${vm_name}.ova"
iso_path="${vm_dir}/ignition.iso"

ignition_encoding="base64"
ignition_encoded=$(base64 -i "$ignition_path" | tr -d '\n')

config_dir="$temp_dir/$vm_name/config"
mkdir -p "$config_dir"

cp "$ignition_path" "$config_dir/config.ign"

cat "$config_dir/config.ign"

hdiutil makehybrid -o "${iso_path}" "$config_dir" -iso -joliet -default-volume-name config-2 -iso-volume-name config-2 -udf-volume-name config-2

# qcow2 이미지를 VMDK로 변환
echo "Converting qcow2 image to VMDK..."
qemu-img convert -f qcow2 "$qcow2_image" -O vmdk "$vmdk_path"
if [ $? -ne 0 ]; then
    echo "Error: VMDK 변환에 실패했습니다."
    exit 1
fi

cat <<EOF > "$vmx_path"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
vmci0.present = "TRUE"
hpet0.present = "TRUE"
virtualHW.productCompatibility = "hosted"
powerType.powerOff = "soft"
powerType.powerOn = "soft"
powerType.suspend = "soft"
powerType.reset = "soft"
displayName = "$vm_name"
firmware = "efi"
guestOS = "arm-fedora-64"
tools.syncTime = "TRUE"
tools.upgrade.policy = "upgradeAtPowerCycle"
numvcpus = "2"
cpuid.coresPerSocket = "1"
memsize = "2048"
nvme0.present = "TRUE"
nvme0:0.fileName = "$(realpath $vmdk_path)"
nvme0:0.present = "TRUE"
usb.present = "TRUE"
ehci.present = "TRUE"
ethernet0.connectionType = "vmnet2"
ethernet0.addressType = "generated"
ethernet0.virtualDev = "e1000e"
ethernet0.present = "TRUE"
floppy0.present = "FALSE"
monitor.phys_bits_used = "36"
cleanShutdown = "TRUE"
softPowerOff = "FALSE"
sata0.present = "TRUE"
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$(realpath $iso_path)"
sata0:1.startConnected = "TRUE"
sata0:1.allowGuestConnectionControl = "TRUE"
sata0:1.pciSlotNumber = "35"
EOF

# VMDK TO OVA 변환
# echo "Converting VMDK to OVA..."
# ovftool "$original_vmx_path" "$ova_path"

# echo "Injecting Ignition URL into OVA..."
# ovftool \
#     --powerOffTarget \
#     --name="${vm_name}" \
#     --allowExtraConfig \
#     --extraConfig:guestinfo.ignition.config.data.encoding="${ignition_encoding}" \
#     --extraConfig:guestinfo.ignition.config.data="${ignition_encoded}" \
#     "$ova_path" \
#     "$vmx_path"

# sed -i '' 's/^guestOS = ".*"/guestOS = "arm-fedora-64"/I' "$vmx_path"

# 가상 머신 시작
echo "Starting VM using vmrun..."
vmrun -T fusion start "$(realpath $vmx_path)"
if [ $? -eq 0 ]; then
    echo "가상 머신이 성공적으로 시작되었습니다."
else
    echo "Error: 가상 머신 시작에 실패했습니다."
fi
