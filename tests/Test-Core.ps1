# Self-test of the Windows watchdog logic with fake time and fake repairs. Needs no admin and changes nothing.
#   powershell -ExecutionPolicy Bypass -File tests\Test-Core.ps1        (exit code 0 = all passed)
$ErrorActionPreference = 'Stop'
$env:NETREFRESH_DATA = Join-Path ([IO.Path]::GetTempPath()) ('nr-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force $env:NETREFRESH_DATA | Out-Null
. (Join-Path $PSScriptRoot '..\NetRefresh.ps1') -Library

$script:failed = 0
function Assert($cond, $what) {
    if ($cond) { Write-Host "PASS  $what" } else { Write-Host "FAIL  $what" -ForegroundColor Red; $script:failed++ }
}

# keep the real ones for the tests that need them, then replace everything that touches the system
$realLog = ${function:Log}; $realTestInternet = ${function:Test-Internet}; $realDaily = ${function:Invoke-Daily}
$script:actions = New-Object Collections.ArrayList
$script:health = 'ok'; $script:cause = 'x'; $script:beats = 0
function Get-Health { $script:health }
function Diagnose($h) { $script:cause }
function Invoke-Action($a) { [void]$script:actions.Add($a); $true }
function Notify($t, $m) { }
function Log($m) { }
function Test-Internet { $script:health -eq 'ok' }
function Send-Heartbeat { $script:beats++ }

$T0 = [datetime]'2026-11-16T05:30:00'
function New-Run([hashtable]$set = @{}) {
    Remove-Item $cfg, $statef, $csv -ErrorAction SilentlyContinue
    Load-Settings; Load-State
    foreach ($k in $set.Keys) { $script:S.$k = $set[$k] }
    $script:outs = New-Object Collections.ArrayList
    $script:cur = $null; $script:stage = 0; $script:fails = 0; $script:lastBeat = [datetime]::MinValue; $script:beats = 0
    $script:actions.Clear(); $script:t = $T0; $script:health = 'ok'
}
function Advance([int]$seconds) { for ($i = 0; $i -lt $seconds / 10; $i++) { $script:t = $script:t.AddSeconds(10); Check-Health $script:t } }
$local = 'No default gateway (DHCP lease lost)'
$isp = 'Router OK but no internet (ISP/WAN drop or router reconnect)'
$router = 'Router unreachable (LAN side)'
$plug = @{ plugType = 'shelly2'; plugHost = '192.168.1.50' }

# --- ladder ---
New-Run; $script:health = 'internet'; $script:cause = $local; Advance 20; $script:health = 'ok'; Advance 10
Assert ($script:outs.Count -eq 0 -and $script:actions.Count -eq 0) 'a 20-second blip is not an outage'

New-Run; $script:health = 'internet'; $script:cause = $local; Advance 1500
Assert (($script:actions -join ',') -eq 'adapter restart,device restart,reboot') 'local fault: adapter restart, device restart, reboot (once each)'
Assert ($script:outs[0].Fix -eq 'reboot') 'the history says it ended in a reboot'

New-Run @{ reboot = $false }; $script:health = 'internet'; $script:cause = $local; Advance 1500
Assert ($script:actions -notcontains 'reboot') 'no reboot when the last-resort reboot is switched off'

New-Run; $script:St.lastReboot = $T0.AddHours(-1); $script:health = 'internet'; $script:cause = $local; Advance 1500
Assert ($script:actions -notcontains 'reboot') 'no reboot within 3 h of the last one'

New-Run; $script:health = 'internet'; $script:cause = $isp; Advance 1500
Assert ($script:actions.Count -eq 0) 'ISP outage without a plug: nothing on the PC is reset, no reboot'

New-Run $plug; $script:health = 'internet'; $script:cause = $isp; Advance 1500
Assert (($script:actions -join ',') -eq 'router power-cycle') 'ISP outage with a plug: only the router is power-cycled'

New-Run $plug; $script:health = 'internet'; $script:cause = $isp; Advance 400; $script:health = 'ok'; Advance 30; $script:health = 'internet'; Advance 400
Assert (($script:actions -join ',') -eq 'router power-cycle') 'a second power-cycle within 30 min is refused'

New-Run $plug; $script:St.plugTimes = @($T0.AddHours(-5), $T0.AddHours(-3), $T0.AddHours(-1)); $script:health = 'internet'; $script:cause = $isp; Advance 400
Assert ($script:actions.Count -eq 0) 'no more than 3 power-cycles in 24 h'

New-Run; $script:health = 'internet'; $script:cause = $router; Advance 1000
Assert (($script:actions -join ',') -eq 'adapter restart,device restart,reboot') 'router unreachable, no plug: device restart instead of a power-cycle'

New-Run $plug; $script:health = 'internet'; $script:cause = $router; Advance 1000
Assert (($script:actions -join ',') -eq 'adapter restart,router power-cycle,reboot') 'router unreachable with a plug: power-cycle at 5 min'

New-Run; $script:health = 'dns'; $script:cause = 'Internet OK but DNS failing (router DNS)'; Advance 1500
Assert (($script:actions -join ',') -eq 'flush DNS,renew lease') 'DNS failure: flush, then renew; never a reboot'

New-Run; $script:health = 'crd'; $script:cause = 'Internet OK but Chrome Remote Desktop service is not running (remote access)'; Advance 1500
Assert (($script:actions -join ',') -eq 'restart service,restart service') 'remote tool down: the service is restarted, nothing else'

New-Run; $script:health = 'tslogin'; $script:cause = 'Tailscale LOGGED OUT - sign in from the Tailscale tray icon (restarts cannot fix this)'; Advance 1500
Assert ($script:actions.Count -eq 0) 'Tailscale logged out: nothing is restarted'

New-Run; $script:health = 'internet'; $script:cause = $local; Advance 100; $script:cause = $isp; Advance 1400
Assert (($script:actions -join ',') -eq 'adapter restart') 'the cause is re-checked: once it is the ISP, local repairs stop'

New-Run; $script:health = 'internet'; $script:cause = $local; Advance 130; $script:health = 'ok'; Advance 10
$row = (Load-Outs $false)[0]
Assert ($row.Fix -eq 'adapter restart' -and $row.End -and $row.Start -eq $T0.AddSeconds(10)) 'recovery: saved with the last repair and the time of the FIRST failed check'

# --- heartbeat, plug rules, probes ---
New-Run @{ heartbeatUrl = 'https://hc-ping.com/x' }; Advance 610
Assert ($script:beats -eq 3) 'heartbeat on the first good check, then every 5 min (3 in 10 min)'

New-Run @{ plugType = 'shelly2'; plugHost = '192.168.1.50; rm' }
Assert (-not (Get-PlugUrl)) 'a plug address with odd characters is refused'
New-Run @{ plugType = 'tasmota'; plugHost = '10.0.0.7' }
Assert ((Get-PlugUrl) -eq 'http://10.0.0.7/cm?cmnd=Backlog%20Power1%20Off%3BDelay%20300%3BPower1%20On') 'Tasmota command switches itself back on after 30 s'

function Ping($h, $ms) { $false }
function Test-Tcp($h, $port, $ms) { $port -eq 443 }
Assert (& $realTestInternet) 'internet counts as up when ping is blocked but port 443 answers'
function Test-Tcp($h, $port, $ms) { $false }
Assert (-not (& $realTestInternet)) 'and as down when neither works'

# --- classes, pattern, report, files ---
Assert ((Get-CauseClass 'Ethernet link down (cable/NIC/driver)') -eq 'local') 'old history rows still map to a class'
Assert ((Get-CauseClass $isp) -eq 'isp' -and (Get-CauseClass $router) -eq 'router') 'ISP and router causes are told apart'

$days = foreach ($d in 1..3) { [pscustomobject]@{ Start = $T0.AddDays(-$d); End = $T0.AddDays(-$d).AddMinutes(20); Cause = $isp; Fix = '' } }
$p = Get-DailyPattern $days $T0
Assert ($p -and $p.Hour -eq 5 -and $p.Days -eq 3) 'a drop around 05:00 on 3 days is reported as a daily pattern'
Assert (-not (Get-DailyPattern @($days[0], $days[1]) $T0)) 'two days are not a pattern'

$mixed = @($days) + [pscustomobject]@{ Start = $T0.AddDays(-4); End = $T0.AddDays(-4).AddMinutes(50); Cause = $local; Fix = '' }
$rep = New-IspReport $mixed $T0
Assert ($rep -match 'ISP-side problem\): 3, 60 minutes' -and $rep -match 'All outages in the period: 4') 'ISP report counts only ISP-side outages (3, 60 min) out of 4'

Set-Content $csv "`"Start`",`"End`",`"Cause`",`"Fix`"`r`n`"garbage`",`"`",`"x`",`"`"`r`n`"2026-11-16T05:00:00`",`"`",`"$local`",`"adapter restart`""
$rows = Load-Outs $true
Assert ($rows.Count -eq 1 -and $rows[0].End -and $rows[0].Fix -eq 'watchdog restarted') 'a damaged row is skipped; an open row is closed on start'

& $realLog 'message with {braces} and {0}'
Assert ((Get-Content $logf -Raw) -match '\{braces\} and \{0\}') 'log lines with { } are written, not lost'

Set-Content $cfg '{"ntfy":"abc def/../x","time":"25:99","plugType":"evil"}'
Load-Settings
Assert ($script:S.ntfy -eq 'abcdefx' -and $script:S.time -eq '06:15' -and $script:S.plugType -eq '') 'a hand-edited settings file is cleaned on load'

# --- daily action guard ---
$script:did = @()
function Reset-Soft { $script:did += 'soft' }
function Exec($f, $a) { $script:did += "exec:$f"; 0 }
New-Run @{ fullRestart = $true }; $script:St.lastReboot = $T0.AddMinutes(-5)
& $realDaily $T0
Assert ($script:did -contains 'soft' -and $script:did -notcontains 'exec:shutdown') 'daily full restart is skipped right after a restart (no loop)'
$script:did = @(); $script:St.lastReboot = [datetime]::MinValue
& $realDaily $T0
Assert ($script:did -contains 'exec:shutdown') 'daily full restart runs otherwise'

Remove-Item $env:NETREFRESH_DATA -Recurse -Force
Write-Host ''
if ($script:failed) { Write-Host "$script:failed test(s) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'All tests passed' }
