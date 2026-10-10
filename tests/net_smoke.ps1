# Two-process online smoke test on one PC (localhost). Usage:
#   powershell -File tests\net_smoke.ps1 [-Runs 1]
# Starts a scripted host and client, then checks both print identical FINAL states.
param(
    [string]$Godot = "D:\Godot\Godot_v4.7.2-stable_win64_console.exe",
    [string]$Project = "D:\TOPDOWNRON",
    [int]$Runs = 1
)

$out = Join-Path $env:TEMP "topdownron_net"
New-Item -ItemType Directory -Force $out | Out-Null
$failed = 0

for ($i = 1; $i -le $Runs; $i++) {
    $hostOut = "$out\host_$i.txt"; $clientOut = "$out\client_$i.txt"
    $h = Start-Process $Godot -ArgumentList "--headless", "--path", $Project, "--", "--auto-host" `
        -RedirectStandardOutput $hostOut -RedirectStandardError "$out\host_$i.err" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $c = Start-Process $Godot -ArgumentList "--headless", "--path", $Project, "--", "--auto-join" `
        -RedirectStandardOutput $clientOut -RedirectStandardError "$out\client_$i.err" -PassThru -WindowStyle Hidden
    $okH = $h.WaitForExit(40000); $okC = $c.WaitForExit(40000)
    if (-not $okH) { $h.Kill() }
    if (-not $okC) { $c.Kill() }

    $hf = (Select-String -Path $hostOut -Pattern "FINAL" -ErrorAction SilentlyContinue | Select-Object -Last 1).Line -replace '^\[\d+\] ', ''
    $cf = (Select-String -Path $clientOut -Pattern "FINAL" -ErrorAction SilentlyContinue | Select-Object -Last 1).Line -replace '^\[\d+\] ', ''
    $rtt = (Select-String -Path $clientOut -Pattern "rtt=" -ErrorAction SilentlyContinue | Select-Object -Last 3 | ForEach-Object { $_.Line }) -join "; "
    if ($hf -and $hf -eq $cf) {
        Write-Output "run $i PASS  $hf"
    } else {
        Write-Output "run $i FAIL  host=[$hf] client=[$cf] exited=$okH/$okC"
        $failed++
    }
    Write-Output "        client rtt: $rtt"
}
Write-Output "logs: $out"
exit $failed
