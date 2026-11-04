#!/usr/bin/env bash
# Run the Windows eBPF VM: test the MinGW build from mingw/build.sh (samples +
# eBPF program) on Windows Server 2022 with eBPF for Windows installed.
#
# The base image is never modified: the VM always runs on a copy-on-write
# overlay (.run/overlay.qcow2) that is backed by the base image.
#
# Usage:
#   ./vm.sh test                   fresh overlay -> boot -> run guest/guest-test.ps1 on out/mingw -> shut down
#   ./vm.sh start                  boot the VM in the background (keeps existing overlay)
#   ./vm.sh ssh [command...]       PowerShell session (or one command) in the VM
#   ./vm.sh stop                   shut the VM down cleanly
#   ./vm.sh reset                  stop and discard the overlay (back to the clean base)
#   ./vm.sh status
#
# Environment overrides:
#   IMAGE      base qcow2   (default: output/ebpf-win.qcow2)
#   VM_CPUS    default: nproc (max 8)
#   VM_MEMORY  MiB, default: 8192
#   SSH_PORT   host port forwarded to guest 22   (default: 2223)
#   VNC        VNC display on 127.0.0.1, e.g. 2 -> port 5902 (default: off)
#   TEST_DIR   what 'test' copies into the VM    (default: <repo>/out/mingw)
#   ACCEL      kvm or tcg (default: kvm if /dev/kvm is usable, else tcg)
#   QEMU       QEMU binary (default: qemu-system-x86_64 with kvm, qemu-docker/qemu-docker.sh with tcg)
#   BOOT_TIMEOUT  seconds to wait for ssh      (default: 600 with kvm, 3600 with tcg)
#   KEEP=1     with 'test': leave the VM running afterwards
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

IMAGE="${IMAGE:-$HERE/output/ebpf-win.qcow2}"
RUN_DIR="$HERE/.run"
OVERLAY="$RUN_DIR/overlay.qcow2"
PIDFILE="$RUN_DIR/qemu.pid"
KEY="$HERE/keys/id_ed25519"
SSH_PORT="${SSH_PORT:-2223}"
TEST_DIR="${TEST_DIR:-$REPO/out/mingw}"

cpus_default=$(nproc); (( cpus_default > 8 )) && cpus_default=8
VM_CPUS="${VM_CPUS:-$cpus_default}"
VM_MEMORY="${VM_MEMORY:-8192}"

# Without KVM, QEMU emulates the CPU in software (TCG): much slower, but works.
if [[ -z "${ACCEL:-}" ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; else ACCEL=tcg; fi
fi
case "$ACCEL" in
    kvm) ACCEL_ARGS=(-machine pc,accel=kvm -cpu host) ;;
    tcg) ACCEL_ARGS=(-machine pc -accel tcg,thread=multi -cpu max) ;;
    *)   echo "error: ACCEL must be kvm or tcg" >&2; exit 1 ;;
esac
if [[ "$ACCEL" == tcg ]]; then BOOT_TIMEOUT="${BOOT_TIMEOUT:-3600}"; else BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"; fi
# Host QEMU 6.2 crashes Windows under TCG, so TCG runs QEMU 10 from Docker.
if [[ "$ACCEL" == tcg ]]; then QEMU="${QEMU:-$HERE/qemu-docker/qemu-docker.sh}"; else QEMU="${QEMU:-qemu-system-x86_64}"; fi

