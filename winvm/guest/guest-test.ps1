# Runs inside the VM (copied there by vm.sh test). Unpacks the build output
# from mingw/build.sh and checks each sample on real Windows with eBPF for
# Windows installed. Any failed check throws, so vm.sh test fails.
$ErrorActionPreference = 'Stop'

$dir = 'C:\work\test'
$wait = 10   # seconds to let a sample start or react; generous for TCG

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
    $p = [System.Diagnostics.Process]::Start($psi)
    $p | Add-Member NoteProperty Stdout $p.StandardOutput.ReadToEndAsync()
    $p | Add-Member NoteProperty Stderr $p.StandardError.ReadToEndAsync()
    $p
}

# Press Enter, wait for exit, print and return the output.
function Stop-Redirected($p) {
    $p.StandardInput.WriteLine()
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw "$($p.StartInfo.FileName) did not stop" }
    $out = $p.Stdout.Result + $p.Stderr.Result
    Write-Host $out.TrimEnd()
    if ($p.ExitCode -ne 0) { throw "$($p.StartInfo.FileName) failed (exit $($p.ExitCode))" }
    $out
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
$p = Start-Redirected "$dir\file_change_monitor.exe" $watched
Start-Sleep $wait
Set-Content -Path "$watched\probe.txt" -Value 'hello'
Start-Sleep $wait
$out = Stop-Redirected $p
if ($out -notmatch 'added: probe.txt') { throw 'file_change_monitor did not report the new file' }

Write-Step 'etw_process_monitor.exe'
$p = Start-Redirected "$dir\etw_process_monitor.exe" ''
Start-Sleep $wait
1..3 | ForEach-Object { cmd.exe /c exit 0 }
Start-Sleep $wait
$out = Stop-Redirected $p
# Kernel-Process event 1 = ProcessStart.
if ($out -notmatch 'Kernel-Process ETW event id=1 ') { throw 'etw_process_monitor did not report a process start' }

Write-Step 'eBPF: verify bind_policy.bpf.o (both sections)'
foreach ($section in 'cgroup/bind4', 'cgroup/bind6') {
    $out = (& netsh ebpf show verification filename=bind_policy.bpf.o section=$section 2>&1) -join "`n"
    Write-Host "${section}: $out"
    if ($out -notmatch 'Program terminates within') { throw "verification failed: $section" }
}

Write-Step 'eBPF: attach cgroup/bind4 and check that binds to port 4444 are rejected'
if (-not (Test-Bind 4444)) { throw 'port 4444 is not free before the test' }
# netsh attaches the first program in the file (cgroup/bind4). The attach can
# end with the netsh process, so keep one interactive netsh open during the checks.
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
$blocked = -not (Test-Bind 4444)
$other = Test-Bind 4445
$netsh.StandardInput.WriteLine("ebpf delete program $id")
$netsh.StandardInput.WriteLine('exit')
Stop-Redirected $netsh | Out-Null
Write-Host "bind 4444 rejected: $blocked; bind 4445 allowed: $other"
if (-not $blocked) { throw 'bind to port 4444 was not rejected' }
if (-not $other) { throw 'bind to port 4445 was rejected' }

Write-Step 'eBPF: program unloaded, port 4444 free again'
for ($i = 0; $i -lt 30 -and ((& netsh ebpf show programs) -match 'bind_policy_ipv4'); $i++) { Start-Sleep 2 }
if ((& netsh ebpf show programs) -match 'bind_policy_ipv4') { throw 'bind_policy_ipv4 is still loaded' }
if (-not (Test-Bind 4444)) { throw 'port 4444 still rejected after unload' }

Write-Host "`nAll checks passed."
