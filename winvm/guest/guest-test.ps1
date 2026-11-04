# Runs inside the VM (copied there by vm.sh test). Unpacks the build output
# from mingw/build.sh and checks each sample on real Windows with eBPF for
# Windows installed. Any failed check throws, so vm.sh test fails.
$ErrorActionPreference = 'Stop'

$dir = 'C:\work\test'
$wait = 10   # seconds to let a sample start or react; generous for TCG
$blockedPort = 4444                  # BLOCKED_PORT in bpf/bind_policy.bpf.c
$allowedPort = $blockedPort + 1

Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dir | Out-Null
tar -xf "$HOME\test.tar" -C $dir
if ($LASTEXITCODE -ne 0) { throw 'failed to unpack test files' }
Set-Location $dir

function Write-Step($text) { Write-Host "`n--- $text" }

# Start a program with stdin/stdout/stderr redirected. The monitors stop on Enter.
function Start-Redirected($file, $arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $file, $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc | Add-Member NoteProperty Stdout $proc.StandardOutput.ReadToEndAsync()
    $proc | Add-Member NoteProperty Stderr $proc.StandardError.ReadToEndAsync()
    $proc
}

# Press Enter, wait for exit, print and return the output.
function Stop-Redirected($proc) {
    $proc.StandardInput.WriteLine()
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit(120000)) { $proc.Kill(); throw "$($proc.StartInfo.FileName) did not stop" }
    $out = $proc.Stdout.Result + $proc.Stderr.Result
    Write-Host $out.TrimEnd()
    if ($proc.ExitCode -ne 0) { throw "$($proc.StartInfo.FileName) failed (exit $($proc.ExitCode))" }
    $out
}

# Program IDs of the loaded bind_policy programs (bind4 and bind6).
function Get-BindPolicyIds {
    (& netsh ebpf show programs) -match 'bind_policy_ipv[46]' | ForEach-Object { ($_.Trim() -split '\s+')[0] }
}

function Test-Bind([int]$port) {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any), $port
    try { $listener.Start(); $true } catch { $false } finally { $listener.Stop() }
}

Write-Step 'asio_smoke_test.exe'
$out = & .\asio_smoke_test.exe
Write-Host $out
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'Boost.Asio action completed') { throw 'asio_smoke_test failed' }

Write-Step 'file_change_monitor.exe'
$watched = 'C:\work\watched'
Remove-Item -Recurse -Force $watched -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $watched | Out-Null
$monitor = Start-Redirected "$dir\file_change_monitor.exe" $watched
Start-Sleep $wait
Set-Content -Path "$watched\probe.txt" -Value 'hello'
Start-Sleep $wait
$out = Stop-Redirected $monitor
if ($out -notmatch 'added: probe.txt') { throw 'file_change_monitor did not report the new file' }

Write-Step 'etw_process_monitor.exe'
$monitor = Start-Redirected "$dir\etw_process_monitor.exe" ''
Start-Sleep $wait
1..3 | ForEach-Object { cmd.exe /c exit 0 }
Start-Sleep $wait
$out = Stop-Redirected $monitor
# Kernel-Process event 1 = ProcessStart.
if ($out -notmatch 'Kernel-Process ETW event id=1 ') { throw 'etw_process_monitor did not report a process start' }

Write-Step 'eBPF: verify bind_policy.bpf.o (both sections)'
foreach ($section in 'cgroup/bind4', 'cgroup/bind6') {
    $out = (& netsh ebpf show verification filename=bind_policy.bpf.o section=$section 2>&1) -join "`n"
    Write-Host "${section}: $out"
    if ($out -notmatch 'Program terminates within') { throw "verification failed: $section" }
}

Write-Step "eBPF: attach cgroup/bind4 and check that binds to port $blockedPort are rejected"
if (-not (Test-Bind $blockedPort)) { throw "port $blockedPort is not free before the test" }
# netsh loads all programs in the file and attaches the first one (cgroup/bind4).
# The attach can end with the netsh process, so keep one interactive netsh open
# during the checks.
$netsh = Start-Redirected 'netsh.exe' ''
$netsh.StandardInput.WriteLine("ebpf add program filename=$dir\bind_policy.bpf.o")
$id = $null
for ($i = 0; $i -lt 60 -and -not $id; $i++) {
    Start-Sleep 2
    $line = (& netsh ebpf show programs) -match 'bind_policy_ipv4'
    if ($line) { $id = ($line[0].Trim() -split '\s+')[0] }
}
if (-not $id) { Stop-Redirected $netsh | Out-Null; throw 'bind_policy_ipv4 did not load' }
& netsh ebpf show programs
$blocked = -not (Test-Bind $blockedPort)
$other = Test-Bind $allowedPort
foreach ($loadedId in Get-BindPolicyIds) { $netsh.StandardInput.WriteLine("ebpf delete program $loadedId") }
$netsh.StandardInput.WriteLine('exit')
Stop-Redirected $netsh | Out-Null
Write-Host "bind $blockedPort rejected: $blocked; bind $allowedPort allowed: $other"
if (-not $blocked) { throw "bind to port $blockedPort was not rejected" }
if (-not $other) { throw "bind to port $allowedPort was rejected" }

Write-Step "eBPF: bind4 and bind6 programs unloaded, port $blockedPort free again"
for ($i = 0; $i -lt 30 -and (Get-BindPolicyIds); $i++) { Start-Sleep 2 }
& netsh ebpf show programs
if (Get-BindPolicyIds) { throw 'a bind_policy program is still loaded' }
if (-not (Test-Bind $blockedPort)) { throw "port $blockedPort still rejected after unload" }

Write-Host "`nAll checks passed."
