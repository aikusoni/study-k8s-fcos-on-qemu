# 쿠버네티스 클러스터를 로컬 맥에서 QEMU로 실행하기

## 설명
이 프로젝트는 쿠버네티스 클러스터를 로컬 맥에서 QEMU로 FCOS를 사용해서 구성하는 방법을 연습한 코드입니다.

## 테스트 환경
- **Host:** MacBook Pro (Apple M3 Max)  
- **QEMU:** 9.2.0  
- **FCOS Image:** fedora-coreos-42.20250623.3.1-qemu.aarch64.qcow2  
- **Podman:** 5.5.2  

## 프로젝트 구조
- `./ignition-files` — FCOS Ignition config 파일들이 들어있습니다.
- `./images` — FCOS VM 이미지를 저장해두는 디렉토리입니다. (예를 들어, https://fedoraproject.org/coreos/download?stream=stable&arch=aarch64#download_section -> https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/42.20250705.3.0/aarch64/fedora-coreos-42.20250705.3.0-qemu.aarch64.qcow2.xz를 다운로드해서 압축을 푼 다음 저장해두면 됩니다.)

## 실행 순서

```bash
# Podman 머신을 먼저 실행합니다.
./00_run_podman_machine.sh

# 호스트머신, VM 모두가 연결할 WireGuard 컨테이너를 실행합니다.
./01_run_podman_wg.sh

# 와이어가드에 호스트 머신을 연결합니다.
./02_connect_wg.sh

# Control Plane를 묶을 로드 밸런서를 실행합니다. (HAProxy)
./03_run_cluster_load_balancer.sh

# 이그니션 파일 서벌르 실행합니다. (이 서버는 ignition-files 디렉토리에 있는 Ignition config 파일들을 제공하는 역할을 합니다.)
./04_ignition_server.sh

# 신규 터미널을 열거나 04_ignition_server.sh를 백그라운드로 실행한 후, 다음 명령어를 실행합니다.

# FCOS VM을 생성합니다.
# k8s_ignition_first_main.yml 파일은 최초로 실행해야하는 쿠버네티스 마스터 노드의 이그니션 파일입니다.
# k8s_ignition_other_main.yml 파일은 첫번째 마스터 노드가 초기화된 후, 추가로 실행할 마스터 노드의 이그니션 파일입니다.
# k8s_ignition_worker.yml 파일은 워커 노드의 이그니션 파일입니다.
./05_init_kube_vm_qemu.sh

# 아래 스크립트로 쿠버네티스 VM을 시작합니다.
./u_start_vm.sh

# k8s_ignition_first_main.yml 파일로 만들어진 vm을 실행한 후, 컨트롤 플레인 초기화가 완료되면
# 05_init_kube_vm_qemu.sh 스크립트로 다른 노드들을 생성하고, 실행하면 클러스터 구성이 완료됩니다.
```

## 호스트 머신에서 kubectl을 사용하려면 다음 명령어를 실행합니다.
```sh
# Enter a shell pre-configured for kubectl
./u_enter_kubectl_shell.sh
```