SSH_OPTS=(-i "$KEY" -p "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
SCP_OPTS=(-i "$KEY" -P "$SSH_PORT"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o BatchMode=yes)
TARGET="Administrator@127.0.0.1"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

is_running() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

vm_ssh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

wait_for_ssh() {
    log "Waiting for the VM to accept ssh on port $SSH_PORT..."
    local deadline=$((SECONDS + BOOT_TIMEOUT))
    while (( SECONDS < deadline )); do
        if vm_ssh 'exit 0' 2>/dev/null; then return 0; fi
        is_running || die "QEMU exited during boot. See $RUN_DIR/qemu.log"
        sleep 5
    done
    die "VM did not become reachable over ssh within $BOOT_TIMEOUT seconds."
}

cmd_start() {
    if is_running; then log "VM already running (pid $(cat "$PIDFILE"))."; return; fi
    [[ -f "$IMAGE" ]] || die "base image not found: $IMAGE (run ./winvm/build-image.sh, or set IMAGE=...)"
    [[ -f "$KEY" ]]   || die "ssh key not found: $KEY (it is created by ./build-image.sh)"
    mkdir -p "$RUN_DIR"
    if [[ ! -f "$OVERLAY" ]]; then
        qemu-img create -q -f qcow2 -b "$(realpath "$IMAGE")" -F qcow2 "$OVERLAY"
    fi

    local display=(-display none)
    [[ -n "${VNC:-}" ]] && display+=(-vnc "127.0.0.1:${VNC}")

    log "Starting VM (accel=$ACCEL, cpus=$VM_CPUS, memory=${VM_MEMORY}M, ssh=127.0.0.1:$SSH_PORT)"
    # Devices must match packer/windows.pkr.hcl: i440fx machine, IDE disk, e1000 NIC.
    # Not -daemonize: qemu-docker.sh must stay in the foreground of its container.
    nohup "$QEMU" \
        -name ebpf-win \
        "${ACCEL_ARGS[@]}" \
        -smp "$VM_CPUS" -m "$VM_MEMORY" \
        -drive file="$OVERLAY",if=ide,format=qcow2,cache=writeback \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
        -device e1000,netdev=n0 \
        -rtc base=utc \
        "${display[@]}" \
        </dev/null >"$RUN_DIR/qemu.log" 2>&1 &
    echo $! > "$PIDFILE"
    wait_for_ssh
    log "VM is up. Connect with: $0 ssh"
}

cmd_stop() {
    if ! is_running; then log "VM is not running."; rm -f "$PIDFILE"; return; fi
    local pid; pid=$(cat "$PIDFILE")
    log "Shutting down VM..."
    vm_ssh 'Stop-Computer -Force' 2>/dev/null || true
    for _ in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || { rm -f "$PIDFILE"; log "VM stopped."; return; }
        sleep 2
    done
    log "Clean shutdown timed out; killing QEMU."
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
}

cmd_reset() {
    cmd_stop
    rm -f "$OVERLAY"
    log "Overlay discarded; next start uses the clean base image."
}

cmd_status() {
    if is_running; then echo "running (pid $(cat "$PIDFILE"), ssh 127.0.0.1:$SSH_PORT)"; else echo "stopped"; fi
    [[ -f "$OVERLAY" ]] && qemu-img info "$OVERLAY" | grep -E 'disk size|backing file:' || true
}

cmd_test() {
    compgen -G "$TEST_DIR/*.exe" >/dev/null || die "no .exe in $TEST_DIR (run ./mingw/build.sh first)"

    TEST_TMP=$(mktemp -d)
    STARTED_BY_TEST=0
    trap on_test_exit EXIT
    local tmp="$TEST_TMP"

    if ! is_running; then
        rm -f "$OVERLAY"          # fresh, clean VM for every test
        STARTED_BY_TEST=1
        cmd_start
    fi

    log "Copying $TEST_DIR into the VM"
    tar -C "$TEST_DIR" -cf "$tmp/test.tar" .
    scp "${SCP_OPTS[@]}" "$tmp/test.tar" "$HERE/guest/guest-test.ps1" "$TARGET:"

    log "Running guest-test.ps1 inside the VM"
    vm_ssh "powershell -NoProfile -ExecutionPolicy Bypass -File guest-test.ps1"
    log "Done."
}

# Clean up after 'test', including when it fails: remove temp files and shut
# down the VM if this test started it (unless KEEP=1).
on_test_exit() {
    local rc=$?
    rm -rf "${TEST_TMP:-}"
    if [[ "${STARTED_BY_TEST:-0}" == 1 && "${KEEP:-0}" != 1 ]]; then
        cmd_stop || true
    fi
    (( rc == 0 )) || echo "test failed (exit $rc). Re-run with KEEP=1 to inspect the VM via ./vm.sh ssh" >&2
    exit "$rc"
}

cmd_ssh() {
    is_running || die "VM is not running (./vm.sh start)."
    if [[ $# -eq 0 ]]; then
        ssh -t "${SSH_OPTS[@]/BatchMode=yes/BatchMode=no}" "$TARGET"
    else
        vm_ssh "$@"
    fi
}

case "${1:-}" in
    test)   cmd_test ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    reset)  cmd_reset ;;
    status) cmd_status ;;
    ssh)    shift; cmd_ssh "$@" ;;
    *) sed -n '2,26p' "$0"; exit 1 ;;
esac
