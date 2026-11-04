#!/usr/bin/env bash
# Drop-in replacement for qemu-system-x86_64 that runs QEMU 10 from Docker
# (Dockerfile next to this script). vm.sh and build-image.sh use it for TCG, because the
# host's QEMU 6.2 crashes Windows Setup without KVM.
#
# The container uses the host network (VNC, ssh/WinRM forwards stay on
# 127.0.0.1) and the host user. Files are mounted at the same paths: the current
# directory, /tmp, the directory of every existing path in the arguments, and
# the backing files of every qcow2 disk.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${QEMU_DOCKER_IMAGE:-ebpf-win-qemu}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -q -t "$IMAGE" "$HERE" >&2
fi

dirs=("$PWD" /tmp)
name=ebpf-win-qemu
prev=
for arg in "$@"; do
    [[ "$prev" == -name ]] && name="ebpf-win-qemu-${arg//[^A-Za-z0-9_.-]/_}"
    prev="$arg"
    # Paths appear bare (-fda /tmp/x) or inside options (-drive file=x,...).
    for path in "$arg" ${arg//,/ }; do
        path="${path#file=}"
        [[ -e "$path" ]] || continue
        path="$(realpath "$path")"
        dirs+=("$(dirname "$path")")
        if [[ "$path" == *.qcow2 ]]; then
            while read -r backing; do dirs+=("$(dirname "$backing")"); done \
                < <(qemu-img info --backing-chain "$path" 2>/dev/null | sed -n 's/^backing file: //p')
        fi
    done
done

mounts=()
while read -r dir; do mounts+=(-v "$dir:$dir"); done < <(printf '%s\n' "${dirs[@]}" | sort -u)

# A previous run that was killed (not shut down) can leave its container behind.
docker rm -f "$name" >/dev/null 2>&1 || true

exec docker run --rm -i --name "$name" --network host \
    --user "$(id -u):$(id -g)" -w "$PWD" "${mounts[@]}" \
    "$IMAGE" qemu-system-x86_64 "$@"
