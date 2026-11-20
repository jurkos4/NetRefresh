param([switch]$Probe, [switch]$Preview, [switch]$Boot, [switch]$Service, [switch]$Library)
# NetRefresh: keeps a remote-access PC online. A watchdog checks the connection every 10 s and repairs it according to
# the CAUSE it finds; it runs as a Windows service (-Service) or inside the window. History, graph, setup check,
# router smart-plug power-cycle, heartbeat and phone alerts.
#   -Service   headless watchdog loop (NetRefresh.exe --service runs this as the Windows service)
#   -Preview   no admin needed, separate data folder: for trying the window, nothing real is repaired
#   -Library   only define the functions (used by tests\Test-Core.ps1)
#   -Probe     print what the health check sees right now

# ---------- paths ----------
$appDir = if ($ExeDir) { $ExeDir } else { $PSScriptRoot }   # $ExeDir/$ExePath/$StopEvent are set by NetRefresh.exe
$dataDir = if ($env:NETREFRESH_DATA) { $env:NETREFRESH_DATA } elseif ($Preview) { Join-Path $appDir 'preview-data' } else { Join-Path $env:ProgramData 'NetRefresh' }
$installDir = Join-Path $env:ProgramFiles 'NetRefresh'
$csv = Join-Path $dataDir 'outages.csv'
$cfg = Join-Path $dataDir 'settings.json'
$statef = Join-Path $dataDir 'state.json'
$logf = Join-Path $dataDir 'netrefresh.log'
$AuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $script:tsExe)) { $script:tsExe = $null }
$ProbeHosts = '1.1.1.1', '8.8.8.8'

# Seconds into an outage at which each repair stage runs, and which repair fits which cause.
# Nothing on this PC can fix an ISP outage, so it never resets the PC's network or reboots for one.
$Stages = 90, 300, 900
$Plan = @{
    local   = 'adapter restart', 'device restart', 'reboot'
    router  = 'adapter restart', 'router power-cycle', 'reboot'
    isp     = $null, 'router power-cycle', $null
    dns     = 'flush DNS', 'renew lease', $null
    remote  = 'restart service', 'restart service', $null
    tslogin = $null, $null, $null
}

# ---------- log, settings, state, history ----------
function Log($m) {
    $line = '[' + (Get-Date).ToString('dd.MM HH:mm:ss') + '] ' + $m   # no -f: a message with { } must not break logging
    for ($i = 0; $i -lt 3; $i++) { try { [IO.File]::AppendAllText($logf, $line + "`r`n"); break } catch { Start-Sleep -Milliseconds 50 } }
}

function Save-Json($obj, $path) {   # write to a temp file, then swap: a crash can never leave half a file
    $tmp = "$path.tmp"
    $obj | ConvertTo-Json -Depth 4 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $path -Force
}

$Defaults = [ordered]@{
    time = '06:15'; armed = $false; reboot = $true; fullRestart = $false; watchCrd = $null; watchTs = $false
    keepAwake = $true; tray = $false; ntfy = ''; launch = ''; updGuardUntil = ''; heartbeatUrl = ''; plugType = ''; plugHost = ''
}
function Load-Settings {
    $j = $null
    if (Test-Path $cfg) { try { $j = Get-Content $cfg -Raw | ConvertFrom-Json } catch { $j = $null } }
    $s = [ordered]@{}
    foreach ($k in $Defaults.Keys) {
        $s[$k] = if ($j -and ($j.PSObject.Properties.Name -contains $k) -and $null -ne $j.$k) { $j.$k } else { $Defaults[$k] }
    }
    if ($null -eq $s.watchCrd) { $s.watchCrd = [bool](Get-Service chromoting -ErrorAction SilentlyContinue) }
    # values are re-checked here too, because the file can be edited by hand
    $s.ntfy = ([string]$s.ntfy) -replace '[^A-Za-z0-9_-]', ''
    if ([string]$s.time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $s.time = $Defaults.time }
    if ([string]$s.plugType -notin '', 'shelly1', 'shelly2', 'tasmota') { $s.plugType = '' }
    $script:S = [pscustomobject]$s
    $script:settingsStamp = if (Test-Path $cfg) { (Get-Item $cfg).LastWriteTimeUtc } else { $null }
}

function Load-State {
    $script:St = @{ lastReboot = [datetime]::MinValue; plugTimes = @() }
    if (Test-Path $statef) {
        try {
            $j = Get-Content $statef -Raw | ConvertFrom-Json
            if ($j.lastReboot) { $script:St.lastReboot = [datetime]$j.lastReboot }
            if ($j.plugTimes) { $script:St.plugTimes = @($j.plugTimes | ForEach-Object { [datetime]$_ }) }
        } catch { }
    }
}
function Save-State {
    Save-Json @{ lastReboot = $script:St.lastReboot.ToString('s'); plugTimes = @($script:St.plugTimes | ForEach-Object { $_.ToString('s') }) } $statef
}

function Load-Outs([bool]$closeOpen) {
    $list = New-Object Collections.ArrayList
    if ((Test-Path $csv) -and (Get-Item $csv).Length -gt 0) {
        foreach ($r in Import-Csv $csv) {
            try {
                $end = if ($r.End) { [datetime]$r.End } elseif ($closeOpen) { Get-Date } else { $null }
                # an open row belongs to a watchdog that stopped mid-outage (PC rebooted, service restarted)
                $fix = if ($r.End -or -not $closeOpen) { $r.Fix } elseif ($r.Fix -eq 'reboot') { 'reboot' } else { 'watchdog restarted' }
                [void]$list.Add([pscustomobject]@{ Start = [datetime]$r.Start; End = $end; Cause = $r.Cause; Fix = $fix })
            } catch { }   # skip a damaged row instead of refusing to start
        }
    }
    , $list
}
function Save-Outs {
    $tmp = "$csv.tmp"
    if ($script:outs.Count -eq 0) { Set-Content $tmp '' } else {
        $script:outs | Select-Object @{n = 'Start'; e = { $_.Start.ToString('s') } }, @{n = 'End'; e = { if ($_.End) { $_.End.ToString('s') } else { '' } } }, Cause, Fix |
            Export-Csv $tmp -NoTypeInformation
    }
    Move-Item $tmp $csv -Force
}

function Notify($title, $msg) {   # phone alert through ntfy.sh; the topic name is the only secret
    if (-not $script:S.ntfy) { return }
    try { Invoke-RestMethod -Uri "https://ntfy.sh/$($script:S.ntfy)" -Method Post -Body $msg -Headers @{ Title = $title } -TimeoutSec 6 | Out-Null } catch { }
}
function Send-Heartbeat {   # "I am alive" for healthchecks.io & co: they alert you when these stop (power cut, crash, closed)
    $u = [string]$script:S.heartbeatUrl
    if ($u -notmatch '^https?://\S+$') { return }
    try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 6 | Out-Null } catch { }
}
function Set-KeepAwake { if ('Lsa' -as [type]) { [Lsa]::KeepAwake([bool]$script:S.keepAwake) } }

# ---------- probes ----------
function Exec($file, $argline) {   # console program without a window (the exe has no console); returns the exit code
    $psi = New-Object Diagnostics.ProcessStartInfo $file, $argline
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    try { $script:execOut = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd(); $p.WaitForExit(); $p.ExitCode } finally { $p.Dispose() }
}
function Ping($h, $ms) {
    $pp = New-Object Net.NetworkInformation.Ping
    try { $pp.Send($h, $ms).Status -eq 'Success' } catch { $false } finally { $pp.Dispose() }
}
function Test-Tcp($h, $port, $ms) {
    $c = New-Object Net.Sockets.TcpClient
    try { $ar = $c.BeginConnect($h, $port, $null, $null); $ar.AsyncWaitHandle.WaitOne($ms) -and $c.Connected } catch { $false } finally { $c.Close() }
}
function Test-Internet {   # ping first; some networks block ping, so a TCP connection to port 443 counts too
    foreach ($h in $ProbeHosts) { if (Ping $h 1000) { return $true } }
    foreach ($h in $ProbeHosts) { if (Test-Tcp $h 443 1500) { return $true } }
    $false
}

