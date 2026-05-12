# 쿠버네티스 클러스터를 로컬 맥에서 QEMU로 실행하기

## 설명
이 프로젝트는 macOS에서 QEMU, Fedora CoreOS, kubeadm을 사용해 로컬 Kubernetes 클러스터를 구성해보는 학습용 프로젝트입니다. VM 간 통신은 WireGuard로 구성하고, 컨트롤 플레인 API는 HAProxy를 통해 접근합니다.

운영 자동화 도구가 아니라 로컬 실험 환경을 재현하기 위한 스크립트 모음입니다. 스크립트는 macOS, Apple Silicon, Homebrew 기반 QEMU 경로, Podman machine, `vmnet-shared` 네트워크 사용을 전제로 합니다.

## 테스트 환경
- **Host:** MacBook Pro (Apple M3 Max)
- **QEMU:** 9.2.0
- **FCOS Image:** fedora-coreos-42.20250623.3.1-qemu.aarch64.qcow2
- **Podman:** 5.5.2

## 사전 요구사항
다음 도구가 로컬 머신에 설치되어 있어야 합니다.

- Podman
- WireGuard Tools (`wg`, `wg-quick`)
- QEMU (`qemu-img`, `qemu-system-aarch64`)
- Butane
- gettext (`envsubst`)
- kubectl
- OpenSSL
- Python 3

## 프로젝트 구조
- `preconfigured.sh` - 클러스터, WireGuard, HAProxy, VM 네트워크 기본값
- `00_run_podman_machine.sh` - Podman machine 준비
- `01_run_podman_wg.sh` - WireGuard 컨테이너와 클라이언트 설정 생성
- `02_connect_wg.sh` - 호스트 머신을 WireGuard에 연결
- `03_run_cluster_load_balancer.sh` - HAProxy 로드밸런서 실행
- `04_ignition_server.sh` - Ignition 템플릿 파일 제공용 HTTP 서버 실행
- `05_init_kube_vm_qemu.sh` - FCOS VM 디스크, Ignition, 시작 스크립트 생성
- `u_fcos_console.sh` - 주요 스크립트를 한 곳에서 실행하는 메뉴형 터미널 콘솔
- `u_run_local_registry.sh` - VM 노드가 이미지를 pull할 수 있는 로컬 insecure registry 실행
- `u_configure_vm_containerd_registry.sh` - 기존 VM의 containerd에 로컬 registry 신뢰 설정 적용
- `u_install_local_path_storage.sh` - kubeadm 클러스터에 local-path-provisioner StorageClass 설치
- `ignition-files/` - Butane 기반 FCOS Ignition 템플릿
- `u_*.sh` - VM 시작/중지, SSH, kubeadm join 정보 조회, kubectl shell 진입용 유틸리티

로컬 실행 중 생성되는 VM 이미지, SSH 키, WireGuard 클라이언트 설정, 로그, HAProxy 런타임 설정은 `.gitignore`에 포함되어 있습니다.

## FCOS 이미지 준비
`images/` 디렉토리에 FCOS QEMU용 `aarch64` qcow2 이미지를 넣어둡니다.

예시:

```bash
mkdir -p images
# Fedora CoreOS 다운로드 페이지에서 qemu.aarch64.qcow2.xz 파일을 받은 뒤 압축을 해제합니다.
# https://fedoraproject.org/coreos/download?stream=stable&arch=aarch64
```

## 실행 순서
```bash
# 1. Podman machine을 실행합니다.
./00_run_podman_machine.sh

# 2. 호스트 머신과 VM들이 접속할 WireGuard 컨테이너를 실행합니다.
./01_run_podman_wg.sh

# 3. 호스트 머신을 WireGuard에 연결합니다.
./02_connect_wg.sh

# 4. 컨트롤 플레인 API 접근용 HAProxy를 실행합니다.
./03_run_cluster_load_balancer.sh

# 5. Ignition 파일 서버를 실행합니다.
./04_ignition_server.sh
```

`04_ignition_server.sh`는 foreground에서 실행됩니다. 새 터미널을 열거나 백그라운드로 실행한 뒤 VM을 생성합니다.

```bash
# 첫 번째 컨트롤 플레인 노드 생성
./05_init_kube_vm_qemu.sh

# 생성된 VM 시작
./u_start_vm_machine.sh
```

