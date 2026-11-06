cmake_minimum_required(VERSION 3.24)
project(windows_ebpf_sandbox LANGUAGES CXX)

include(FetchContent)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Threads REQUIRED)
# Header-only Asio. The mingw/ container provides Boost (Fedora mingw64-boost).
find_package(Boost 1.78 CONFIG REQUIRED)

# --- Boost.Asio action loop + smoke test --------------------------------------
add_library(action_loop STATIC src/actions/ActionLoop.cpp)
target_include_directories(action_loop PUBLIC src/actions)
target_link_libraries(action_loop PUBLIC Boost::headers Threads::Threads)
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    # Boost 1.78 asio/awaitable.hpp uses std::exchange without <utility>;
    # GCC 14 no longer pulls it in indirectly.
    target_compile_options(action_loop PUBLIC -include utility)
endif()
if(WIN32)
    target_link_libraries(action_loop PUBLIC ws2_32 mswsock)
    target_compile_definitions(action_loop PUBLIC _WIN32_WINNT=0x0A00 WINVER=0x0A00 WIN32_LEAN_AND_MEAN)
endif()

add_executable(asio_smoke_test src/actions/main.cpp)
target_link_libraries(asio_smoke_test PRIVATE action_loop)

# --- Windows-only samples -------------------------------------------------------
if(WIN32)
    add_executable(file_change_monitor
        src/file_monitor/DirectoryWatcher.cpp
        src/file_monitor/main.cpp
    )
    target_include_directories(file_change_monitor PRIVATE src/file_monitor)
    target_link_libraries(file_change_monitor PRIVATE action_loop)

    add_executable(etw_process_monitor
        src/etw/KernelProcessWatcher.cpp
        src/etw/main.cpp
    )
    target_include_directories(etw_process_monitor PRIVATE src/etw)
    target_link_libraries(etw_process_monitor PRIVATE action_loop advapi32 ole32)

    if(MINGW)
        # Both samples use wmain().
        target_link_options(file_change_monitor PRIVATE -municode)
        target_link_options(etw_process_monitor PRIVATE -municode)
    endif()
endif()

foreach(target asio_smoke_test file_change_monitor etw_process_monitor)
    if(TARGET ${target})
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
        set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
    endif()
endforeach()

# --- eBPF programs (ELF objects, loaded in the VM by netsh through the JIT) --------
# Headers come from the same eBPF for Windows release that winvm/ installs:
# both read the version and hashes from ebpf-for-windows.env.
set(EBPF_PIN_FILE "${CMAKE_CURRENT_SOURCE_DIR}/ebpf-for-windows.env")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${EBPF_PIN_FILE}")
file(STRINGS "${EBPF_PIN_FILE}" ebpf_pins REGEX "^[A-Z0-9_]+=")
foreach(pin IN LISTS ebpf_pins)
    string(REGEX MATCH "^([A-Z0-9_]+)=(.*)$" pin_match "${pin}")
    set(${CMAKE_MATCH_1} "${CMAKE_MATCH_2}")
endforeach()

FetchContent_Declare(ebpf_for_windows
    URL "https://github.com/microsoft/ebpf-for-windows/archive/refs/tags/v${EBPF_FOR_WINDOWS_VERSION}.tar.gz"
    URL_HASH SHA256=${EBPF_FOR_WINDOWS_SOURCE_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    # Headers only: point at a directory without CMakeLists.txt so the
    # upstream project is not added to this build.
    SOURCE_SUBDIR include
)
FetchContent_MakeAvailable(ebpf_for_windows)

find_program(BPF_CLANG_EXECUTABLE NAMES clang REQUIRED)

if(MINGW)
    # The mingw/ container toolchain that docs/WINDOWS_DESIGN.md documents.
    # Other versions are not tested (for example the -include utility workaround above).
    execute_process(COMMAND "${BPF_CLANG_EXECUTABLE}" -dumpversion
        OUTPUT_VARIABLE BPF_CLANG_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT CMAKE_CXX_COMPILER_VERSION MATCHES "^14\\."
       OR NOT Boost_VERSION VERSION_EQUAL 1.78
       OR NOT BPF_CLANG_VERSION MATCHES "^20\\.")
        message(FATAL_ERROR
            "Expected MinGW-w64 GCC 14, Boost 1.78 and clang 20 (mingw/Dockerfile); found "
            "GCC ${CMAKE_CXX_COMPILER_VERSION}, Boost ${Boost_VERSION}, clang ${BPF_CLANG_VERSION}.")
    endif()
endif()

set(BPF_OUTPUT_DIR "${CMAKE_BINARY_DIR}/bin")
set(BIND_POLICY_OBJECT "${BPF_OUTPUT_DIR}/bind_policy.bpf.o")

add_custom_command(
    OUTPUT "${BIND_POLICY_OBJECT}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${BPF_OUTPUT_DIR}"
    COMMAND "${BPF_CLANG_EXECUTABLE}" -target bpf -O2 -g -Werror -ffreestanding
        "-I${ebpf_for_windows_SOURCE_DIR}/include"
        -c "${CMAKE_CURRENT_SOURCE_DIR}/bpf/bind_policy.bpf.c"
        -o "${BIND_POLICY_OBJECT}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/bpf/bind_policy.bpf.c"
    COMMENT "Compiling eBPF for Windows bind policy"
    VERBATIM
)
add_custom_target(ebpf_programs ALL DEPENDS "${BIND_POLICY_OBJECT}")