# ok | internet | dns | crd | tailscale | tslogin   (the first thing that is broken)
function Get-Health {
    if (-not (Test-Internet)) { return 'internet' }
    $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1
    $dns = if ($nic) { (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Select-Object -First 1 }
    # ask the DNS server directly so the local cache cannot hide a failure; no adapter/DNS server to ask = skip, not "failed"
    if ($dns) { try { Resolve-DnsName example.com -Server $dns -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null } catch { return 'dns' } }
    if ($script:S.watchCrd) {
        $svc = Get-Service chromoting -ErrorAction SilentlyContinue
        $state = if ($svc) { $svc.Status }
        if ($svc) { $svc.Dispose() }
        if ($state -and $state -ne 'Running') { return 'crd' }
    }
    if ($script:S.watchTs -and $script:tsExe -and (Exec $script:tsExe 'status') -ne 0) {
        if ($script:execOut -match 'Logged out|NeedsLogin') { return 'tslogin' }
        return 'tailscale'
    }
    'ok'
}

function Test-Gateway($gw) {   # ping, or proof from the ARP table that the router is there: some routers ignore ping
    if (Ping $gw 1000) { return $true }
    $n = Get-NetNeighbor -IPAddress $gw -ErrorAction SilentlyContinue | Select-Object -First 1
    [bool]($n -and [string]$n.State -in 'Reachable', 'Stale', 'Delay', 'Probe', 'Permanent')
}

function Diagnose($h) {   # WHERE the break is, in plain words: the cause written to the history
    if (-not (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) { return 'Network link down (cable, Wi-Fi or adapter)' }
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object NextHop -ne '0.0.0.0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if (-not $gw) { return 'No default gateway (DHCP lease lost)' }
    switch ($h) {
        'internet' { if (Test-Gateway $gw) { 'Router OK but no internet (ISP/WAN drop or router reconnect)' } else { 'Router unreachable (LAN side)' } }
        'dns' { 'Internet OK but DNS failing (router DNS)' }
        'crd' { 'Internet OK but Chrome Remote Desktop service is not running (remote access)' }
        'tailscale' { 'Internet OK but Tailscale offline (remote access)' }
        'tslogin' { 'Tailscale LOGGED OUT - sign in from the Tailscale tray icon (restarts cannot fix this)' }
        default { 'Unknown' }
    }
}

function Get-CauseClass([string]$cause) {
    switch -Wildcard ($cause) {
        '*link down*' { return 'local' }
        'No default gateway*' { return 'local' }
        'Router unreachable*' { return 'router' }
        'Router OK but no internet*' { return 'isp' }
        '*DNS failing*' { return 'dns' }
        '*LOGGED OUT*' { return 'tslogin' }
        '*(remote access)*' { return 'remote' }
    }
    'local'
}

# ---------- repairs ----------
function Restart-Remote {   # the remote-access tools being watched
    foreach ($name in @(if ($script:S.watchCrd) { 'chromoting' }) + @(if ($script:S.watchTs) { 'Tailscale' })) {
        if (Get-Service $name -ErrorAction SilentlyContinue) {
            Log "Restarting $name"
            try { Restart-Service $name -Force -ErrorAction Stop } catch { Log "  failed: $($_.Exception.Message)" }
        }
    }
}
function Reset-Soft {
    Log 'Adapter restart: flush DNS, restart the active adapters, renew the lease'
    $null = Exec ipconfig '/flushdns'
    foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') {
        Log "Restarting adapter $($a.Name)"
        try { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop } catch { Log "  failed: $($_.Exception.Message)" }
    }
    Start-Sleep 8
    $null = Exec ipconfig '/renew'
    Restart-Remote
}
function Reset-Devices {
    Log 'Device restart: restart the network adapters as devices, renew the lease'
    foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue) {
        Log "Restarting device $($a.Name)"
        $null = Exec pnputil "/restart-device `"$($a.PnpDeviceID)`""
    }
    Start-Sleep 10
    $null = Exec ipconfig '/renew'
    Restart-Remote
}
function Reset-Deep {   # MANUAL ONLY: rewrites the TCP/IP settings (static IPs and DNS are lost), needs a reboot
    Log 'DEEP reset (manual): release, Winsock and TCP/IP reset, device restart, renew'
    $null = Exec ipconfig '/release'
    $null = Exec ipconfig '/flushdns'
    $null = Exec netsh 'winsock reset'
    $null = Exec netsh 'int ip reset'
    foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue) { $null = Exec pnputil "/restart-device `"$($a.PnpDeviceID)`"" }
    Start-Sleep 10
    $null = Exec ipconfig '/renew'
    Log 'Deep reset done. Restart the PC to finish it.'
}
function Get-PlugUrl {
    $h = [string]$script:S.plugHost
    if ($h -notmatch '^[A-Za-z0-9.-]+(:\d{1,5})?$') { return $null }
    # every command makes the PLUG turn itself back on after 30 s, so the router comes back even if this PC cannot reach it
    switch ($script:S.plugType) {
        'shelly1' { "http://$h/relay/0?turn=off&timer=30" }
        'shelly2' { "http://$h/rpc/Switch.Set?id=0&on=false&toggle_after=30" }
        'tasmota' { "http://$h/cm?cmnd=Backlog%20Power1%20Off%3BDelay%20300%3BPower1%20On" }
    }
}
function Invoke-PlugCycle {
    $url = Get-PlugUrl
    if (-not $url) { Log 'Router plug: no plug type or valid address set'; return $false }
    Log "Router power-cycle via the $($script:S.plugType) plug at $($script:S.plugHost) (off 30 s, it switches itself back on)"
    try { Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 | Out-Null; $true } catch { Log "  the plug did not answer: $($_.Exception.Message)"; $false }
}
function Invoke-Action($action) {
    switch ($action) {
        'adapter restart' { Reset-Soft; return $true }
        'device restart' { Reset-Devices; return $true }
        'flush DNS' { Log 'Flushing the DNS cache'; $null = Exec ipconfig '/flushdns'; return $true }
        'renew lease' { Log 'Renewing the DHCP lease (also fetches the DNS servers again)'; $null = Exec ipconfig '/renew'; return $true }
        'restart service' { Restart-Remote; return $true }
        'router power-cycle' { return (Invoke-PlugCycle) }
        'reboot' { $null = Exec shutdown '/r /t 30 /c "NetRefresh: network down 15 min"'; return $true }
    }
    $false
}
function Test-RebootAllowed($now) { [bool]$script:S.reboot -and ($now - $script:St.lastReboot).TotalHours -ge 3 }
function Test-PlugAllowed($now) {   # at most 3 power-cycles a day, 30 min apart: never a router reboot loop
    if (-not (Get-PlugUrl)) { return $false }
    $recent = @($script:St.plugTimes | Where-Object { ($now - $_).TotalHours -lt 24 })
    $recent.Count -lt 3 -and -not @($recent | Where-Object { ($now - $_).TotalMinutes -lt 30 }).Count
}

# ---------- the watchdog ----------
function Check-Health($now) {
    $h = Get-Health
    if ($h -eq 'ok') {
        $script:fails = 0
        if ($script:cur) {
            $c = $script:cur; $c.End = $now
            if (-not $c.Fix) { $c.Fix = 'self-recovered' }
            Save-Outs; $script:cur = $null; $script:stage = 0
            $mins = [int]($c.End - $c.Start).TotalMinutes
            Log "Back UP after $mins min. Cause: $($c.Cause). Fixed by: $($c.Fix)"
            Notify 'NetRefresh: back UP' "Down $mins min. Cause: $($c.Cause). Fixed by: $($c.Fix)"
        }
        if (($now - $script:lastBeat).TotalSeconds -ge 300) { $script:lastBeat = $now; Send-Heartbeat }
        return
    }
    if ($script:fails -eq 0) { $script:firstFail = $now }
    $script:fails++
    if ($script:fails -ge 3 -and -not $script:cur) {   # 3 failed checks in a row (~30 s) = a real outage, not a blip
        $script:cur = [pscustomobject]@{ Start = $script:firstFail; End = $null; Cause = (Diagnose $h); Fix = '' }
        $script:stage = 0
        [void]$script:outs.Add($script:cur); Save-Outs
        Log "DOWN since $($script:firstFail.ToString('HH:mm:ss')). Cause: $($script:cur.Cause)"
        Notify 'NetRefresh: DOWN' "Since $($script:firstFail.ToString('HH:mm:ss')). Cause: $($script:cur.Cause)"
    }
    if (-not $script:cur -or $script:stage -ge $Stages.Count) { return }
    if (($now - $script:cur.Start).TotalSeconds -lt $Stages[$script:stage]) { return }

    $class = Get-CauseClass (Diagnose $h)   # diagnose again: the cause can change during an outage
    $action = $Plan[$class][$script:stage]
    $script:stage++
    if ($action -eq 'router power-cycle' -and -not (Test-PlugAllowed $now)) {
        $action = if ($class -eq 'router') { 'device restart' } else { $null }   # no plug set up, or used up for today
    }
    if ($action -eq 'reboot' -and -not (Test-RebootAllowed $now)) {
        Log $(if ($script:S.reboot) { 'Still down, but rebooted less than 3 h ago: not rebooting again' } else { 'Still down; the last-resort reboot is switched off' })
        $action = $null
    }
    if (-not $action) {
        $why = @{ isp = 'the router works but the internet does not: an ISP/WAN outage that nothing on this PC can fix (it is counted in the ISP report)'
                  tslogin = 'Tailscale is logged out: only a person can sign it in again' }[$class]
        if ($why -and $script:stage -eq 1) { Log "Waiting: $why" }
        return
    }
    $script:cur.Fix = $action; Save-Outs
    if ($action -eq 'reboot') {
        $script:St.lastReboot = $now; Save-State
        Log 'Still down after 15 min: REBOOTING in 30 s'
        Notify 'NetRefresh: rebooting' 'A local network fault lasted 15 min even after repairs: the PC reboots in 30 s.'
        [void](Invoke-Action $action); return
    }
    if ($action -eq 'router power-cycle') { $script:St.plugTimes = @($script:St.plugTimes) + $now; Save-State }
    [void](Invoke-Action $action)
    Log "Done ($action). Internet: $(if (Test-Internet) { 'UP' } else { 'still DOWN' })"
}

function Get-NextRun($now) {
    if (-not $script:S.armed) { return $null }
    $n = $now.Date.Add([timespan]::Parse($script:S.time))
    if ($n -le $now) { $n.AddDays(1) } else { $n }
}
function Invoke-Daily($now) {
    if ($script:S.fullRestart -and ($now - $script:St.lastReboot).TotalMinutes -ge 10) {   # 10-min guard: never a restart loop
        $script:St.lastReboot = $now; Save-State
        Log 'Scheduled full restart: the PC restarts in 30 s'
        Notify 'NetRefresh: restarting' 'Scheduled daily restart: the PC restarts in 30 s.'
        $null = Exec shutdown '/r /t 30 /c "NetRefresh: scheduled daily restart"'
    } else {
        Log 'Scheduled daily reset'
        Reset-Soft
        Log "Done. Internet: $(if (Test-Internet) { 'UP' } else { 'still DOWN' })"
    }
}
function Test-UpdateGuardExpired($now) {   # the Windows Update guard switches itself off after 7 days, so updates still finish
    $until = [string]$script:S.updGuardUntil
    if (-not $until) { return }
    $on = (Get-ItemProperty $AuKey -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue).NoAutoRebootWithLoggedOnUsers -eq 1
    if ($on -and $now -gt [datetime]$until) {
        Remove-ItemProperty $AuKey -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue
        Log 'Windows Update guard ended after 7 days: automatic update restarts are allowed again'
    }
}

function Start-Watchdog {
    $script:outs = Load-Outs $true; Save-Outs
    $script:cur = $null; $script:stage = 0; $script:fails = 0; $script:tick = 0; $script:lastMinute = -1; $script:lastBeat = [datetime]::MinValue
    $script:next = Get-NextRun (Get-Date)
    Set-KeepAwake
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if (((Get-Date) - $boot).TotalMinutes -lt 10) { Notify 'NetRefresh: PC is back' 'The PC started and NetRefresh is watching again.' }
    } catch { }
}
function Step-Watchdog($now = (Get-Date)) {   # called once a second, by the service loop or the window's timer
    if ((Test-Path $cfg) -and (Get-Item $cfg).LastWriteTimeUtc -ne $script:settingsStamp) {
        Load-Settings; $script:next = Get-NextRun $now; Set-KeepAwake
    }
    if ($script:next -and $now -ge $script:next) { Invoke-Daily $now; $script:next = Get-NextRun $now }
    if (++$script:tick -ge 10) { $script:tick = 0; Check-Health $now }
    if ($now.Minute -ne $script:lastMinute) {
        $script:lastMinute = $now.Minute
        Test-UpdateGuardExpired $now
        if ((Test-Path $logf) -and (Get-Item $logf).Length -gt 5MB) { Move-Item $logf "$logf.1" -Force }   # the log never grows without end
    }
}

