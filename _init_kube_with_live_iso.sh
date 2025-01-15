#!/bin/bash

# 필요한 도구 확인
command -v vmrun >/dev/null 2>&1 || { echo >&2 "vmrun이 필요합니다. VMware Fusion이 설치되어 있어야 합니다."; exit 1; }

image_dir="./images"
machine_dir="./machines"
host_ip="192.168.222.1"

# 현재 디렉토리에서 사용 가능한 iso 이미지 선택
iso_files=($image_dir/fedora-coreos*.iso)
if [ ${#iso_files[@]} -eq 0 ]; then
    echo "Error: $image_dir 디렉토리에 'fedora-coreos*.iso' 파일이 없습니다."
    echo "https://fedoraproject.org/coreos/download?stream=stable#download_section 에서 다운로드 후 다시 시도하세요."
    exit 1
elif [ ${#iso_files[@]} -eq 1 ]; then
    iso_image="${iso_files[0]}"
    echo "선택된 iso 이미지: $iso_image"
else
    echo "사용 가능한 iso 이미지 목록:"
    select file in "${iso_files[@]}"; do
        if [ -n "$file" ]; then
            iso_image="$file"
            echo "선택된 iso 이미지: $iso_image"
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
      ignition_url="http://${host_ip}:8000/ignition_main.json"
      memory_size="2048"
      num_cpus="4"
      break
      ;;
    kube_worker)
      ignition_url="http://${host_ip}:8000/ignition_worker.json"
      memory_size="1024"
      num_cpus="2"
      break
      ;;
    *)
      echo "오류: 지원되지 않는 선택입니다. 다시 시도하세요."
      ;;
  esac
done


# 사용자 설정
VM_DIR="${machine_dir}/${vm_name}"
VM_NAME="${vm_name}"
VMX_FILE="${VM_DIR}/${VM_NAME}.vmx"
VMDK_FILE="${VM_DIR}/${VM_NAME}.vmdk"
MEMORY_SIZE="${memory_size}"
DISK_SIZE="10GB"
NUM_CPUS="${num_cpus}"
GUEST_OS="arm-fedora-64"

# 디렉토리 생성
mkdir -p "$VM_DIR"

# VMDK 파일 생성
if [ ! -f "$VMDK_FILE" ]; then
    echo "VMDK 파일 생성 중: $VMDK_FILE"
    vmware-vdiskmanager -c -t 0 -s "$DISK_SIZE" -a lsilogic "$VMDK_FILE"
    if [ $? -ne 0 ]; then
        echo "VMDK 파일 생성 실패!"
        exit 1
    fi
else
    echo "VMDK 파일이 이미 존재합니다: $VMDK_FILE"
    exit 1
fi

# VMX 파일 생성
cat <<EOF > "$VMX_FILE"
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
displayName = "$VM_NAME"
firmware = "efi"
guestOS = "$GUEST_OS"
tools.syncTime = "TRUE"
tools.upgrade.policy = "upgradeAtPowerCycle"
numvcpus = "$NUM_CPUS"
cpuid.coresPerSocket = "1"
memsize = "$MEMORY_SIZE"
nvme0.present = "TRUE"
nvme0:0.fileName = "$(realpath $VMDK_FILE)"
nvme0:0.present = "TRUE"
ehci.present = "TRUE"
sata0.present = "TRUE"
sata0:1.present = "TRUE"
sata0:1.deviceType = "cdrom-image"
sata0:1.fileName = "$(realpath $iso_image)"
ethernet0.connectionType = "vmnet2"
ethernet0.addressType = "generated"
ethernet0.virtualDev = "e1000e"
ethernet0.present = "TRUE"
floppy0.present = "FALSE"
monitor.phys_bits_used = "36"
cleanShutdown = "TRUE"
softPowerOff = "FALSE"
usb.present = "TRUE"
EOF

echo "VMX 파일 생성 완료: $VMX_FILE"

# 가상 머신 실행
echo "가상 머신 실행 중..."
vmrun -T fusion start "$VMX_FILE" -args "--ignition-url=http://192.168.222.1:8000/ignition_main.json"
if [ $? -eq 0 ]; then
    echo "가상 머신이 성공적으로 실행되었습니다!"
else
    echo "가상 머신 실행 실패!"
    exit 1
fi