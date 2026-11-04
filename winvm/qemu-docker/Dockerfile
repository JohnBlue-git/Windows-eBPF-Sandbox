# Newer QEMU for hosts without KVM. QEMU 6.2 (Ubuntu 22.04) crashes Windows
# Setup under TCG (SYSTEM_THREAD_EXCEPTION_NOT_HANDLED); QEMU 10 does not.
# Used by winvm/qemu-docker/qemu-docker.sh.
FROM debian:trixie-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        qemu-system-x86 qemu-utils \
 && rm -rf /var/lib/apt/lists/*