# ---------- reports ----------
function Get-DailyPattern($outs, $now) {   # an hour of the day with drops on 3+ different days in the last 7
    $wk = @($outs | Where-Object { $_.Start -gt $now.AddDays(-7) })
    $best = $wk | Group-Object { $_.Start.Hour } | ForEach-Object {
        [pscustomobject]@{ Hour = [int]$_.Name; Days = @($_.Group | ForEach-Object { $_.Start.Date } | Sort-Object -Unique).Count }
    } | Sort-Object Days -Descending | Select-Object -First 1
    if ($best -and $best.Days -ge 3) { $best } else { $null }
}
function New-IspReport($outs, $now, $days = 30) {
    $rows = @($outs | Where-Object { $_.Start -gt $now.AddDays(-$days) } | Sort-Object Start)
    $dur = { param($o) ($(if ($o.End) { $o.End } else { $now }) - $o.Start).TotalMinutes }
    $isp = @($rows | Where-Object { (Get-CauseClass $_.Cause) -eq 'isp' })
    $ispMin = 0; $longest = 0
    foreach ($o in $isp) { $m = & $dur $o; $ispMin += $m; if ($m -gt $longest) { $longest = $m } }
    $byClass = $rows | Group-Object { Get-CauseClass $_.Cause } | ForEach-Object { "$($_.Name): $($_.Count)" }
    $out = New-Object Collections.Generic.List[string]
    $out.Add('NetRefresh outage report')
    $out.Add("Period: $($now.AddDays(-$days).ToString('dd.MM.yyyy')) - $($now.ToString('dd.MM.yyyy')) ($days days)")
    $out.Add('')
    $out.Add("Internet outages while the home router itself was working (an ISP-side problem): $($isp.Count), $([int]$ispMin) minutes in total, longest $([int]$longest) minutes.")
    $p = Get-DailyPattern $outs $now
    if ($p) { $out.Add(("Repeating pattern: drops on {0} of the last 7 days around {1:00}:00." -f $p.Days, $p.Hour)) }
    $out.Add("All outages in the period: $($rows.Count) ($(@($byClass) -join ', '))")
    $out.Add('')
    $out.Add('ISP-side outages:')
    $out.Add('Start              End                Minutes')
    foreach ($o in $isp) {
        $out.Add(('{0,-18} {1,-18} {2,7}' -f $o.Start.ToString('dd.MM.yyyy HH:mm'), $(if ($o.End) { $o.End.ToString('dd.MM.yyyy HH:mm') } else { 'ongoing' }), [int](& $dur $o)))
    }
    $out.Add('')
    $out.Add('How this was measured: every 10 seconds the PC pings 1.1.1.1 and 8.8.8.8 and tries a TCP connection to port 443. Three failed checks in a row (about 30 s) count as an outage. "Router working" means the router answered on the home network (ping or ARP) during the outage.')
    $out -join "`r`n"
}

if ($Library) { return }

if ($Probe) { Load-Settings; $h = Get-Health; "health=$h"; "diagnose=$(Diagnose $h)"; "class=$(Get-CauseClass (Diagnose $h))"; return }

# ---------- start-up ----------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and -not $Preview) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show('NetRefresh needs administrator rights to repair the network. Start NetRefresh.exe, or run PowerShell as administrator.', 'NetRefresh')
    return
}

if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Force $dataDir | Out-Null
    if (-not $Preview -and -not $env:NETREFRESH_DATA) {
        # only SYSTEM and administrators may change what the elevated watchdog reads; users can read it
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        Set-Acl $dataDir $acl
        foreach ($n in 'settings.json', 'outages.csv', 'netrefresh.log') {   # one-time move from older versions, which kept data next to the program
            $old = Join-Path $appDir $n
            if (Test-Path $old) { Copy-Item $old $dataDir -Force }
        }
    }
}

# Windows auto-login keeps the password as the LSA secret "DefaultPassword" (same method as Sysinternals Autologon)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Lsa {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attr, uint access, out IntPtr policy);
    [DllImport("advapi32.dll", EntryPoint = "LsaStorePrivateData")] static extern uint LsaStore(IntPtr policy, ref LSA_UNICODE_STRING key, ref LSA_UNICODE_STRING data);
    [DllImport("advapi32.dll", EntryPoint = "LsaStorePrivateData")] static extern uint LsaDelete(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr nullData);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LogonUser(string user, string domain, string pass, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);

    static void Check(uint st) { if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st)); }
    static LSA_UNICODE_STRING Make(string s) {
        LSA_UNICODE_STRING r = new LSA_UNICODE_STRING();
        r.Buffer = Marshal.StringToCoTaskMemUni(s); r.Length = (ushort)(s.Length * 2); r.MaximumLength = (ushort)(r.Length + 2); return r;
    }
    // value == null deletes the secret
    public static void SetSecret(string key, string value) {
        LSA_OBJECT_ATTRIBUTES oa = new LSA_OBJECT_ATTRIBUTES(); oa.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr pol; Check(LsaOpenPolicy(IntPtr.Zero, ref oa, 0x20, out pol));   // POLICY_CREATE_SECRET
        LSA_UNICODE_STRING k = Make(key); LSA_UNICODE_STRING v = new LSA_UNICODE_STRING();
        try {
            if (value == null) Check(LsaDelete(pol, ref k, IntPtr.Zero));
            else { v = Make(value); Check(LsaStore(pol, ref k, ref v)); }
        } finally {
            Marshal.FreeCoTaskMem(k.Buffer);
            if (v.Buffer != IntPtr.Zero) Marshal.ZeroFreeCoTaskMemUnicode(v.Buffer);
            LsaClose(pol);
        }
    }
    // while on, Windows will not idle-sleep as long as the calling thread lives (the screen may still turn off)
    public static void KeepAwake(bool on) { SetThreadExecutionState(0x80000000u | (on ? 0x00000001u : 0u)); }
    // 0 = password is right; 1326 = wrong password
    public static int CheckPassword(string user, string domain, string pass) {
        IntPtr tok;
        if (LogonUser(user, domain, pass, 2, 0, out tok)) { CloseHandle(tok); return 0; }
        return Marshal.GetLastWin32Error();
    }
}
'@

