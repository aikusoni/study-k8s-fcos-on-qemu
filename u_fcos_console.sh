#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

menu_mode=false

if [ -t 1 ]; then
  bold="$(printf '\033[1m')"
  dim="$(printf '\033[2m')"
  reset="$(printf '\033[0m')"
else
  bold=""
  dim=""
  reset=""
fi

usage() {
  cat <<'EOF'
Usage:
  ./u_fcos_console.sh
  ./u_fcos_console.sh <command>

Commands:
  status          Show host runtime, Podman, WireGuard, HAProxy, VM status
  list            List generated FCOS VM machines
  podman          Start or initialize the Podman machine
  wireguard       Start or create the WireGuard container/configs
  connect-wg      Connect the macOS host to WireGuard
  loadbalancer    Create/recreate the HAProxy container
  renew-lb        Regenerate and reload HAProxy config
  bootstrap       Run 00 -> 03 host runtime bootstrap
  registry        Start local insecure registry
  registry-nodes  Configure VM containerd to trust the local registry
  storage         Install local-path-provisioner StorageClass
  ignition        Run the Ignition template HTTP server
  new-vm          Create a new FCOS VM from the interactive generator
  create-start    Create a new FCOS VM, then open the start selector
  start-vm        Start a generated VM
  stop-vm         Stop a running VM
  ssh             SSH into a VM
  kube-status     Inspect Kubernetes cluster state
  kubectl-shell   Open a temporary kubectl shell
  vm-systemd      Inspect VM systemd units
  vm-logs         Inspect VM systemd units plus kubelet/kubeadm logs
  join            Print kubeadm join command from a control-plane node
  token           Print kubeadm token from a control-plane node
  hash            Print kubeadm discovery hash from a control-plane node
  kubelet-log     Save kubelet journal from a VM to .logs/
  clean           Delete generated VM/runtime state after confirmation
  help            Show this help
EOF
}

pause_if_menu() {
  if [ "$menu_mode" = true ]; then
    echo
    read -r -p "Press Enter to return to the console..." _
  fi
}

print_title() {
  echo
  echo "${bold}== $1 ==${reset}"
}

note() {
  echo "${dim}$1${reset}"
}

require_script() {
  local script="$1"
  if [ ! -f "$script" ]; then
    echo "ERROR: script not found: $script" >&2
    return 1
  fi
}

run_script() {
  local title="$1"
  local script="$2"
  shift 2
  local had_errexit=false
  case "$-" in
    *e*) had_errexit=true ;;
  esac

  print_title "$title"
  require_script "$script" || return 1

  set +e
  bash "$script" "$@"
  local status=$?
  if [ "$had_errexit" = true ]; then
    set -e
  else
    set +e
  fi

  if [ "$status" -eq 0 ]; then
    echo
    echo "Done."
  else
    echo
    echo "Command exited with status $status."
  fi
  return "$status"
}

run_script_pause() {
  set +e
  run_script "$@"
  local status=$?
  set -e
  pause_if_menu
  return "$status"
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [yes/no]: " answer
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) echo "Aborted."; return 1 ;;
  esac
}

bootstrap_runtime() {
  print_title "Bootstrap host runtime"
  note "This runs 00 -> 03: Podman machine, WireGuard, host WireGuard, HAProxy."
  note "WireGuard setup/connect can ask for sudo in this terminal."
  confirm "Continue" || return 1

  run_script "1/4 Podman machine" ./00_run_podman_machine.sh || return $?
  run_script "2/4 WireGuard container" ./01_run_podman_wg.sh || return $?
  run_script "3/4 Host WireGuard connect" ./02_connect_wg.sh || return $?
  run_script "4/4 HAProxy load balancer" ./03_run_cluster_load_balancer.sh || return $?
}

create_and_start_vm() {
  print_title "Create and start FCOS VM"
  note "The generator is interactive. Starting the VM can ask for sudo because QEMU uses vmnet-shared."
  confirm "Create a VM and then open the VM start selector" || return 1

  run_script "Create FCOS VM" ./05_init_kube_vm_qemu.sh || return $?
  run_script "Start FCOS VM" ./u_start_vm_machine.sh || return $?
}

