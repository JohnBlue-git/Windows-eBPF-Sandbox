# Fixed Linux build environment for Windows targets:
#   CMake + Ninja + MinGW-w64 g++ (posix threads) + Boost for MinGW
#   + clang (bpf target) for the eBPF objects.
# Fedora is used because it ships Boost cross-built for MinGW (mingw64-boost).
# Used by mingw/build.sh; the repo is bind-mounted at /src.
# The base image is pinned by digest. dnf still installs the current Fedora 42
# packages, so CMakeLists.txt checks the GCC, Boost and clang versions.
FROM fedora:42@sha256:99e203b80b1c3d8f7e161ec10a68fd02b081ef83a3963553e513c82846b97814

RUN dnf install -y --setopt=install_weak_deps=False \
        cmake ninja-build \
        mingw64-gcc-c++ mingw64-winpthreads-static mingw64-boost \
        clang llvm \
 && dnf clean all

WORKDIR /src