Load-Settings
Load-State

# ---------- service: the headless watchdog ----------
if ($Service) {
    if (-not $StopEvent) { $StopEvent = New-Object Threading.ManualResetEvent $false }   # -Service -Preview test runs
    Start-Watchdog
    Log 'Watchdog service started'
    while (-not $StopEvent.WaitOne(1000)) {
        try { Step-Watchdog } catch { Log "Internal error (continuing): $($_.Exception.Message)" }
    }
    Log 'Watchdog service stopped'
    return
}

# ---------- the window ----------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Get-ConsoleUser { (Get-CimInstance Win32_ComputerSystem).UserName }
function Get-ServiceRunning { $s = Get-Service NetRefresh -ErrorAction SilentlyContinue; $r = [bool]($s -and $s.Status -eq 'Running'); if ($s) { $s.Dispose() }; $r }

$script:svcMode = Get-ServiceRunning
$script:windowWatching = $false
$script:uiStamp = $null; $script:uiOuts = New-Object Collections.ArrayList
if (-not $script:svcMode) { Start-Watchdog; $script:windowWatching = $true } else { $script:outs = Load-Outs $false }

function Draw-Graph($g, $w, $h, $outs) {
    $g.Clear([Drawing.Color]::White)
    $left = 62; $top = 20; $rowH = [math]::Floor(($h - $top - 4) / 7); $cw = $w - $left - 10
    $font = New-Object Drawing.Font('Segoe UI', 8)
    $txt = [Drawing.Brushes]::DimGray
    $track = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(222, 240, 226))
    $red = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(214, 48, 49))
    $amber = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(232, 160, 24))
    $grid = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(110, 140, 140, 140))
    for ($i = 0; $i -lt 7; $i++) {
        $day = [datetime]::Today.AddDays(-$i); $dayEnd = $day.AddDays(1); $y = $top + $i * $rowH
        $g.DrawString($day.ToString('ddd dd.MM'), $font, $txt, 2, $y + 3)
        $g.FillRectangle($track, $left, $y + 2, $cw, $rowH - 4)
        foreach ($o in $outs) {
            $e = if ($o.End) { $o.End } else { Get-Date }
            if ($e -le $day -or $o.Start -ge $dayEnd) { continue }
            $a = if ($o.Start -gt $day) { $o.Start } else { $day }
            $b = if ($e -lt $dayEnd) { $e } else { $dayEnd }
            $brush = if ((Get-CauseClass $o.Cause) -in 'remote', 'tslogin') { $amber } else { $red }
            $g.FillRectangle($brush, [single]($left + $cw * ($a - $day).TotalHours / 24), [single]($y + 2), [single]([math]::Max(2, $cw * ($b - $a).TotalHours / 24)), [single]($rowH - 4))
        }
    }
    for ($hr = 0; $hr -le 24; $hr += 3) {
        $x = $left + $cw * $hr / 24
        $g.DrawLine($grid, [single]$x, [single]($top - 3), [single]$x, [single]($top + 7 * $rowH))
        if ($hr -lt 24) { $g.DrawString(('{0:00}' -f $hr), $font, $txt, [single]($x - 6), 2) }
    }
    foreach ($o in $font, $track, $red, $amber, $grid) { $o.Dispose() }
}

$appIcon = try {
    if ($ExePath) { [Drawing.Icon]::ExtractAssociatedIcon($ExePath) }
    elseif (Test-Path (Join-Path $appDir 'src\app.ico')) { New-Object Drawing.Icon (Join-Path $appDir 'src\app.ico') }
    else { [Drawing.SystemIcons]::Application }
} catch { [Drawing.SystemIcons]::Application }
$f = New-Object Windows.Forms.Form -Property @{ Text = $(if ($Preview) { 'NetRefresh (preview)' } else { 'NetRefresh' }); Size = '660,570'; StartPosition = 'CenterScreen'; MinimumSize = '660,570'; Icon = $appIcon }
$tabs = New-Object Windows.Forms.TabControl -Property @{ Dock = 'Fill' }
$t1 = New-Object Windows.Forms.TabPage -Property @{ Text = 'Control' }
$t2 = New-Object Windows.Forms.TabPage -Property @{ Text = 'History' }
$t5 = New-Object Windows.Forms.TabPage -Property @{ Text = 'Setup check' }
$t3 = New-Object Windows.Forms.TabPage -Property @{ Text = 'Auto-login' }
$t4 = New-Object Windows.Forms.TabPage -Property @{ Text = 'Extras' }
$tabs.TabPages.AddRange(@($t1, $t2, $t5, $t3, $t4)); $f.Controls.Add($tabs)

# ---- Control tab ----
$lbl = New-Object Windows.Forms.Label -Property @{ Text = 'Run every day at:'; Location = '10,16'; AutoSize = $true }
$pick = New-Object Windows.Forms.DateTimePicker -Property @{ Format = 'Custom'; CustomFormat = 'HH:mm'; ShowUpDown = $true; Location = '115,12'; Width = 70; Value = [datetime]::Today.Add([timespan]::Parse($script:S.time)) }
$btnStart = New-Object Windows.Forms.Button -Property @{ Text = $(if ($script:S.armed) { 'Stop' } else { 'Start' }); Location = '200,10'; Size = '80,28' }
$btnNow = New-Object Windows.Forms.Button -Property @{ Text = 'Run now'; Location = '290,10'; Size = '80,28' }
$btnRestart = New-Object Windows.Forms.Button -Property @{ Text = 'Test PC restart'; Location = '380,10'; Size = '110,28' }
$btnCancel = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel restart'; Location = '500,10'; Size = '110,28' }
$stat = New-Object Windows.Forms.Label -Property @{ Location = '10,44'; Size = '610,18' }
$mode = New-Object Windows.Forms.Label -Property @{ Location = '10,64'; Size = '615,18' }
$chkRb = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Last resort: reboot if a LOCAL network fault lasts 15 min (max once per 3 h, never for ISP outages)'; Location = '10,86'; Size = '615,22'; Checked = [bool]$script:S.reboot }
$chkFull = New-Object Windows.Forms.CheckBox -Property @{ Text = 'At the set time restart the WHOLE PC (instead of the network reset)'; Location = '10,110'; Size = '615,22'; Checked = [bool]$script:S.fullRestart }
$chkAuto = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Install as a Windows service and start with Windows (keeps watching without this window)'; Location = '10,134'; Size = '615,22'; Checked = [bool](Get-Service NetRefresh -ErrorAction SilentlyContinue) }
$chkCrd = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Watch Chrome Remote Desktop'; Location = '10,160'; Size = '240,22'; Checked = [bool]$script:S.watchCrd }
$chkTs = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Reboot Tailscale'; Location = '260,160'; Size = '300,22'; Checked = [bool]$script:S.watchTs }
$lblApp = New-Object Windows.Forms.Label -Property @{ Text = 'Open at login:'; Location = '10,192'; AutoSize = $true }
$appSearch = New-Object Windows.Forms.TextBox -Property @{ Location = '105,188'; Width = 150 }
(New-Object Windows.Forms.ToolTip).SetToolTip($appSearch, 'Type to search your apps')
$combo = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Location = '265,188'; Width = 255 }
$script:apps = @{}   # Start-menu name -> AppID (works for Store apps like Claude Desktop and normal programs)
$script:appNames = New-Object Collections.ArrayList
[void]$combo.Items.Add('(nothing)')
foreach ($a in Get-StartApps | Sort-Object Name) { if (-not $script:apps.ContainsKey($a.Name)) { $script:apps[$a.Name] = $a.AppID; [void]$script:appNames.Add($a.Name); [void]$combo.Items.Add($a.Name) } }
$combo.SelectedItem = if ($script:S.launch -and $script:apps.ContainsKey([string]$script:S.launch)) { [string]$script:S.launch } else { '(nothing)' }
$lblLogin = New-Object Windows.Forms.Label -Property @{ Location = '10,216'; Size = '615,20' }
$box = New-Object Windows.Forms.TextBox -Property @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Location = '10,240'; Size = '615,244'; Anchor = 'Top,Left,Right,Bottom' }
$t1.Controls.AddRange(@($lbl, $pick, $btnStart, $btnNow, $btnRestart, $btnCancel, $stat, $mode, $chkRb, $chkFull, $chkAuto, $chkCrd, $chkTs, $lblApp, $appSearch, $combo, $lblLogin, $box))

