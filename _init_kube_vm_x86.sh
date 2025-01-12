#!/bin/bash

ova_path="./fedora-coreos-41.20241215.3.0-vmware.x86_64.ova"

if [ ! -f "$ova_path" ]; then
	echo "Error: Failed to find ova image from the path ($ova_path)"
	exit 1
fi

echo "VirtualMachine OVA FIle : $ova_path..."

# Input New VM Name
read -p "Input your new virtual machine name: " vm_name
vm_dir=./machines
vm_path=${vm_dir}/${vm_name}.vmx

mkdir -p $vm_dir

# VM Name Validation
if [ -d "$vm_path" ]; then
	echo "Error: The virtual machine '$vm_name' is already exists."
	exit 1
fi

read -p "Input your new virtual machine mode (kube_master or kube_worker) : " vm_mode

case "$vm_mode" in
  kube_master)
    ignition_url="http://localhost:8000/ignition_master.json"
    ;;
  kube_worker)
    ignition_url="http://localhost:8000/ignition_worker.json"
    ;;
  *)
    echo "오류: 지원되지 않는 vm_mode입니다. kube_master 또는 kube_worker를 사용하세요."
    exit 1
    ;;
esac

ovftool \
  --X:injectOvfEnv \
  --prop:"guestinfo.coreos.config.url=${ignition_url}" \
  "$ova_path" \
  "$vm_path"  
