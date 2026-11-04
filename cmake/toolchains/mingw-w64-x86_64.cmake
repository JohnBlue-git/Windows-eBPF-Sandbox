# Cross-compile for 64-bit Windows with MinGW-w64 on a Linux host (Fedora
# mingw64-* packages, as installed by mingw/Dockerfile).
#
#   cmake -S . -B build/mingw -G Ninja \
#         -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/mingw-w64-x86_64.cmake
#
# Fedora's MinGW GCC uses the posix thread model, so std::thread works. The GCC
# runtime (libgcc, libstdc++, libwinpthread) is linked statically, so the EXEs
# run on a clean Windows without extra DLLs next to them.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(MINGW_TRIPLE x86_64-w64-mingw32)
set(CMAKE_C_COMPILER   ${MINGW_TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER ${MINGW_TRIPLE}-g++)
set(CMAKE_RC_COMPILER  ${MINGW_TRIPLE}-windres)

# Boost and the other mingw64-* libraries live here.
set(CMAKE_FIND_ROOT_PATH /usr/${MINGW_TRIPLE}/sys-root/mingw)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)   # host clang compiles the eBPF objects
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