# ---- History tab ----
$sum = New-Object Windows.Forms.Label -Property @{ Location = '10,8'; Size = '495,20' }
$repBtn = New-Object Windows.Forms.Button -Property @{ Text = 'ISP report...'; Location = '515,4'; Size = '110,24' }
$pg = New-Object Windows.Forms.Panel -Property @{ Location = '10,32'; Size = '615,210'; BorderStyle = 'FixedSingle' }
$pg.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($pg, $true)
$leg = New-Object Windows.Forms.Label -Property @{ Text = 'Red = internet down, amber = remote tool down. One row per day, 00:00 to 24:00.'; Location = '10,246'; Size = '610,18'; ForeColor = 'DimGray' }
$lv = New-Object Windows.Forms.ListView -Property @{ View = 'Details'; FullRowSelect = $true; Location = '10,270'; Size = '615,220'; Anchor = 'Top,Left,Right,Bottom' }
[void]$lv.Columns.Add('Started', 105); [void]$lv.Columns.Add('Down', 60); [void]$lv.Columns.Add('Cause', 300); [void]$lv.Columns.Add('Fixed by', 120)
$t2.Controls.AddRange(@($sum, $repBtn, $pg, $leg, $lv))

# ---- Setup check tab ----
$chkBtn = New-Object Windows.Forms.Button -Property @{ Text = 'Check now'; Location = '10,10'; Size = '100,28' }
$fixBtn = New-Object Windows.Forms.Button -Property @{ Text = 'Fix ticked problems'; Location = '120,10'; Size = '150,28' }
$lvS = New-Object Windows.Forms.ListView -Property @{ View = 'Details'; FullRowSelect = $true; CheckBoxes = $true; Location = '10,46'; Size = '615,438'; Anchor = 'Top,Left,Right,Bottom' }
[void]$lvS.Columns.Add('Status', 70); [void]$lvS.Columns.Add('Item', 270); [void]$lvS.Columns.Add('Why it matters', 270)
$t5.Controls.AddRange(@($chkBtn, $fixBtn, $lvS))

# ---- Auto-login tab ----
$meName = ((Get-ConsoleUser) -split '\\')[-1]
$l3a = New-Object Windows.Forms.Label -Property @{ Text = "Make Windows sign in as $meName by itself after every restart (only needed to open apps after a restart)."; Location = '10,14'; Size = '610,20' }
$l3b = New-Object Windows.Forms.Label -Property @{ Text = 'Windows password:'; Location = '10,52'; AutoSize = $true }
$pass = New-Object Windows.Forms.TextBox -Property @{ UseSystemPasswordChar = $true; Location = '130,48'; Width = 220 }
$enable = New-Object Windows.Forms.Button -Property @{ Text = 'Enable auto-login'; Location = '10,88'; Size = '130,28' }
$disable = New-Object Windows.Forms.Button -Property @{ Text = 'Disable auto-login'; Location = '150,88'; Size = '130,28' }
$l3c = New-Object Windows.Forms.Label -Property @{ Location = '10,130'; Size = '610,200'; ForeColor = 'DimGray'
    Text = "Use the account password. For a Microsoft account that is the Microsoft account password, not the PIN.`r`n`r`nThe password is checked against Windows, then stored encrypted by Windows itself (not in any NetRefresh file, never logged). The box is cleared afterwards.`r`n`r`nEnabling also turns off 'Windows Hello only' sign-in, which Windows needs for auto-login.`r`n`r`nAnyone who can touch this PC can then sign in without a password, and an administrator can read the stored password with tools. The watchdog service itself does NOT need auto-login." }
$t3.Controls.AddRange(@($l3a, $l3b, $pass, $enable, $disable, $l3c))

# ---- Extras tab ----
$PlugTypes = [ordered]@{ '(none)' = ''; 'Shelly Gen1' = 'shelly1'; 'Shelly Gen2+' = 'shelly2'; 'Tasmota' = 'tasmota' }
$chkAwake = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Keep this PC awake (Windows cannot idle-sleep; the screen may still turn off)'; Location = '10,10'; Size = '615,22'; Checked = [bool]$script:S.keepAwake }
$chkUpd = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Stop Windows Update restarting the PC by itself for 7 days (then it switches itself off)'; Location = '10,34'; Size = '615,22'
    Checked = [bool]((Get-ItemProperty $AuKey -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue).NoAutoRebootWithLoggedOnUsers -eq 1) }
$chkTray = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Minimize to the tray and show pop-up alerts (starts hidden after a login)'; Location = '10,58'; Size = '615,22'; Checked = [bool]$script:S.tray }
$l4a = New-Object Windows.Forms.Label -Property @{ Text = 'Phone alerts (ntfy.sh topic):'; Location = '10,92'; AutoSize = $true }
$ntfyBox = New-Object Windows.Forms.TextBox -Property @{ Location = '175,88'; Width = 235; Text = [string]$script:S.ntfy }
$ntfyTest = New-Object Windows.Forms.Button -Property @{ Text = 'Send test'; Location = '420,86'; Size = '90,26' }
$l4b = New-Object Windows.Forms.Label -Property @{ Location = '10,114'; Size = '615,30'; ForeColor = 'DimGray'; Text = 'Free ntfy app on your phone, same topic. Use a long random topic: anyone who knows it can read the alerts.' }
$lHb = New-Object Windows.Forms.Label -Property @{ Text = 'Heartbeat URL:'; Location = '10,152'; AutoSize = $true }
$hbBox = New-Object Windows.Forms.TextBox -Property @{ Location = '175,148'; Width = 335; Text = [string]$script:S.heartbeatUrl }
$hbTest = New-Object Windows.Forms.Button -Property @{ Text = 'Send now'; Location = '520,146'; Size = '90,26' }
$lHb2 = New-Object Windows.Forms.Label -Property @{ Location = '10,174'; Size = '615,30'; ForeColor = 'DimGray'; Text = 'A healthchecks.io (or self-hosted) ping URL, sent every 5 min. It alerts you when this PC stops checking in: power cut, crash, app closed, no internet.' }
$lPlug = New-Object Windows.Forms.Label -Property @{ Text = 'Router smart plug:'; Location = '10,214'; AutoSize = $true }
$plugCombo = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Location = '175,210'; Width = 115 }
[void]$plugCombo.Items.AddRange([object[]]@($PlugTypes.Keys))
$plugCombo.SelectedItem = @($PlugTypes.Keys | Where-Object { $PlugTypes[$_] -eq [string]$script:S.plugType })[0]
if (-not $plugCombo.SelectedItem) { $plugCombo.SelectedIndex = 0 }
$plugHost = New-Object Windows.Forms.TextBox -Property @{ Location = '300,210'; Width = 140; Text = [string]$script:S.plugHost }
(New-Object Windows.Forms.ToolTip).SetToolTip($plugHost, 'IP address of the plug, e.g. 192.168.1.50')
$plugTest = New-Object Windows.Forms.Button -Property @{ Text = 'Test power-cycle'; Location = '450,208'; Size = '160,26' }
$lPlug2 = New-Object Windows.Forms.Label -Property @{ Location = '10,238'; Size = '615,44'; ForeColor = 'DimGray'; Text = 'Switches the router off for 30 s when it hangs (router unreachable, or no internet while it still answers). At most 3 times a day, 30 min apart. The plug switches itself back on, even if this PC cannot reach it.' }
$deepBtn = New-Object Windows.Forms.Button -Property @{ Text = 'Deep network reset (manual)...'; Location = '10,292'; Size = '220,28' }
$lDeep = New-Object Windows.Forms.Label -Property @{ Location = '240,298'; Size = '385,20'; ForeColor = 'DimGray'; Text = 'Rewrites the TCP/IP settings: static IPs and DNS are lost. Never automatic.' }
$t4.Controls.AddRange(@($chkAwake, $chkUpd, $chkTray, $l4a, $ntfyBox, $ntfyTest, $l4b, $lHb, $hbBox, $hbTest, $lHb2, $lPlug, $plugCombo, $plugHost, $plugTest, $lPlug2, $deepBtn, $lDeep))

