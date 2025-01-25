# Run k8s cluster on local machine

## Overview
- This is my study project to run k8s cluster on my local machine.

## Specifications
- This project is to run k8s cluster on macbook pro (m3).

- The k8s cluster is running on fedora core os that is running on qemu.

- The k8s nodes are communicating with each other through wireguard vpn.

## Running Sequence
```sh
# Run ignition template server.
./ignition-server/ignition.sh

# Run wireguard vpn server on host machine.
## The wireguard vpn server is running on host machine with podman.
## The wireguard vpn server is used to connect k8s nodes.
./host_vpn_server.sh

# Run fedora core os on qemu. (k8s running on fedora core os)
## The fedora core os is running on qemu.
## The fedora core os is used to run k8s cluster.
./init_kube_vm_qemu.sh
```

## Roadmap
- ✅ Initialize wireguard vpn server on host machine.
    - The project uses podman to run wireguard vpn server.
- ✅ Initialize fedora core os on qemu.
- ✅ Connecting fedora core os to wireguard vpn.
- 🚧 Initialize k8s control plane.
- 🚧 Initialize k8s worker node.