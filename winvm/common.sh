# Shared by build-image.sh and vm.sh. Source it after setting HERE (winvm/).

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

BASE_IMAGE_NAME=ebpf-win.qcow2               # in output/, written by Packer
KEY="$HERE/keys/id_ed25519"                  # created by build-image.sh, used by vm.sh
QEMU_DOCKER="$HERE/qemu-docker/qemu-docker.sh"

# Set ACCEL to kvm if /dev/kvm is usable, else tcg (unless already set).
# Without KVM, QEMU emulates the CPU in software (TCG): much slower, but works.
# Host QEMU 6.2 crashes Windows under TCG, so TCG runs QEMU 10 from Docker ($QEMU_DOCKER).
detect_accel() {
    if [[ -z "${ACCEL:-}" ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; else ACCEL=tcg; fi
    fi
    case "$ACCEL" in
        kvm) [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm not accessible. Enable VT-x/AMD-V and add yourself to the 'kvm' group." ;;
        tcg) ;;
        *)   die "ACCEL must be kvm or tcg" ;;
    esac
}
