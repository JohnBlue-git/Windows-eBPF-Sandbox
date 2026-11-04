#!/usr/bin/env bash
# Build the Windows VM base image (qcow2) with Packer (packer/) + QEMU:
# Windows Server 2022 Core + OpenSSH + test signing + eBPF for Windows.
# Run once on the Linux host. About 1 hour without KVM (TCG, QEMU 10 in
# Docker); faster with KVM.
#
# Usage:
#   ./build-image.sh [path/to/iso]
#
# ISO selection (first match wins): 1. the argument, 2. $WIN_ISO,
# 3. iso/windows-server-2022.iso (Microsoft evaluation ISO).
# If <iso>.sha256 exists it is verified.
#
# Environment overrides:
#   WIN_ISO_SHA256   ISO sha256          (default: from <iso>.sha256, else not verified)
#   WIN_IMAGE_NAME   install.wim image   (default: Windows Server 2022 SERVERSTANDARDCORE)
#   WIN_IMAGE_INDEX  select image by index instead of name
#   WIN_PRODUCT_KEY  product key         (default: none, for evaluation media)
#   WIN_ADMIN_PASSWORD  Administrator password inside the VM
#   VM_CPUS / VM_MEMORY  resources used during the build
#   ACCEL            kvm or tcg     (default: kvm if /dev/kvm is usable, else tcg)
#   QEMU             QEMU binary for tcg (default: qemu-docker/qemu-docker.sh, QEMU 10 in Docker)
#   HEADLESS=false   show the QEMU window (otherwise watch via VNC 127.0.0.1:5900-5910)
#   FORCE=1          overwrite an existing output/ directory
#
# The eBPF for Windows version and MSI sha256 come from ../ebpf-for-windows.env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$HERE"
source "$HERE/common.sh"
source "$REPO/ebpf-for-windows.env"

ISO="${1:-${WIN_ISO:-$HERE/iso/windows-server-2022.iso}}"

EBPF_MSI="$HERE/downloads/ebpf-for-windows.x64.$EBPF_FOR_WINDOWS_VERSION.msi"
EBPF_URL="https://github.com/microsoft/ebpf-for-windows/releases/download/v$EBPF_FOR_WINDOWS_VERSION/ebpf-for-windows.x64.$EBPF_FOR_WINDOWS_VERSION.msi"

# --- prerequisites -----------------------------------------------------------
for cmd in packer qemu-img ssh-keygen curl sha256sum; do
    command -v "$cmd" >/dev/null || die "'$cmd' not found. See docs/winvm.md (host setup)."
done
detect_accel
[[ "$ACCEL" == tcg ]] && echo "warning: /dev/kvm not used; building with TCG software emulation (slow)." >&2
[[ -f "$ISO" ]] || die "Windows ISO not found: $ISO
Save the Windows Server 2022 evaluation ISO as winvm/iso/windows-server-2022.iso
(or a symlink to it). See docs/winvm.md."

if [[ -n "${WIN_ADMIN_PASSWORD:-}" && "$WIN_ADMIN_PASSWORD" =~ [\<\>\&\"\'] ]]; then
    die "WIN_ADMIN_PASSWORD must not contain < > & \" ' (it is embedded in XML)."
fi

if [[ -d output && "${FORCE:-0}" != 1 ]]; then
    die "output/ already exists. Remove it or re-run with FORCE=1."
fi

# --- eBPF for Windows MSI (copied into the VM by Packer) ----------------------
if [[ ! -f "$EBPF_MSI" ]]; then
    mkdir -p "$(dirname "$EBPF_MSI")"
    echo "Downloading $EBPF_URL"
    curl -fL --retry 3 -o "$EBPF_MSI.part" "$EBPF_URL"
    mv "$EBPF_MSI.part" "$EBPF_MSI"
fi
echo "$EBPF_FOR_WINDOWS_MSI_SHA256  $EBPF_MSI" | sha256sum -c --quiet || die "sha256 mismatch: $EBPF_MSI"

# --- ssh key the host uses to log into the VM -------------------------------
if [[ ! -f "$KEY" ]]; then
    mkdir -p "$(dirname "$KEY")"
    ssh-keygen -q -t ed25519 -N '' -C "ebpf-win-vm" -f "$KEY"
    echo "Generated VM ssh key: $KEY"
fi

# --- build -------------------------------------------------------------------
checksum="none"
if [[ -n "${WIN_ISO_SHA256:-}" ]]; then
    checksum="sha256:${WIN_ISO_SHA256}"
elif [[ -f "$ISO.sha256" ]]; then
    checksum="sha256:$(awk '{print tolower($1); exit}' "$ISO.sha256")"
    echo "Using checksum from $ISO.sha256"
fi

args=(
    -var "iso_url=$(realpath "$ISO")"
    -var "iso_checksum=$checksum"
    -var "ssh_public_key_file=$KEY.pub"
    -var "ebpf_msi=$EBPF_MSI"
    -var "headless=${HEADLESS:-true}"
    -var "image_index=${WIN_IMAGE_INDEX:-0}"
    -var "accelerator=$ACCEL"
    -var "vm_name=$BASE_IMAGE_NAME"
)
[[ "$ACCEL" == tcg ]] && args+=(-var "cpu_model=max" -var "winrm_timeout=12h"
                                -var "qemu_binary=${QEMU:-$QEMU_DOCKER}")
[[ -n "${WIN_IMAGE_NAME:-}"     ]] && args+=(-var "image_name=$WIN_IMAGE_NAME")
[[ -n "${WIN_PRODUCT_KEY:-}"    ]] && args+=(-var "product_key=$WIN_PRODUCT_KEY")
[[ -n "${WIN_ADMIN_PASSWORD:-}" ]] && args+=(-var "admin_password=$WIN_ADMIN_PASSWORD")
[[ -n "${VM_CPUS:-}"            ]] && args+=(-var "cpus=$VM_CPUS")
[[ -n "${VM_MEMORY:-}"          ]] && args+=(-var "memory=$VM_MEMORY")
force=(); [[ "${FORCE:-0}" == 1 ]] && force=(-force)   # 'packer validate' rejects -force

packer init "$HERE/packer"
packer validate "${args[@]}" "$HERE/packer"
PACKER_LOG="${PACKER_LOG:-0}" packer build "${force[@]}" "${args[@]}" "$HERE/packer"

echo
echo "Base image ready: $HERE/output/$BASE_IMAGE_NAME"
qemu-img info "$HERE/output/$BASE_IMAGE_NAME" | sed -n '1,6p'
echo "Next: ./mingw/build.sh && ./winvm/vm.sh test"
