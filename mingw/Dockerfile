# Fixed Linux build environment for Windows targets:
#   CMake + Ninja + MinGW-w64 g++ (posix threads) + Boost for MinGW
#   + clang (bpf target) for the eBPF objects.
# Fedora is used because it ships Boost cross-built for MinGW (mingw64-boost).
# Used by mingw/build.sh; the repo is bind-mounted at /src.
FROM fedora:42

RUN dnf install -y --setopt=install_weak_deps=False \
        cmake ninja-build \
        mingw64-gcc-c++ mingw64-winpthreads-static mingw64-boost \
        clang llvm \
 && dnf clean all

WORKDIR /src