# ---- tray: the window hides there instead of closing ----
$ni = New-Object Windows.Forms.NotifyIcon -Property @{ Icon = $appIcon; Text = 'NetRefresh'; Visible = $true }
$ni.ContextMenu = New-Object Windows.Forms.ContextMenu
[void]$ni.ContextMenu.MenuItems.Add('Open', { $f.Show(); $f.WindowState = 'Normal'; $f.Activate() })
[void]$ni.ContextMenu.MenuItems.Add('Exit', {
    $msg = if ($script:svcMode) { 'Close the NetRefresh window? The watchdog service keeps running.' } else { 'Quit NetRefresh? The connection will NOT be watched until you start it again.' }
    if ([Windows.Forms.MessageBox]::Show($msg, 'NetRefresh', 'YesNo', 'Question') -eq 'Yes') {
        if (-not $script:svcMode) { Log 'NetRefresh stopped (closed by the user)'; Notify 'NetRefresh stopped' 'The window was closed: the connection is no longer watched.' }
        $script:quitting = $true; $f.Close()
    }
})
$ni.Add_DoubleClick({ $f.Show(); $f.WindowState = 'Normal'; $f.Activate() })
$script:quitting = $false; $script:hintShown = $false
$f.Add_FormClosing({
    if ($_.CloseReason -eq 'UserClosing' -and -not $script:quitting) {   # X hides; Exit is in the tray menu
        $_.Cancel = $true; $f.Hide()
        if (-not $script:hintShown) { $script:hintShown = $true; $ni.ShowBalloonTip(6000, 'NetRefresh is still running', 'It keeps watching from the tray. Right-click the tray icon and choose Exit to quit.', 'Info') }
    }
})
$f.Add_Resize({ if ($chkTray.Checked -and $f.WindowState -eq 'Minimized') { $f.Hide() } })
$f.Add_FormClosed({ $ni.Visible = $false; $ni.Dispose() })

# ---------- window helpers ----------
function Save-Settings {
    $h = [ordered]@{
        time = $pick.Value.ToString('HH:mm'); armed = [bool]$script:S.armed; reboot = $chkRb.Checked; fullRestart = $chkFull.Checked
        watchCrd = $chkCrd.Checked; watchTs = $chkTs.Checked; keepAwake = $chkAwake.Checked; tray = $chkTray.Checked
        ntfy = ($ntfyBox.Text -replace '[^A-Za-z0-9_-]', ''); launch = $(if ([string]$combo.SelectedItem -eq '(nothing)') { '' } else { [string]$combo.SelectedItem })
        updGuardUntil = [string]$script:S.updGuardUntil; heartbeatUrl = $hbBox.Text.Trim()
        plugType = $PlugTypes[[string]$plugCombo.SelectedItem]; plugHost = $plugHost.Text.Trim()
    }
    Save-Json $h $cfg
    Load-Settings
    $ntfyBox.Text = $script:S.ntfy
    $script:next = Get-NextRun (Get-Date)
    Set-KeepAwake
}
$script:busy = $false
function Invoke-UiTask([scriptblock]$job) {   # one repair at a time; the buttons are off while it runs
    if ($script:busy) { [void][Windows.Forms.MessageBox]::Show('A repair is already running. Try again in a moment.', 'NetRefresh'); return }
    $script:busy = $true
    $buttons = $btnNow, $btnRestart, $deepBtn, $plugTest, $fixBtn
    foreach ($b in $buttons) { $b.Enabled = $false }
    $f.Cursor = 'WaitCursor'
    try { & $job } finally { foreach ($b in $buttons) { $b.Enabled = $true }; $f.Cursor = 'Default'; $script:busy = $false; Update-LogBox }
}
$script:logPos = -1
function Update-LogBox {   # the box shows the shared log file, written by the service or by this window
    if (-not (Test-Path $logf)) { return }
    $text = ''
    try {
        $fs = [IO.File]::Open($logf, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($script:logPos -lt 0) { $script:logPos = [math]::Max(0, $fs.Length - 20000) }
            if ($fs.Length -lt $script:logPos) { $script:logPos = 0; $box.Clear() }   # the log was rotated
            if ($fs.Length -gt $script:logPos) {
                $fs.Position = $script:logPos
                $buf = New-Object byte[] ($fs.Length - $script:logPos)
                $n = $fs.Read($buf, 0, $buf.Length); $script:logPos += $n
                $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
            }
        } finally { $fs.Dispose() }
    } catch { return }
    if (-not $text) { return }
    $box.AppendText($text)
    if ($chkTray.Checked) {
        foreach ($line in $text -split "`r?`n") {
            if ($line -match 'DOWN since|Back UP|REBOOTING|restarts in 30 s') { $ni.ShowBalloonTip(5000, 'NetRefresh', ($line -replace '^\[[^\]]+\]\s*', ''), 'Info') }
        }
    }
}
function Get-UiOuts {
    if (-not $script:svcMode) { return , $script:outs }
    $stamp = if (Test-Path $csv) { (Get-Item $csv).LastWriteTimeUtc } else { $null }
    if ($stamp -ne $script:uiStamp) { $script:uiStamp = $stamp; $script:uiOuts = Load-Outs $false }
    , $script:uiOuts
}
function Refresh-History {
    $outs = Get-UiOuts
    $wk = @($outs | Where-Object { $_.Start -gt [datetime]::Today.AddDays(-6) })
    $mins = 0; foreach ($o in $wk) { $mins += (($(if ($o.End) { $o.End } else { Get-Date })) - $o.Start).TotalMinutes }
    $hrs = $wk | Group-Object { $_.Start.Hour } | Sort-Object Count -Descending | Select-Object -First 1
    $sum.Text = "Last 7 days: $($wk.Count) drops, $([int]$mins) min down" + $(if ($hrs) { ", most often around $('{0:00}' -f [int]$hrs.Name):00" })
    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($o in @($outs | Sort-Object Start -Descending | Select-Object -First 100)) {
        $dur = if ($o.End) { "$([int]($o.End - $o.Start).TotalMinutes) min" } else { 'ongoing' }
        $fix = if ($o.Fix) { $o.Fix } elseif ($o.End) { 'self-recovered' } else { '-' }
        [void]$lv.Items.Add([Windows.Forms.ListViewItem]::new([string[]]@($o.Start.ToString('dd.MM HH:mm'), $dur, $o.Cause, $fix)))
    }
    $lv.EndUpdate()
    $pg.Invalidate()
}
function Update-Status {
    $n = Get-NextRun (Get-Date)
    $stat.Text = if ($n) { 'Daily {0} at {1}: next in {2:hh\:mm\:ss}' -f $(if ($script:S.fullRestart) { 'full restart' } else { 'network reset' }), $script:S.time, ($n - (Get-Date)) } else { 'Daily action: off (press Start)' }
}
function Update-ModeLabel {
    if ($script:svcMode) { $mode.Text = 'Watchdog: running as a Windows service (keeps watching without this window, even before login).'; $mode.ForeColor = 'DarkGreen' }
    else { $mode.Text = 'Watchdog: running in this window only. Tick "Install as a Windows service" so it keeps watching when closed.'; $mode.ForeColor = 'DarkOrange' }
}
function Update-Login {   # Windows decides who auto-logs in (Winlogon); we only check it matches the user running this app
    $me = ((Get-ConsoleUser) -split '\\')[-1]
    $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ($w.AutoAdminLogon -ne '1') { $lblLogin.Text = "Auto-login is OFF (only needed to open apps after a restart)."; $lblLogin.ForeColor = 'DimGray' }
    elseif ($w.DefaultUserName -notmatch [regex]::Escape($me)) { $lblLogin.Text = "WARNING: auto-login is set for '$($w.DefaultUserName)', not $me."; $lblLogin.ForeColor = 'Firebrick' }
    else { $lblLogin.Text = "Auto-login is ON for $me."; $lblLogin.ForeColor = 'DarkGreen' }
}
function Install-NetRefresh {   # protected copy in Program Files + Windows service + window at login
    if (-not $ExePath) { [void][Windows.Forms.MessageBox]::Show('Installing works from NetRefresh.exe. Build it with build.bat first.', 'NetRefresh'); return $false }
    if ($Preview) { [void][Windows.Forms.MessageBox]::Show('Not in preview mode.', 'NetRefresh'); return $false }
    $dest = Join-Path $installDir 'NetRefresh.exe'
    try {
        $old = Get-Service NetRefresh -ErrorAction SilentlyContinue
        if ($old) { Stop-Service NetRefresh -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
        New-Item -ItemType Directory -Force $installDir | Out-Null
        if ($ExePath -ne $dest) { Copy-Item $ExePath $dest -Force }
        if (-not $old) {
            New-Service -Name NetRefresh -BinaryPathName "`"$dest`" --service" -DisplayName 'NetRefresh network watchdog' -Description 'Watches the internet connection and repairs it according to the cause.' -StartupType Automatic | Out-Null
        }
        $null = Exec sc.exe 'failure NetRefresh reset= 86400 actions= restart/10000/restart/10000/restart/60000'
        Start-Service NetRefresh
        # older versions started a user-writable copy as admin at login: remove that task
        Unregister-ScheduledTask NetRefresh -Confirm:$false -ErrorAction SilentlyContinue
        $cu = Get-ConsoleUser
        Register-ScheduledTask NetRefreshWindow -Action (New-ScheduledTaskAction -Execute $dest -Argument '-Boot') -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $cu) `
            -Principal (New-ScheduledTaskPrincipal -UserId $cu -RunLevel Highest) -Force | Out-Null
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\NetRefresh.lnk')); $lnk.TargetPath = $dest; $lnk.Save()
        Log "Installed to ${installDir}: the watchdog service is running; the window opens when $cu logs in (Start menu: NetRefresh)"
        $true
    } catch { [void][Windows.Forms.MessageBox]::Show("Install failed: $($_.Exception.Message)", 'NetRefresh'); $false }
}
function Uninstall-NetRefresh {
    Stop-Service NetRefresh -Force -ErrorAction SilentlyContinue
    $null = Exec sc.exe 'delete NetRefresh'
    foreach ($tn in 'NetRefreshWindow', 'NetRefresh') { Unregister-ScheduledTask $tn -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\NetRefresh.lnk') -ErrorAction SilentlyContinue
    Log "Uninstalled the service and the autostart. The program in $installDir and your history in $dataDir were kept."
}

# ---------- setup check ----------
$EnergyKeys = '*EEE', 'AdvancedEEE', 'EEELinkAdvertisement', 'EnableGreenEthernet', 'GreenEthernet', 'PowerSavingMode', 'ULPMode', 'SavePowerNowEnabled', 'AutoPowerSaveModeEnabled'
function Get-PowerAc($sub, $setting) {   # seconds; the last two hex values of powercfg /query are AC, then DC (language-independent)
    $null = Exec powercfg "/query SCHEME_CURRENT $sub $setting"
    $v = [regex]::Matches($script:execOut, '0x[0-9a-fA-F]{8}')
    if ($v.Count -ge 2) { [Convert]::ToInt64($v[$v.Count - 2].Value, 16) } else { $null }
}
function Get-SetupIssues {
    $items = New-Object Collections.ArrayList
    $add = { param($status, $name, $why, $fix, $restart) [void]$items.Add([pscustomobject]@{ Status = $status; Name = $name; Why = $why; Fix = $fix; Restart = [bool]$restart }) }
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) {
        $n = $a.Name
        try {
            $pm = Get-NetAdapterPowerManagement -Name $n -ErrorAction Stop
            if ([string]$pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
                & $add 'Problem' "${n}: Windows may switch it off to save power" 'A common cause of overnight drops.' ({ Set-NetAdapterPowerManagement -Name $n -AllowComputerToTurnOffDevice Disabled -NoRestart }.GetNewClosure()) $true
            } else { & $add 'OK' "${n}: never switched off to save power" '' $null $false }
        } catch { }
        foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $n -AllProperties -ErrorAction SilentlyContinue | Where-Object { $EnergyKeys -contains $_.RegistryKeyword })) {
            $k = $p.RegistryKeyword
            if ((@($p.RegistryValue) -join '') -ne '0') {
                & $add 'Problem' "${n}: $($p.DisplayName) is on" 'Energy saving on the link can drop it when the PC is idle.' ({ Set-NetAdapterAdvancedProperty -Name $n -RegistryKeyword $k -RegistryValue 0 -NoRestart }.GetNewClosure()) $true
            }
        }
    }
    $sl = Get-PowerAc 'SUB_SLEEP' 'STANDBYIDLE'
    if ($sl -gt 0) { & $add 'Problem' "The PC sleeps after $([int]($sl / 60)) min on mains power" 'A sleeping PC cannot be reached remotely.' { $null = Exec powercfg '/change standby-timeout-ac 0' } $false }
    elseif ($null -ne $sl) { & $add 'OK' 'Sleep on mains power: never' '' $null $false }
    $hib = Get-PowerAc 'SUB_SLEEP' 'HIBERNATEIDLE'
    if ($hib -gt 0) { & $add 'Problem' "The PC hibernates after $([int]($hib / 60)) min on mains power" 'A hibernating PC cannot be reached remotely.' { $null = Exec powercfg '/change hibernate-timeout-ac 0' } $false }
    $crd = Get-Service chromoting -ErrorAction SilentlyContinue
    if ($crd) {
        if ([string]$crd.StartType -ne 'Automatic') { & $add 'Problem' 'Chrome Remote Desktop does not start with Windows' 'After a restart you could not connect.' { Set-Service chromoting -StartupType Automatic } $false }
        else { & $add 'OK' 'Chrome Remote Desktop starts with Windows' '' $null $false }
    }
    if (Get-Service NetRefresh -ErrorAction SilentlyContinue) { & $add 'OK' 'NetRefresh watchdog service installed' '' $null $false }
    else { & $add 'Problem' 'NetRefresh watchdog service not installed' 'Without it nothing is watched while this window is closed or before login.' { if (Install-NetRefresh) { $chkAuto.Checked = $true } } $false }
    $pat = Get-DailyPattern (Get-UiOuts) (Get-Date)
    if ($pat) { & $add 'Problem' ('Drops on {0} of the last 7 days around {1:00}:00' -f $pat.Days, $pat.Hour) 'Typical of an ISP forced 24-hour reconnect or a router schedule: set the router reconnect/reboot time to an hour you do not need the PC, or ask your ISP.' $null $false }
    else { & $add 'OK' 'No daily drop pattern in the last 7 days' '' $null $false }
    & $add 'Tip' 'BIOS: "Restore on AC power loss" = Power On' 'The PC then starts by itself after a power cut. Windows cannot see this setting.' $null $false
    & $add 'Tip' 'Router: give this PC a DHCP reservation' 'Its address never changes, so port forwards and remote tools keep working.' $null $false
    , $items
}
function Show-SetupCheck {
    $lvS.BeginUpdate(); $lvS.Items.Clear()
    foreach ($i in (Get-SetupIssues)) {
        $it = [Windows.Forms.ListViewItem]::new([string[]]@($i.Status, $i.Name, $i.Why))
        $it.Tag = $i
        $it.Checked = [bool]($i.Status -eq 'Problem' -and $i.Fix)
        if ($i.Status -eq 'Problem') { $it.ForeColor = 'Firebrick' } elseif ($i.Status -eq 'OK') { $it.ForeColor = 'DarkGreen' }
        [void]$lvS.Items.Add($it)
    }
    $lvS.EndUpdate()
}