dispatch() {
  local command="${1:-menu}"

  case "$command" in
    menu|"")
      main_menu
      ;;
    status)
      run_script_pause "Host runtime status" ./u_host_runtime_status.sh
      ;;
    list)
      run_script_pause "VM machine list" ./u_list_vm_machine.sh
      ;;
    podman)
      run_script_pause "Start Podman machine" ./00_run_podman_machine.sh
      ;;
    wireguard)
      run_script_pause "Start WireGuard container" ./01_run_podman_wg.sh
      ;;
    connect-wg)
      run_script_pause "Connect host WireGuard" ./02_connect_wg.sh
      ;;
    loadbalancer)
      run_script_pause "Create/recreate HAProxy" ./03_run_cluster_load_balancer.sh
      ;;
    renew-lb)
      run_script_pause "Renew HAProxy config" ./u_renew_loadbalancer.sh
      ;;
    registry)
      run_script_pause "Start local insecure registry" ./u_run_local_registry.sh
      ;;
    registry-nodes)
      run_script_pause "Configure VM containerd registry trust" ./u_configure_vm_containerd_registry.sh
      ;;
    storage)
      run_script_pause "Install local-path StorageClass" ./u_install_local_path_storage.sh
      ;;
    ignition)
      print_title "Ignition HTTP server"
      note "This command stays in the foreground. Stop it with Ctrl-C."
      run_script_pause "Run Ignition HTTP server" ./04_ignition_server.sh
      ;;
    new-vm)
      run_script_pause "Create FCOS VM" ./05_init_kube_vm_qemu.sh
      ;;
    start-vm)
      print_title "Start FCOS VM"
      note "QEMU vmnet-shared requires sudo. The password prompt must happen in this terminal."
      run_script_pause "Start FCOS VM" ./u_start_vm_machine.sh
      ;;
    stop-vm)
      run_script_pause "Stop FCOS VM" ./u_stop_vm_machine.sh
      ;;
    ssh)
      run_script_pause "SSH into VM" ./u_ssh_vm.sh
      ;;
    kube-status)
      run_script_pause "Inspect Kubernetes cluster" ./u_inspect_kube_cluster.sh
      ;;
    kubectl-shell)
      run_script_pause "Open kubectl shell" ./u_enter_kubectl_shell.sh
      ;;
    vm-systemd)
      run_script_pause "Inspect VM systemd units" ./u_inspect_vm_systemd.sh
      ;;
    vm-logs)
      run_script_pause "Inspect VM systemd units and logs" ./u_inspect_vm_systemd.sh --logs
      ;;
    join)
      run_script_pause "Get kubeadm join command" ./u_kubeadm_join_command.sh
      ;;
    token)
      run_script_pause "Get kubeadm token" ./u_kubeadm_token.sh
      ;;
    hash)
      run_script_pause "Get kubeadm discovery hash" ./u_kubeadm_hash.sh
      ;;
    kubelet-log)
      run_script_pause "Save kubelet log" ./u_get_kubelet_log.sh
      ;;
    bootstrap)
      set +e
      bootstrap_runtime
      local status=$?
      set -e
      pause_if_menu
      return "$status"
      ;;
    create-start)
      set +e
      create_and_start_vm
      local status=$?
      set -e
      pause_if_menu
      return "$status"
      ;;
    clean)
      print_title "Danger zone"
      note "This delegates to u_delete_all_vm_machine.sh, which asks again before deleting."
      run_script_pause "Delete generated VM state" ./u_delete_all_vm_machine.sh
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Unknown command: $command" >&2
      echo >&2
      usage >&2
      return 2
      ;;
  esac
}

draw_menu() {
  if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
    clear
  fi
  cat <<EOF
${bold}FCOS Kubernetes Console${reset}
${dim}A terminal command hub for this local QEMU + FCOS + kubeadm lab.${reset}

  [1]  Look around             Host runtime status
  [2]  Read the machine board  List generated VM machines

  [3]  Prepare base camp       Run 00 -> 03 host runtime bootstrap
  [4]  Wake Podman             Start or initialize Podman machine
  [5]  Raise WireGuard         Start or create WireGuard container/configs
  [6]  Enter WireGuard tunnel  Connect host WireGuard
  [7]  Raise load balancer     Create/recreate HAProxy
  [8]  Renew load balancer     Regenerate and reload HAProxy config
  [9]  Open ignition gate      Run Ignition HTTP server

  [30] Start local registry    Host insecure registry for VM image pulls
  [31] Trust registry on VMs   Patch existing nodes' containerd config
  [32] Install local storage   local-path-provisioner StorageClass

  [10] Forge a new VM          Create FCOS VM
  [11] Forge and boot VM       Create FCOS VM, then start selector
  [12] Boot a VM               Start generated VM
  [13] Halt a VM               Stop running VM

  [14] Enter a VM              SSH into VM
  [15] Inspect VM services     systemd unit status
  [16] Inspect VM logs         systemd unit status plus kubelet/kubeadm logs
  [17] Survey Kubernetes       Cluster status snapshot
  [18] Open kubectl shell      Temporary kubeconfig shell

  [19] Get join command        kubeadm join command
  [20] Get token               kubeadm token
  [21] Get discovery hash      kubeadm discovery hash
  [22] Save kubelet log        Write VM kubelet journal to .logs/

  [90] Clean generated state   Danger zone
  [h]  Help
  [q]  Quit
EOF
}

main_menu() {
  menu_mode=true

  while true; do
    draw_menu
    echo
    read -r -p "> " choice

    case "$choice" in
      1|look|status) dispatch status ;;
      2|list|machines) dispatch list ;;
      3|bootstrap) dispatch bootstrap ;;
      4|podman) dispatch podman ;;
      5|wireguard|wg) dispatch wireguard ;;
      6|connect|connect-wg) dispatch connect-wg ;;
      7|loadbalancer|lb) dispatch loadbalancer ;;
      8|renew|renew-lb) dispatch renew-lb ;;
      9|ignition) dispatch ignition ;;
      30|registry) dispatch registry ;;
      31|registry-nodes) dispatch registry-nodes ;;
      32|storage) dispatch storage ;;
      10|new|new-vm) dispatch new-vm ;;
      11|create-start) dispatch create-start ;;
      12|start|start-vm) dispatch start-vm ;;
      13|stop|stop-vm) dispatch stop-vm ;;
      14|ssh) dispatch ssh ;;
      15|systemd|vm-systemd) dispatch vm-systemd ;;
      16|logs|vm-logs) dispatch vm-logs ;;
      17|kube|kube-status) dispatch kube-status ;;
      18|kubectl|kubectl-shell) dispatch kubectl-shell ;;
      19|join) dispatch join ;;
      20|token) dispatch token ;;
      21|hash) dispatch hash ;;
      22|kubelet-log) dispatch kubelet-log ;;
      90|clean) dispatch clean ;;
      h|help|\?) dispatch help; pause_if_menu ;;
      q|quit|exit) echo "Bye."; break ;;
      "") ;;
      *) echo "Unknown choice: $choice"; pause_if_menu ;;
    esac
  done
}

dispatch "${1:-menu}"
