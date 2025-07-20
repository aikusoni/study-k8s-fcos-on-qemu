# Run k8s cluster on local machine

## Overview
- This is my study project to run k8s cluster on my local machine.

## Test Environment
- Host Machine : MacBook Pro (Apple M3 Max)
- QEMU : QEMU emulator version 9.2.0
- FCOS Image : fedora-coreos-42.20250623.3.1-qemu.aarch64.qcow2
- Podman Version : 5.5.2

## File structure
- ./ignition-files : fcos ignition files for k8s control plane and worker node.
- ./images : FCOS image files (It is not included in this repository).

## Running Sequence
```sh
# Run podman machine.
./00_run_podman_machine.sh

# Run wireguard container onto podman.
./01_run_podman_wg.sh

# Connect to the wireguard container to communicate with k8s node Virtual Machine in host machine.
./02_conenct_wg.sh

# Run haproxy for clustering.
./03_run_cluster_load_balancer.sh

# Run ignition distribution servers on host machine to initialize fcos.
./04_ignition_server.sh 
# or execute 'nohup ./04_ignition_server.sh &' to avoid blocking the terminal.

# Initialize fcos on qemu.
# This script make vm image and run qemu with fcos.
./05_init_kube_vm_qemu.sh

# Run VM via below scripts.
./u_start_vm.sh

# Use the script below to launch a shell for running kubectl on the host
# (while the Kubernetes control plane is running in a QEMU VM)
./u_enter_kubectl_shell.sh
```

## Roadmap
- ✅ Initialize wireguard vpn server on host machine.
    - The project uses podman to run wireguard vpn server.
- ✅ Initialize fedora core os on qemu.
- ✅ Connecting fedora core os to wireguard vpn.
- ✅ Initialize k8s control plane.
- ✅ Initialize k8s worker node.
