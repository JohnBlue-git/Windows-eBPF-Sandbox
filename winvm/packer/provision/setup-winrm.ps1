# Runs once at first logon (from autounattend.xml) so Packer can connect over WinRM.
# Plain HTTP + Basic auth is only reachable through QEMU's localhost port forward
# during the image build.
$ErrorActionPreference = 'Continue'

# Treat the NIC as Private so the WinRM firewall exception applies.
Get-NetConnectionProfile | ForEach-Object {
    try { Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private } catch {}
}

# Build VM housekeeping: no password expiry, no sleep/hibernate.
net accounts /maxpwage:unlimited
powercfg /hibernate off
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0

winrm quickconfig -q -force
winrm set winrm/config '@{MaxTimeoutms="7200000"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="4096"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in action=allow protocol=TCP localport=5985
Set-Service -Name WinRM -StartupType Automatic
Restart-Service -Name WinRM
