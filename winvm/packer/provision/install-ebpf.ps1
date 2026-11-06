# Installs eBPF for Windows from the MSI that Packer uploaded, then checks that
# the drivers and the JIT service run. Needs test signing to be active already
# (windows.pkr.hcl turns it on and reboots before this script).
$ErrorActionPreference = 'Stop'

if (-not ((bcdedit /enum '{current}') -match 'testsigning\s+Yes')) { throw 'test signing is not active' }

# In this MSI the JIT service (eBPFSvc) is part of eBPF_Runtime_Components.
$msi = 'C:\Windows\Temp\ebpf-for-windows.msi'
$log = 'C:\Windows\Temp\ebpf-install.log'
$installer = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
    '/i', $msi, '/qn', '/norestart', '/l*v', $log,
    'INSTALLFOLDER="C:\Program Files\ebpf-for-windows"', 'ADDLOCAL=eBPF_Runtime_Components')
if ($installer.ExitCode -ne 0 -and $installer.ExitCode -ne 3010) {
    Get-Content $log -Tail 40
    throw "eBPF MSI failed: $($installer.ExitCode)"
}
Remove-Item $msi -Force

foreach ($name in 'eBPFCore', 'NetEbpfExt', 'eBPFSvc') {
    $state = (sc.exe query $name | Select-String 'STATE').ToString()
    Write-Host "${name}: $state"
    if ($state -notmatch 'RUNNING') { throw "$name is not running" }
}
# The MSI adds its folder (with ebpfnetsh.dll) to the machine PATH; this session
# started before that, so reload PATH for netsh to find the helper DLL.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
& netsh ebpf show programs
if ($LASTEXITCODE -ne 0) { throw 'netsh ebpf helper is not working' }
Write-Host 'eBPF for Windows installed.'
