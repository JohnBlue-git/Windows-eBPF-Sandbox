# Windows VM (`winvm/`)

The VM runs the MinGW build output (`out/mingw/`) on Windows Server 2022 with
eBPF for Windows installed. See the diagrams in the
[top-level README](../README.md#how-it-fits-together) for how the pieces
connect.

## Files

```
winvm/
├── vm.sh                     every run: test / start / ssh / stop / reset / status
├── build-image.sh            one time: ISO + eBPF MSI -> output/ebpf-win.qcow2 (runs Packer)
├── common.sh                 shared by both: paths, die/log, KVM or TCG choice
├── qemu-docker/
│   ├── Dockerfile            QEMU 10 (Debian trixie)
│   └── qemu-docker.sh        drop-in qemu-system-x86_64 that runs QEMU 10 in Docker
├── packer/                   image recipe
│   ├── windows.pkr.hcl       Packer template (QEMU builder)
│   ├── autounattend.pkrtpl.xml   unattended Windows Setup answers (served on floppy A:)
│   └── provision/            run once, while Packer builds the image
│       ├── setup-winrm.ps1         first logon: enable WinRM for Packer
│       ├── install-openssh.ps1     sshd + host public key for Administrator
│       └── install-ebpf.ps1        eBPF MSI; check drivers, eBPFSvc, netsh helper
├── guest/
│   └── guest-test.ps1        copied into the VM by vm.sh test: runs all checks
│
│   local only, not in Git (see .gitignore):
├── iso/                      Windows ISO
├── downloads/                eBPF for Windows Release build zip + extracted MSI
├── output/                   base image ebpf-win.qcow2
├── keys/                     ssh key the host uses to log in to the VM
└── .run/                     per-run overlay disk, QEMU log and pid
```

## Host setup (Ubuntu/Debian)

```sh
# Docker (for mingw/ and, without KVM, for QEMU 10)
sudo apt install -y docker.io && sudo usermod -aG docker "$USER"   # log out/in

# QEMU tools (qemu-img is always used on the host)
sudo apt install -y qemu-system-x86 qemu-utils
ls -l /dev/kvm                      # optional; without it QEMU uses TCG in Docker
sudo usermod -aG kvm "$USER"        # only if /dev/kvm exists

# Packer (HashiCorp apt repo), only for build-image.sh
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y packer
```

Disk space: about 40 GB free during the image build.

## 1. Get the Windows ISO

Download **Windows Server 2022 (ISO, English, 64-bit)** from the Microsoft
Evaluation Center and save it as `winvm/iso/windows-server-2022.iso`. A symlink
also works, for example to the ISO of another project:

```sh
ln -s ~/y/Windows_CMake_Build/winvm/iso/windows-server-2022.iso winvm/iso/
```

The default image is `Windows Server 2022 SERVERSTANDARDCORE`. To use other
media, list the image names and pass the one you want:

```sh
sudo apt install -y wimtools
7z e -o/tmp/wim windows-server-2022.iso sources/install.wim && wiminfo /tmp/wim/install.wim | grep ^Name
WIN_IMAGE_NAME="Windows Server 2022 SERVERSTANDARDCORE" ./winvm/build-image.sh
```

## 2. Build the base image (once)

```sh
./winvm/build-image.sh
```

The script:

1. Downloads `Build.Release.x64.zip` of eBPF for Windows 1.7.0 (about
   380 MB) into `winvm/downloads/`, checks its sha256 and extracts
   `ebpf-for-windows.msi` from it. The version and hash come from
   `ebpf-for-windows.env` in the repository root. The standalone `.msi`
   release asset is not used, because it cannot load JIT programs (see
   [WINDOWS_DESIGN.md](WINDOWS_DESIGN.md#jit-not-native)).
2. Creates `winvm/keys/id_ed25519` if it does not exist.
3. Runs Packer: unattended Windows Setup, OpenSSH, `bcdedit /set testsigning
   on`, reboot, then the eBPF MSI. `install-ebpf.ps1` fails the build if
   `eBPFCore`, `NetEbpfExt` or `eBPFSvc` does not run.

The build runs headless. To watch it, connect a VNC viewer to the port Packer
prints (127.0.0.1:59xx). From another machine, use an ssh tunnel:
`ssh -L 5900:127.0.0.1:5900 <user>@<host>`.

ISO: `./winvm/build-image.sh [path/to/iso]`. Without an argument it uses
`$WIN_ISO`, then `winvm/iso/windows-server-2022.iso`. If `<iso>.sha256` exists
next to the ISO, Packer checks the ISO against it (`WIN_ISO_SHA256` takes
precedence).

Overrides: `WIN_ISO`, `WIN_ISO_SHA256`, `WIN_IMAGE_NAME`, `WIN_IMAGE_INDEX`,
`WIN_PRODUCT_KEY`, `WIN_ADMIN_PASSWORD`, `VM_CPUS`, `VM_MEMORY`, `HEADLESS=false`, `FORCE=1`, `PACKER_LOG=1`,
`ACCEL=kvm|tcg`, `QEMU=<binary>`.

**Without KVM**, `build-image.sh` and `vm.sh` use TCG with `-cpu max` and run
QEMU 10 from Docker through `qemu-docker/qemu-docker.sh`. The host's QEMU 6.2
(Ubuntu 22.04) crashes Windows Setup under TCG with
`SYSTEM_THREAD_EXCEPTION_NOT_HANDLED`. The first run builds the `ebpf-win-qemu`
Docker image (tag `ebpf-win-qemu`; set `QEMU_DOCKER_IMAGE` to change it).

## 3. Test a build

```sh
./mingw/build.sh                 # cross-compile -> out/mingw/
./winvm/vm.sh test               # run guest/guest-test.ps1 on out/mingw/ in the VM
```

`vm.sh test` creates a new overlay, boots the VM, copies `out/mingw/` in
(`TEST_DIR=...` to change it), runs `guest/guest-test.ps1`, and shuts the VM
down. To test several builds without a reboot each time, run `vm.sh start`
first; `test` then reuses the running VM and leaves it running.

## Interactive use

```sh
./winvm/vm.sh start              # boot (VNC=2 to also expose 127.0.0.1:5902)
./winvm/vm.sh ssh                # PowerShell in the VM
./winvm/vm.sh ssh 'netsh ebpf show programs'   # or run one command
./winvm/vm.sh status
./winvm/vm.sh stop
./winvm/vm.sh reset              # discard all changes made in the VM
```

Useful commands in the VM:

```powershell
netsh ebpf show programs
netsh ebpf show verification filename=C:\work\test\bind_policy.bpf.o section=cgroup/bind6
bpftool prog show
sc.exe query eBPFSvc
```

`vm.sh` overrides: `IMAGE`, `VM_CPUS`, `VM_MEMORY`, `SSH_PORT` (default 2223),
`VNC`, `TEST_DIR`, `ACCEL`, `QEMU`, `BOOT_TIMEOUT`, `KEEP=1` (leave the VM
running after `test`, for example to inspect a failure).

## What goes in Git and what doesn't

| In Git (small, reviewable) | Not in Git |
|---|---|
| Packer template, answer file, PowerShell scripts, shell scripts | Windows ISO (`iso/`), eBPF MSI (`downloads/`) |
| | Base image (`output/*.qcow2`) |
| | Per-run overlay (`.run/`), VM ssh key (`keys/`) |

The qcow2 is not committed: it is too large for Git, it is a copy of Windows
(evaluation media generally cannot be redistributed), and it contains the
VM's ssh public key and the Administrator password. Rebuild it with
`build-image.sh`, or share one copy on a disk. **Copy `keys/` together with
the image**: the image only accepts that key.

```sh
IMAGE=/srv/vm-images/ebpf-win.qcow2 ./winvm/vm.sh test
```

## Notes

- **Evaluation expiry:** the evaluation edition runs for 180 days. After that,
  run `build-image.sh` again (`FORCE=1`), or use a licensed ISO and
  `WIN_PRODUCT_KEY`.
- **Devices:** the VM uses an IDE disk and an e1000 NIC, so Windows needs no
  extra drivers. `vm.sh` must keep the same devices as `packer/windows.pkr.hcl`.
- **Test signing** is on in the image (needed by eBPF for Windows drivers).
  The VM boots with BIOS, so there is no Secure Boot to turn off.
- **Security:** WinRM (HTTP/Basic) and sshd are reachable only through QEMU's
  user-mode forwards on 127.0.0.1. Change the default `WIN_ADMIN_PASSWORD` if
  the image will be shared.
- **Port in use:** if another program already listens on 127.0.0.1:2223, set
  `SSH_PORT`.
