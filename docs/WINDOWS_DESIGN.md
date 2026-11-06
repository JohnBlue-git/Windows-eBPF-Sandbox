# Windows Design

## Scope

This repository carries over only the Boost.Asio design from
QEMU-eBPF-Sandbox. It does not copy the Linux procedural C or custom-coroutine
implementations. The C++ samples are cross-compiled on Linux with MinGW-w64;
the eBPF program is compiled with clang; both are tested in a Windows Server
2022 VM that has eBPF for Windows installed (see [winvm.md](winvm.md)).

## Platform boundary

Boost.Asio uses IOCP on Windows. In this project the `ActionLoop` io_context
runs the logging actions and the `file_change_monitor` directory reads. The
ETW sample keeps its own thread, because `ProcessTrace` blocks until the session
stops. IOCP does not make Linux eBPF APIs or hooks portable. eBPF for Windows provides libbpf-compatible user-mode APIs and
a Windows execution environment. Program support is determined by the Windows
hooks and helpers exposed by that project. Linux-specific XDP, cgroup,
syscall-trace, and tracepoint examples must not be presented as working on
Windows without a supported Windows equivalent.

## Windows replacements for Linux hooks

| Linux example/hook | Windows eBPF status | Choice in this project |
| --- | --- | --- |
| XDP | eBPF for Windows has an XDP program type, but the provider is the separate XDP for Windows extension. | Not included. It needs another driver package and a supported NIC path. |
| cgroup socket hooks | No Linux cgroup hierarchy. `NetEbpfExt.sys` (in the core package) provides socket-address hooks (`cgroup/bind4`, `bind6`, `connect4`, `connect6`, ...). These are Windows networking hooks, not cgroup emulation. | `bpf/bind_policy.bpf.c`: reject binds to port 4444. |
| tracepoint / syscall trace | No general equivalent in eBPF for Windows. | `src/etw/`: ETW (`Microsoft-Windows-Kernel-Process`). |
| file create/write/rename/delete | No filesystem hook in eBPF for Windows. | `src/file_monitor/`: `ReadDirectoryChangesW` (notification only). Enforcement needs a Filesystem Minifilter driver. |

## eBPF runtime decisions

### Version

eBPF for Windows **1.7.0** (2026-10-16, pre-release; every release since 1.4.0
is marked pre-release). The Release build zip (`Build.Release.x64.zip`, which
contains the MSI) and the headers (source tarball of tag `v1.7.0`) are pinned
by sha256 in `ebpf-for-windows.env`. `CMakeLists.txt` and `winvm/build-image.sh` both read
the version and their hash from that file, so they cannot disagree.

### JIT, not native

eBPF for Windows can run a program in two ways:

| | JIT | Native |
|---|---|---|
| Input | ELF `.o` from clang | `.sys` driver made from the `.o` by `bpf2c` |
| Build needs | clang only (runs on Linux) | MSVC + WDK, then driver signing |
| Load | `eBPFSvc` verifies and JIT-compiles | the driver loads like any driver |
| Status | Microsoft says JIT is available on pre-release versions only | the production path |

This project uses **JIT**: the `.o` builds in the Linux container and loads with
`netsh ebpf add program`, so the VM needs no Visual Studio.

Each release has two MSIs, and only one of them can load JIT programs:

| MSI | Build configuration | `eBPFCore.sys` |
|---|---|---|
| `ebpf-for-windows.x64.1.7.0.msi` (release asset) | `NativeOnlyRelease` | No JIT or interpreter. Loading a `.o` fails: `netsh` prints `error 129: could not load program` (`ENOTSUP`). |
| `Build Release x64/ebpf-for-windows.msi` inside `Build.Release.x64.zip` | `Release` | Includes uBPF (JIT). |

`winvm/build-image.sh` therefore downloads `Build.Release.x64.zip` and installs
the MSI from it. In that MSI, `eBPFSvc` (JIT) is part of
`eBPF_Runtime_Components`; there is no separate JIT feature. If a future
release stops publishing a `Release` build, the native path needs an MSVC + WDK
build step (in the VM or on a Windows machine).

### Test signing

