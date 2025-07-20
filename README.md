# Run a Kubernetes Cluster Locally

## Overview
This is a study project to run a Kubernetes cluster on my local machine.

## Test Environment
- **Host:** MacBook Pro (Apple M3 Max)  
- **QEMU:** 9.2.0  
- **FCOS Image:** fedora-coreos-42.20250623.3.1-qemu.aarch64.qcow2  
- **Podman:** 5.5.2  

## File Structure
- `./ignition-files` — Ignition configs for control-plane and worker nodes  
- `./images` — FCOS QCOW2 images (not included in this repo)  

## Running Sequence

```bash
# 1. Start the Podman VM
./00_run_podman_machine.sh

# 2. Launch the WireGuard container
./01_run_podman_wg.sh

# 3. Connect your shell to the WireGuard network
./02_connect_wg.sh

# 4. Start the HAProxy load-balancer
./03_run_cluster_load_balancer.sh

# 5. Serve Ignition configs
./04_ignition_server.sh
# (or run in background: `nohup ./04_ignition_server.sh &`)

# 6. Initialize Fedora CoreOS VM with Ignition
#    (Repeat this for each control-plane or worker node you want to add)
./05_init_kube_vm_qemu.sh

# 7. Boot the VM
#    (Run again to start each node)
./u_start_vm.sh
```

## Kubectl On Host Machine
```sh
# Enter a shell pre-configured for kubectl
./u_enter_kubectl_shell.sh
```