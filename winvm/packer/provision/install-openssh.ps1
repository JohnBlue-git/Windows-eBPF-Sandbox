# Installs Win32-OpenSSH server so the host can ssh/scp into the VM (used by vm.sh).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$version = 'v9.5.0.0p1-Beta'
$msi = 'C:\Windows\Temp\OpenSSH-Win64.msi'
Invoke-WebRequest -Uri "https://github.com/PowerShell/Win32-OpenSSH/releases/download/$version/OpenSSH-Win64-v9.5.0.0.msi" -OutFile $msi
$p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', '/norestart') -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "OpenSSH MSI failed: $($p.ExitCode)" }
Remove-Item $msi -Force

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd   # first start generates host keys and C:\ProgramData\ssh

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# PowerShell as the remote shell.
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

# Administrator logs in with the host's public key (uploaded by Packer).
$authKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
Get-Content 'C:\Windows\Temp\host_key.pub' | Set-Content -Encoding ascii $authKeys
icacls.exe $authKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
Remove-Item 'C:\Windows\Temp\host_key.pub' -Force

Restart-Service sshd
Write-Host 'OpenSSH server installed.'