The eBPF for Windows drivers (`eBPFCore.sys`, `NetEbpfExt.sys`) are not
Microsoft-signed. Microsoft's VM setup turns Secure Boot off and runs
`bcdedit -set TESTSIGNING ON`, then reboots. The image build does the same
(BIOS VM: no Secure Boot) before it installs the MSI, because the MSI starts
the drivers during install.

### Dependencies in the VM

The MSI tools link the C runtime statically and import only the Universal CRT
(`api-ms-win-crt-*`), which Windows Server 2022 includes. No Visual C++
redistributable is needed. The MSI installs `netsh ebpf` (`ebpfnetsh.dll`),
`bpftool.exe`, `bpf2c.exe` and `export_program_info.exe` and adds the
install folder to `PATH`.

### Loading

`netsh ebpf add program filename=<file>` loads all programs in the file and
attaches the **first** one (`cgroup/bind4` here). The attach can end with the
`netsh` process, so `guest-test.ps1` keeps one interactive `netsh` open while it
checks binds. `cgroup/bind6` is checked with `netsh ebpf show verification`
(verifier only). At the end, the test deletes both loaded programs
(`bind_policy_ipv4` and `bind_policy_ipv6`) and checks that neither is listed.

A C++ loader (libbpf API from `EbpfApi.dll`) is not part of this project yet.
Its headers are written for MSVC; whether MinGW can link against it has not
been tested.

## Samples

- `bpf/bind_policy.bpf.c` uses `BPF_PROG_TYPE_CGROUP_SOCK_ADDR` bind attach
  types and rejects port 4444 for IPv4 and IPv6. It demonstrates a Windows
  socket policy, not cgroup grouping.
- `etw_process_monitor` consumes the `Microsoft-Windows-Kernel-Process` ETW
  provider and hands event metadata to `ActionLoop`. It logs event ID, opcode,
  and the header process/thread IDs (`header_pid`, `header_tid`); it does not
  decode provider-specific payloads. The header IDs are the process that
  logged the event: for ProcessStart (id 1) that is the creating process, not
  the new one. Run it elevated.
- `file_change_monitor` reports completed changes through
  `ReadDirectoryChangesW`, run as overlapped I/O on the `ActionLoop` IOCP. It
  watches the whole directory tree and reports name changes (create, delete,
  rename) and size, attribute and last-write changes. It cannot block, deny or roll back a change. For
  pre-operation allow/deny decisions, use a Filesystem Minifilter driver (WDK)
  and a Filter Manager communication port to an Asio user-mode service. See
  [file system minifilter drivers](https://learn.microsoft.com/windows-hardware/drivers/ifs/about-file-system-filter-drivers)
  and
  [communication between user mode and kernel mode](https://learn.microsoft.com/windows-hardware/drivers/ifs/communication-between-user-mode-and-kernel-mode).

## Build environment

`mingw/Dockerfile` (Fedora 42) provides CMake 3.31, Ninja, MinGW-w64 GCC 14
(posix threads), `mingw64-boost` 1.78 and clang 20. Fedora is used because it
ships Boost cross-built for MinGW. The base image is pinned by digest, but
`dnf` installs the current Fedora 42 packages, so `CMakeLists.txt` stops with
an error if the GCC major, Boost or clang major version differs. Boost 1.78 `asio/awaitable.hpp` uses
`std::exchange` without including `<utility>`; GCC 14 needs it, so
`CMakeLists.txt` adds `-include utility` for GCC.

The executables link the GCC runtime statically and import only Windows system
DLLs.

## References

- [eBPF for Windows](https://github.com/microsoft/ebpf-for-windows)
- [Install eBPF for Windows](https://github.com/microsoft/ebpf-for-windows/blob/main/docs/InstallEbpf.md)
- [VM setup (test signing)](https://github.com/microsoft/ebpf-for-windows/blob/main/docs/vm-setup.md)
- [Getting Started](https://github.com/microsoft/ebpf-for-windows/blob/main/docs/GettingStarted.md)
- [Original Boost.Asio design](https://github.com/JohnBlue-git/QEMU-eBPF-Sandbox/blob/main/docs/BOOST_ASIO_DESIGN.md)