첫 번째 컨트롤 플레인 노드의 초기화가 끝난 뒤 `05_init_kube_vm_qemu.sh`를 다시 실행해 추가 컨트롤 플레인 노드 또는 워커 노드를 생성합니다.

Ignition 템플릿 용도:

- `k8s_ignition_first_main.yml` - 최초 컨트롤 플레인 노드
- `k8s_ignition_other_main.yml` - 추가 컨트롤 플레인 노드
- `k8s_ignition_worker.yml` - 워커 노드

## 종합 콘솔
여러 스크립트를 직접 기억하지 않고 메뉴에서 실행하려면 다음 콘솔을 사용합니다.

```bash
./u_fcos_console.sh
```

직접 명령도 실행할 수 있습니다.

```bash
./u_fcos_console.sh status
./u_fcos_console.sh list
./u_fcos_console.sh bootstrap
./u_fcos_console.sh new-vm
./u_fcos_console.sh start-vm
./u_fcos_console.sh kube-status
./u_fcos_console.sh registry
./u_fcos_console.sh registry-nodes
./u_fcos_console.sh storage
```

`start-vm`, `connect-wg`, WireGuard 초기 생성처럼 macOS 네트워크 권한이 필요한 작업은 터미널에서 `sudo` 비밀번호를 요구할 수 있습니다.

## 앱 배포용 애드온
Spring Boot 같은 일반 애플리케이션을 FCOS VM 클러스터에 올리려면 이미지 배포용 registry와 PVC용 StorageClass를 준비합니다.

로컬 registry를 호스트 WireGuard IP에 실행합니다.

```bash
./u_run_local_registry.sh
```

기본 endpoint는 `preconfigured.sh`의 `LOCAL_REGISTRY_ENDPOINT` 값이며, 기본값은 `10.10.117.2:5000`입니다. registry 데이터는 macOS Podman bind mount 문제를 피하기 위해 기본적으로 named volume(`fcos-local-registry-data`)에 저장합니다. 앱 이미지는 이 주소로 push합니다.

```bash
podman build --platform=linux/arm64 -t 10.10.117.2:5000/example/app:local .
podman push --tls-verify=false 10.10.117.2:5000/example/app:local
```

새로 생성되는 VM은 Ignition 템플릿에 로컬 registry용 containerd 설정이 포함됩니다. 이미 생성된 VM에는 다음 스크립트로 같은 설정을 SSH로 적용합니다.

```bash
./u_configure_vm_containerd_registry.sh
```

PVC를 사용하는 앱을 위해 local-path-provisioner를 설치합니다. 이 명령은 `./u_enter_kubectl_shell.sh`가 열어준 kubectl 작업 쉘 안에서 실행합니다.

```bash
./u_enter_kubectl_shell.sh
./u_install_local_path_storage.sh
```

설치 후 `local-path`가 default StorageClass로 설정됩니다.

## kubectl 사용
호스트 머신에서 임시 kubeconfig가 설정된 shell을 열려면 다음 스크립트를 실행합니다.

```bash
./u_enter_kubectl_shell.sh
```

클러스터 상태를 호스트에서 한 번에 확인하려면 다음 스크립트를 실행합니다.

```bash
./u_inspect_kube_cluster.sh
```

특정 `kubectl` 명령만 실행할 수도 있습니다.

```bash
./u_inspect_kube_cluster.sh get nodes -o wide
./u_inspect_kube_cluster.sh get pods -A -o wide
./u_inspect_kube_cluster.sh describe node <node-name>
```

## 상태 확인 유틸리티
생성된 VM과 현재 실행 중인 QEMU 프로세스를 확인합니다.

```bash
./u_list_vm_machine.sh
```

호스트 쪽 런타임 상태를 한 번에 확인합니다.

```bash
./u_host_runtime_status.sh
```

특정 VM 내부의 systemd unit 상태를 확인합니다. Kubernetes `Service` 리소스가 아니라 VM OS 레벨의 `kubelet`, `containerd`, `wg-quick` 같은 systemd unit을 확인하는 용도입니다.

```bash
./u_inspect_vm_systemd.sh
./u_inspect_vm_systemd.sh --logs
```