# ---------- wiring ----------
$btnStart.Add_Click({
    $script:S.armed = -not $script:S.armed; Save-Settings
    $btnStart.Text = if ($script:S.armed) { 'Stop' } else { 'Start' }
    Log $(if ($script:S.armed) { "Daily action on, next run $((Get-NextRun (Get-Date)).ToString('dd.MM HH:mm'))" } else { 'Daily action off' })
})
$pick.Add_ValueChanged({ Save-Settings })
foreach ($c in $chkRb, $chkFull, $chkCrd, $chkTs, $chkTray) { $c.Add_Click({ Save-Settings }) }
$chkAwake.Add_Click({ Save-Settings; Log "Keep-awake $(if ($chkAwake.Checked) { 'on' } else { 'off' })" })
$chkUpd.Add_Click({
    try {
        if ($chkUpd.Checked) {
            if (-not (Test-Path $AuKey)) { New-Item $AuKey -Force | Out-Null }   # never -Force an existing key: that wipes its other policy values
            New-ItemProperty $AuKey -Name NoAutoRebootWithLoggedOnUsers -PropertyType DWord -Value 1 -Force | Out-Null
            $script:S.updGuardUntil = (Get-Date).AddDays(7).ToString('s')
            Log "Windows Update auto-restart blocked until $((Get-Date).AddDays(7).ToString('dd.MM HH:mm'))"
        } else {
            Remove-ItemProperty $AuKey -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue
            $script:S.updGuardUntil = ''
            Log 'Windows Update auto-restart allowed again'
        }
        Save-Settings
    } catch { $chkUpd.Checked = -not $chkUpd.Checked; [void][Windows.Forms.MessageBox]::Show("Failed: $($_.Exception.Message)", 'NetRefresh') }
})
$ntfyBox.Add_Leave({ Save-Settings })
$ntfyTest.Add_Click({
    Save-Settings
    if (-not $script:S.ntfy) { [void][Windows.Forms.MessageBox]::Show('Type a topic first.', 'NetRefresh'); return }
    try { Invoke-RestMethod -Uri "https://ntfy.sh/$($script:S.ntfy)" -Method Post -Body 'If you can read this, phone alerts work.' -Headers @{ Title = 'NetRefresh test' } -TimeoutSec 6 | Out-Null; Log 'Test alert sent' }
    catch { Log "Test alert failed: $($_.Exception.Message)" }
    Update-LogBox
})
$hbBox.Add_Leave({ Save-Settings })
$hbTest.Add_Click({
    Save-Settings
    if ($script:S.heartbeatUrl -notmatch '^https?://\S+$') { [void][Windows.Forms.MessageBox]::Show('Paste the ping URL from healthchecks.io (it starts with https://).', 'NetRefresh'); return }
    try { Invoke-WebRequest -Uri $script:S.heartbeatUrl -UseBasicParsing -TimeoutSec 6 | Out-Null; Log 'Heartbeat sent' } catch { Log "Heartbeat failed: $($_.Exception.Message)" }
    Update-LogBox
})
$plugCombo.Add_SelectedIndexChanged({ Save-Settings })
$plugHost.Add_Leave({ Save-Settings })
$plugTest.Add_Click({
    Save-Settings
    if (-not (Get-PlugUrl)) { [void][Windows.Forms.MessageBox]::Show('Choose the plug type and enter its IP address first.', 'NetRefresh'); return }
    if ([Windows.Forms.MessageBox]::Show('This switches the router off for 30 seconds. The internet is gone for about 2-3 minutes while the router starts again. Continue?', 'Test router power-cycle', 'YesNo', 'Warning') -ne 'Yes') { return }
    Invoke-UiTask { if (Invoke-PlugCycle) { Log 'The plug answered: power-cycle started' } }
})
$deepBtn.Add_Click({
    $msg = "Deep reset rewrites the Windows network settings (Winsock and TCP/IP).`n`nStatic IP addresses and manually set DNS servers are LOST, and VPN software may need repair. Restart the PC afterwards.`n`nOnly use it if the normal repairs do not help. Continue?"
    if ([Windows.Forms.MessageBox]::Show($msg, 'Deep network reset', 'YesNo', 'Warning') -ne 'Yes') { return }
    Invoke-UiTask { Reset-Deep }
})
$combo.Add_SelectedIndexChanged({ Save-Settings })
$appSearch.Add_TextChanged({   # substring search; the first match gets selected, clearing the box keeps the choice
    $q = $appSearch.Text.Trim(); $cur = [string]$combo.SelectedItem
    $combo.BeginUpdate(); $combo.Items.Clear(); [void]$combo.Items.Add('(nothing)')
    foreach ($n in $script:appNames) { if (-not $q -or $n.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$combo.Items.Add($n) } }
    $combo.EndUpdate()
    if ($q -and $combo.Items.Count -gt 1) { $combo.SelectedIndex = 1 }
    elseif ($combo.Items.Contains($cur)) { $combo.SelectedItem = $cur }
    else { $combo.SelectedIndex = 0 }
})
$chkAuto.Add_Click({
    if ($chkAuto.Checked) { if (-not (Install-NetRefresh)) { $chkAuto.Checked = $false } }
    else { Uninstall-NetRefresh }
    $script:svcCheck = 99   # re-check the mode on the next tick
})
$btnNow.Add_Click({ Invoke-UiTask { Reset-Soft; Log "Done. Internet: $(if (Test-Internet) { 'UP' } else { 'still DOWN' })" } })
$btnRestart.Add_Click({
    if ([Windows.Forms.MessageBox]::Show("Restart this PC in 30 seconds?`n`nSave your work first. Press 'Cancel restart' to stop it.", 'Test PC restart', 'YesNo', 'Warning') -ne 'Yes') { return }
    Log 'TEST: the PC restarts in 30 s'
    [void](Exec shutdown '/r /t 30 /c "NetRefresh: test restart"')
})
$btnCancel.Add_Click({ [void](Exec shutdown '/a'); Log 'Restart cancelled (if one was pending)' })
$repBtn.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog -Property @{ Filter = 'Text file|*.txt'; FileName = "NetRefresh-ISP-report-$((Get-Date).ToString('yyyy-MM-dd')).txt"; InitialDirectory = [Environment]::GetFolderPath('MyDocuments') }
    if ($dlg.ShowDialog() -eq 'OK') { Set-Content $dlg.FileName (New-IspReport (Get-UiOuts) (Get-Date)) -Encoding UTF8; Log "ISP report saved to $($dlg.FileName)" }
})
$chkBtn.Add_Click({ $f.Cursor = 'WaitCursor'; try { Show-SetupCheck } finally { $f.Cursor = 'Default' } })
$fixBtn.Add_Click({
    $sel = @($lvS.CheckedItems | ForEach-Object { $_.Tag } | Where-Object { $_.Fix })
    if (-not $sel) { [void][Windows.Forms.MessageBox]::Show('Run the check, then tick the problems to fix.', 'NetRefresh'); return }
    if ([Windows.Forms.MessageBox]::Show("Apply $($sel.Count) fix(es)? Adapter changes restart the adapter, so the connection drops for a few seconds.", 'NetRefresh', 'YesNo', 'Question') -ne 'Yes') { return }
    Invoke-UiTask {
        $restart = $false
        foreach ($i in $sel) {
            try { & $i.Fix; Log "Setup fix applied: $($i.Name)"; if ($i.Restart) { $restart = $true } } catch { Log "Setup fix failed: $($i.Name): $($_.Exception.Message)" }
        }
        if ($restart) { foreach ($a in Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') { try { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop } catch { } } }
    }
    Show-SetupCheck
})
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$enable.Add_Click({
    $pw = $pass.Text
    if (-not $pw) { [void][Windows.Forms.MessageBox]::Show('Type your Windows password first.', 'NetRefresh'); return }
    $ask = "Windows will sign in as $meName automatically after every restart, and 'Windows Hello only' sign-in will be turned off.`n`nAnyone with physical access to this PC will be able to sign in.`n`nContinue?"
    if ([Windows.Forms.MessageBox]::Show($ask, 'Enable auto-login', 'YesNo', 'Warning') -ne 'Yes') { return }
    $err = [Lsa]::CheckPassword($meName, $env:COMPUTERNAME, $pw)   # one attempt only, so it cannot lock the account
    if ($err -ne 0) {
        $msg = switch ($err) {
            1326 { 'Wrong password. For a Microsoft account use its password, not the PIN.' }
            1327 { 'Windows will not accept this sign-in (account restriction, e.g. a blank password).' }
            default { "Windows rejected the sign-in (error $err)." }
        }
        $pass.Clear(); [void][Windows.Forms.MessageBox]::Show($msg, 'NetRefresh'); return
    }
    try {
        [Lsa]::SetSecret('DefaultPassword', $pw)   # first: if this fails nothing else is changed
        Remove-ItemProperty $wl DefaultPassword -ErrorAction SilentlyContinue   # never leave a plain-text copy
        Set-ItemProperty $wl AutoAdminLogon '1'; Set-ItemProperty $wl DefaultUserName $meName; Set-ItemProperty $wl DefaultDomainName $env:COMPUTERNAME
        Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' DevicePasswordLessBuildVersion 0 -ErrorAction SilentlyContinue
        Log "Auto-login enabled for $meName"
    } catch { [void][Windows.Forms.MessageBox]::Show("Failed: $($_.Exception.Message)", 'NetRefresh') } finally { $pass.Clear(); $pw = $null }
    Update-Login
})
$disable.Add_Click({
    try { [Lsa]::SetSecret('DefaultPassword', $null) } catch { }   # fine if there was none
    Remove-ItemProperty $wl DefaultPassword -ErrorAction SilentlyContinue
    Set-ItemProperty $wl AutoAdminLogon '0'
    Log 'Auto-login disabled'; Update-Login
})
$pg.Add_Paint({ Draw-Graph $_.Graphics $pg.ClientSize.Width $pg.ClientSize.Height (Get-UiOuts) })

# started by the login task (-Boot): open the chosen app once, 30 s later so the network is up
$script:launchAt = if ($Boot) { (Get-Date).AddSeconds(30) } else { $null }
if ($Boot -and $chkTray.Checked) { $f.Add_Shown({ $f.Hide() }) }
$script:svcCheck = 0; $script:hist = 0
$t = New-Object Windows.Forms.Timer -Property @{ Interval = 1000 }
$t.Add_Tick({
    if ($script:busy) { return }
    $script:busy = $true
    try {
        if (++$script:svcCheck -ge 5) {
            $script:svcCheck = 0
            $script:svcMode = Get-ServiceRunning
            if ($script:svcMode) { $script:windowWatching = $false }
            elseif (-not $script:windowWatching) { Start-Watchdog; $script:windowWatching = $true; Log 'Watching from this window (the service is not running)' }
            Update-ModeLabel
        }
        if ($script:windowWatching) { Step-Watchdog }
        if ($script:launchAt -and (Get-Date) -ge $script:launchAt) {
            $script:launchAt = $null
            $id = $script:apps[[string]$combo.SelectedItem]
            if ($id) { Log "Opening $($combo.SelectedItem)"; Start-Process explorer.exe "shell:AppsFolder\$id" }
        }
        Update-LogBox
        Update-Status
        if (++$script:hist -ge 10) {
            $script:hist = 0; Refresh-History; Update-Login
            $chkUpd.Checked = [bool]((Get-ItemProperty $AuKey -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue).NoAutoRebootWithLoggedOnUsers -eq 1)
        }
    } finally { $script:busy = $false }
})
Log $(if ($script:svcMode) { 'Window opened (the watchdog service is running)' } else { 'Watching the connection every 10 s from this window' })
Update-ModeLabel; Update-Status; Update-Login; Refresh-History; Update-LogBox
$t.Start()
[Windows.Forms.Application]::Run($f)   # not ShowDialog: hiding a modal dialog would end it
