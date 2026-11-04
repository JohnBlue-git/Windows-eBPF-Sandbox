// Packer template: unattended Windows Server 2022 (Server Core) install into a
// QEMU qcow2 disk, then installs OpenSSH, turns on test signing, and installs
// the eBPF for Windows MSI (runtime drivers + JIT service). Enough to run the
// MinGW builds and load clang-built .bpf.o files (vm.sh test).
//
// Normally run through ../build-image.sh, which checks prerequisites and fills
// in the variables below.

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "Path or URL of the Windows Server 2022 ISO (evaluation or licensed)."
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "e.g. sha256:<hash>. 'none' skips verification."
}

variable "image_name" {
  type        = string
  default     = "Windows Server 2022 SERVERSTANDARDCORE"
  description = "Image name inside sources/install.wim (list with: wiminfo install.wim)."
}

variable "image_index" {
  type        = number
  default     = 0
  description = "If > 0, select the image by index instead of image_name."
}

variable "product_key" {
  type        = string
  default     = ""
  description = "Leave empty for evaluation media."
}

variable "admin_password" {
  type      = string
  default   = "EbpfWin!2026"
  sensitive = true
}

variable "ssh_public_key_file" {
  type        = string
  description = "Public key installed for Administrator so the host can ssh/scp into the VM."
}

variable "ebpf_msi" {
  type        = string
  description = "eBPF for Windows MSI on the host (downloaded and checked by build-image.sh)."
}

variable "output_dir" {
  type    = string
  default = "output"
}

variable "vm_name" {
  type    = string
  default = "ebpf-win.qcow2"
}

variable "disk_size" {
  type    = string
  default = "60G"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "accelerator" {
  type        = string
  default     = "kvm"
  description = "kvm, or tcg on hosts without hardware virtualization (much slower)."
}

variable "cpu_model" {
  type        = string
  default     = "host"
  description = "QEMU -cpu value. 'host' needs KVM; use 'max' with tcg."
}

variable "qemu_binary" {
  type        = string
  default     = "qemu-system-x86_64"
  description = "QEMU binary; build-image.sh passes QEMU 10 in Docker for tcg."
}

variable "winrm_timeout" {
  type        = string
  default     = "4h"
  description = "How long to wait for Windows Setup to finish (raise it for tcg)."
}

variable "headless" {
  type    = bool
  default = true
}

source "qemu" "windows" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  output_directory = var.output_dir
  vm_name          = var.vm_name
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_compression = true

  qemu_binary  = var.qemu_binary
  accelerator  = var.accelerator
  cpu_model    = var.cpu_model
  machine_type = "pc"
  cpus         = var.cpus
  memory       = var.memory

  // IDE disk + e1000 NIC: Windows has in-box drivers for both, so no
  // virtio-win driver ISO is needed. vm.sh must use the same devices.
  disk_interface = "ide"
  net_device     = "e1000"

  headless          = var.headless
  vnc_bind_address  = "127.0.0.1"
  vnc_port_min      = 5900
  vnc_port_max      = 5910

  // Windows Setup scans A:\ for autounattend.xml.
  floppy_content = {
    "autounattend.xml" = templatefile("${path.root}/autounattend.pkrtpl.xml", {
      admin_password = var.admin_password
      image_name     = var.image_name
      image_index    = var.image_index
      product_key    = var.product_key
    })
  }
  floppy_files = ["${path.root}/provision/setup-winrm.ps1"]

  boot_wait    = "2s"
  boot_command = ["<spacebar><wait><spacebar>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = var.winrm_timeout
  winrm_use_ssl  = false

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "30m"
}

build {
  sources = ["source.qemu.windows"]

  provisioner "file" {
    source      = var.ssh_public_key_file
    destination = "C:/Windows/Temp/host_key.pub"
  }

  provisioner "powershell" {
    scripts = ["${path.root}/provision/install-openssh.ps1"]
  }

  // eBPF for Windows drivers are test-signed, and the MSI starts them during
  // install, so test signing must be active (reboot) before the MSI runs.
  provisioner "windows-shell" {
    inline = ["bcdedit /set testsigning on"]
  }

  provisioner "windows-restart" {
    restart_timeout = "60m"
  }

  provisioner "file" {
    source      = var.ebpf_msi
    destination = "C:/Windows/Temp/ebpf-for-windows.msi"
  }

  provisioner "powershell" {
    scripts = ["${path.root}/provision/install-ebpf.ps1"]
  }
}
