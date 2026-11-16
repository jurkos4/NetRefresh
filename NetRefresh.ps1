param([switch]$Test, [switch]$Probe, [switch]$Preview, [switch]$Boot, [switch]$Elevated, [string]$Demo)
# NetRefresh: daily scheduled network reset + outage watchdog with escalation (soft -> hard -> reboot),
# outage logger (outages.csv, netrefresh.log) and a 7-day dropout graph. Runs while the window is open.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$dir = if ($ExeDir) { $ExeDir } else { $PSScriptRoot }   # $ExeDir/$ExePath are set by NetRefresh.exe, which hosts this script
$csv = Join-Path $dir 'outages.csv'
$cfg = Join-Path $dir 'settings.json'
$logf = Join-Path $dir 'netrefresh.log'
$script:watchTs = $false; $script:watchCrd = $true   # remote-access tools to watch; the window's checkboxes set these
$script:tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $script:tsExe)) { $script:tsExe = $null }

# runs a console program with no window (the exe has no console, so a plain call would flash one); returns the exit code
function Exec($file, $argline) {
    $psi = New-Object Diagnostics.ProcessStartInfo $file, $argline
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $script:execOut = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd(); $p.WaitForExit(); $p.ExitCode
}

function Ping($h, $ms) { try { (New-Object Net.NetworkInformation.Ping).Send($h, $ms).Status -eq 'Success' } catch { $false } }

# ok | internet | dns | tailscale  (first thing that is broken)
function Get-Health {
    if (-not (Ping '1.1.1.1' 1000) -and -not (Ping '8.8.8.8' 1000)) { return 'internet' }
    try {
        $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses | Select-Object -First 1
        # ask the DNS server directly so the local cache can't hide a failure
        if ($dns) { Resolve-DnsName example.com -Server $dns -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null }
    } catch { return 'dns' }
    if ($script:watchCrd) {   # Chrome Remote Desktop host service
        $svc = Get-Service chromoting -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') { return 'crd' }
    }
    if ($script:watchTs -and $script:tsExe -and (Exec $script:tsExe 'status') -ne 0) {
        if ($script:execOut -match 'Logged out|NeedsLogin') { return 'tslogin' }   # only a person can sign in
        return 'tailscale'
    }
    'ok'
}

# works out WHERE the break is, in plain words (this is the "cause" in the log)
function Diagnose($h) {
    if (-not (Get-NetAdapter -Physical | Where-Object Status -eq 'Up')) { return 'Ethernet link down (cable/NIC/driver)' }
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object NextHop -ne '0.0.0.0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if (-not $gw) { return 'No default gateway (DHCP lease lost)' }
    if (-not (Ping $gw 1000)) { return 'Router unreachable (LAN side)' }
    switch ($h) {
        'internet' { 'Router OK but no internet (ISP/WAN drop or router reconnect)' }
        'dns' { 'Internet OK but DNS failing (router DNS)' }
        'crd' { 'Internet OK but Chrome Remote Desktop service is not running (remote access)' }
        'tailscale' { 'Internet OK but Tailscale offline (remote access)' }
        'tslogin' { 'Tailscale LOGGED OUT - sign in from the Tailscale tray icon (restarts cannot fix this)' }
        default { 'Unknown' }
    }
}

function Restart-TS($log) {   # restarts whichever remote-access tools are being watched
    foreach ($name in @(if ($script:watchCrd) { 'chromoting' }) + @(if ($script:watchTs) { 'Tailscale' })) {
        if (Get-Service $name -ErrorAction SilentlyContinue) {
            $log.Invoke("Restarting $name")
            try { Restart-Service $name -Force -ErrorAction Stop } catch { $log.Invoke("  failed: $_") }
        }
    }
}

# mode: soft | hard | tailscale
function Reset-Net($log, $mode = 'soft') {
    if ($mode -eq 'tailscale') { Restart-TS $log }
    elseif ($mode -eq 'soft') {
        $log.Invoke('SOFT reset: flush DNS, restart adapters, renew lease')
        $null = Exec ipconfig '/flushdns'
        foreach ($a in Get-NetAdapter -Physical | Where-Object Status -eq 'Up') {
            $log.Invoke("Restarting adapter $($a.Name)")
            try { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop } catch { $log.Invoke("  failed: $_") }
        }
        Start-Sleep 8
        $null = Exec ipconfig '/renew'
        Restart-TS $log
    } else {
        $log.Invoke('HARD reset: release, winsock + IP stack reset, device restart, renew')
        $null = Exec ipconfig '/release'
        $null = Exec ipconfig '/flushdns'
        $null = Exec netsh 'winsock reset'   # fully applies after the next reboot
        $null = Exec netsh 'int ip reset'
        foreach ($a in Get-NetAdapter -Physical) {
            $log.Invoke("Restarting device $($a.Name)")
            $null = Exec pnputil "/restart-device `"$($a.PnpDeviceID)`""
        }
        Start-Sleep 10
        $null = Exec ipconfig '/renew'
        $null = Exec ipconfig '/registerdns'
        Restart-TS $log
    }
    $log.Invoke("Done. Internet: $(if (Ping '1.1.1.1' 3000) {'UP'} else {'still DOWN'})")
}

function Draw-Graph($g, $w, $h, $outs) {
    $g.Clear([Drawing.Color]::White)
    $left = 62; $top = 20; $rowH = [math]::Floor(($h - $top - 4) / 7); $cw = $w - $left - 10
    $font = New-Object Drawing.Font('Segoe UI', 8)
    $txt = [Drawing.Brushes]::DimGray
    $track = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(222, 240, 226))
    $red = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(214, 48, 49))
    $amber = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(232, 160, 24))   # Tailscale-only problems
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
            $g.FillRectangle($(if ($o.Cause -match 'Tailscale|Chrome Remote') { $amber } else { $red }), [single]($left + $cw * ($a - $day).TotalHours / 24), [single]($y + 2), [single]([math]::Max(2, $cw * ($b - $a).TotalHours / 24)), [single]($rowH - 4))
        }
    }
    for ($hr = 0; $hr -le 24; $hr += 3) {
        $x = $left + $cw * $hr / 24
        $g.DrawLine($grid, [single]$x, [single]($top - 3), [single]$x, [single]($top + 7 * $rowH))
        if ($hr -lt 24) { $g.DrawString(('{0:00}' -f $hr), $font, $txt, [single]($x - 6), 2) }
    }
}

if ($Demo) {
    $d = [datetime]::Today
    $o = @(
        [pscustomobject]@{ Start = $d.AddHours(5.4); End = $d.AddHours(5.9) },
        [pscustomobject]@{ Start = $d.AddDays(-1).AddHours(5.2); End = $d.AddDays(-1).AddHours(6.3) },
        [pscustomobject]@{ Start = $d.AddDays(-2).AddHours(5.6); End = $d.AddDays(-2).AddHours(5.7) },
        [pscustomobject]@{ Start = $d.AddDays(-2).AddHours(14); End = $d.AddDays(-2).AddHours(14.2) },
        [pscustomobject]@{ Start = $d.AddDays(-4).AddHours(23.8); End = $d.AddDays(-3).AddHours(0.4) })
    $bmp = New-Object Drawing.Bitmap 620, 210
    Draw-Graph ([Drawing.Graphics]::FromImage($bmp)) 620 210 $o
    $bmp.Save($Demo, [Drawing.Imaging.ImageFormat]::Png); exit
}
if ($Probe) { $h = Get-Health; "health=$h"; "diagnose=$(Diagnose $h)"; exit }

# the enum, not the string 'Administrator': the string means the USER named Administrator and is false for normal accounts
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and -not $Preview -and -not $ExeDir) {   # the exe's manifest already demands admin
    if ($Elevated) { [void][Windows.Forms.MessageBox]::Show('Could not get administrator rights.', 'NetRefresh'); exit }   # never relaunch twice    $argList = '-NoProfile -ExecutionPolicy Bypass {0} -File "{1}"' -f $(if ($Test) { '' } else { '-WindowStyle Hidden' }), $PSCommandPath
    if ($Test) { $argList += ' -Test' }
    if ($Boot) { $argList += ' -Boot' }
    $argList += ' -Elevated'
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}
if ($Test) { Reset-Net { param($m) Write-Host $m }; Read-Host 'Enter to close'; exit }

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
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
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

# ---------- state ----------
$script:next = $null; $script:ping = 0; $script:fails = 0; $script:firstFail = $null
$script:cur = $null; $script:stage = 0; $script:kind = ''; $script:busy = $false; $script:hist = 0
$script:lastReboot = [datetime]::MinValue
$script:outs = New-Object Collections.ArrayList
if ((Test-Path $csv) -and (Get-Item $csv).Length -gt 0) {
    foreach ($r in Import-Csv $csv) {
        $e = if ($r.End) { [datetime]$r.End } else { Get-Date }   # open row = app/PC restarted mid-outage
        $fx = if ($r.End) { $r.Fix } elseif ($r.Fix -eq 'reboot') { 'reboot' } else { 'app restarted' }
        [void]$script:outs.Add([pscustomobject]@{ Start = [datetime]$r.Start; End = $e; Cause = $r.Cause; Fix = $fx })
    }
}
$set = if (Test-Path $cfg) { Get-Content $cfg -Raw | ConvertFrom-Json } else { $null }
if ($set -and $set.lastReboot) { $script:lastReboot = [datetime]$set.lastReboot }
$script:watchCrd = if ($set -and $null -ne $set.watchCrd) { [bool]$set.watchCrd } else { [bool](Get-Service chromoting -ErrorAction SilentlyContinue) }
$script:watchTs = [bool]($set -and $set.watchTs)
$script:ntfy = if ($set -and $set.ntfy) { [string]$set.ntfy } else { '' }

# ---------- UI ----------
$f = New-Object Windows.Forms.Form -Property @{ Text = 'NetRefresh'; Size = '660,570'; StartPosition = 'CenterScreen'; MinimumSize = '660,570' }
$tabs = New-Object Windows.Forms.TabControl -Property @{ Dock = 'Fill' }
$t1 = New-Object Windows.Forms.TabPage -Property @{ Text = 'Control' }
$t2 = New-Object Windows.Forms.TabPage -Property @{ Text = 'History' }
$t3 = New-Object Windows.Forms.TabPage -Property @{ Text = 'Auto-login' }
$t4 = New-Object Windows.Forms.TabPage -Property @{ Text = 'Extras' }
$tabs.TabPages.AddRange(@($t1, $t2, $t3, $t4)); $f.Controls.Add($tabs)

$lbl = New-Object Windows.Forms.Label -Property @{ Text = 'Run every day at:'; Location = '10,16'; AutoSize = $true }
$start = if ($set -and $set.time) { [timespan]::Parse($set.time) } else { [timespan]::FromMinutes(375) }
$pick = New-Object Windows.Forms.DateTimePicker -Property @{ Format = 'Custom'; CustomFormat = 'HH:mm'; ShowUpDown = $true; Location = '115,12'; Width = 70; Value = [datetime]::Today.Add($start) }
$btn = New-Object Windows.Forms.Button -Property @{ Text = 'Start'; Location = '200,10'; Size = '80,28' }
$now = New-Object Windows.Forms.Button -Property @{ Text = 'Run now'; Location = '290,10'; Size = '80,28' }
$rb = New-Object Windows.Forms.Button -Property @{ Text = 'Test PC restart'; Location = '380,10'; Size = '110,28' }
$rbCancel = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel restart'; Location = '500,10'; Size = '110,28' }
$stat = New-Object Windows.Forms.Label -Property @{ Text = 'Stopped'; Location = '10,46'; Size = '600,20' }
$chkRb = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Last resort: reboot the PC if the internet stays down 15 min (max once per 3 h)'; Location = '10,70'; Size = '600,22'; Checked = [bool]($null -eq $set -or $set.reboot) }
$chkFull = New-Object Windows.Forms.CheckBox -Property @{ Text = 'At the set time restart the WHOLE PC (instead of the soft network reset)'; Location = '10,94'; Size = '600,22'; Checked = [bool]($set -and $set.fullRestart) }
$chkAuto = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Start with Windows (run at login, as admin)'; Location = '10,118'; Size = '600,22'; Checked = [bool](Get-ScheduledTask NetRefresh -ErrorAction SilentlyContinue) }
$chkCrd = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Watch Chrome Remote Desktop'; Location = '10,144'; Size = '240,22'; Checked = $script:watchCrd }
$chkTs = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Reboot Tailscale'; Location = '260,144'; Size = '300,22'; Checked = $script:watchTs }
$lblApp = New-Object Windows.Forms.Label -Property @{ Text = 'Open at login:'; Location = '10,176'; AutoSize = $true }
$appSearch = New-Object Windows.Forms.TextBox -Property @{ Location = '105,172'; Width = 150 }
(New-Object Windows.Forms.ToolTip).SetToolTip($appSearch, 'Type to search your apps')
$combo = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Location = '265,172'; Width = 255 }
$script:apps = @{}   # Start-menu name -> AppID (works for Store apps like Claude Desktop and normal programs)
[void]$combo.Items.Add('(nothing)')
$script:appNames = New-Object Collections.ArrayList   # full list, so the search box can narrow the combo and widen it again
foreach ($a in Get-StartApps | Sort-Object Name) { if (-not $script:apps.ContainsKey($a.Name)) { $script:apps[$a.Name] = $a.AppID; [void]$script:appNames.Add($a.Name); [void]$combo.Items.Add($a.Name) } }
$combo.SelectedItem = if ($set -and $set.launch -and $script:apps.ContainsKey($set.launch)) { $set.launch } elseif ($null -eq $set -and $script:apps.ContainsKey('Claude')) { 'Claude' } else { '(nothing)' }
$lblLogin = New-Object Windows.Forms.Label -Property @{ Location = '10,202'; Size = '615,20' }
$box = New-Object Windows.Forms.TextBox -Property @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Location = '10,228'; Size = '615,256'; Anchor = 'Top,Left,Right,Bottom' }
$t1.Controls.AddRange(@($lbl, $pick, $btn, $now, $rb, $rbCancel, $stat, $chkRb, $chkFull, $chkAuto, $chkCrd, $chkTs, $lblApp, $appSearch, $combo, $lblLogin, $box))

$sum = New-Object Windows.Forms.Label -Property @{ Location = '10,8'; Size = '610,20' }
$pg = New-Object Windows.Forms.Panel -Property @{ Location = '10,32'; Size = '615,210'; BorderStyle = 'FixedSingle' }
$pg.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($pg, $true)
$leg = New-Object Windows.Forms.Label -Property @{ Text = 'Red = internet down, amber = remote tool down. One row per day, 00:00 to 24:00.'; Location = '10,246'; Size = '610,18'; ForeColor = 'DimGray' }
$lv = New-Object Windows.Forms.ListView -Property @{ View = 'Details'; FullRowSelect = $true; Location = '10,270'; Size = '615,220'; Anchor = 'Top,Left,Right,Bottom' }
[void]$lv.Columns.Add('Started', 105); [void]$lv.Columns.Add('Down', 60); [void]$lv.Columns.Add('Cause', 300); [void]$lv.Columns.Add('Fixed by', 120)
$t2.Controls.AddRange(@($sum, $pg, $leg, $lv))
$meName = ((Get-CimInstance Win32_ComputerSystem).UserName -split '\\')[-1]   # helpers are defined further down
$l3a = New-Object Windows.Forms.Label -Property @{ Text = "Make Windows sign in as $meName by itself after every restart."; Location = '10,14'; Size = '610,20' }
$l3b = New-Object Windows.Forms.Label -Property @{ Text = 'Windows password:'; Location = '10,52'; AutoSize = $true }
$pass = New-Object Windows.Forms.TextBox -Property @{ UseSystemPasswordChar = $true; Location = '130,48'; Width = 220 }
$enable = New-Object Windows.Forms.Button -Property @{ Text = 'Enable auto-login'; Location = '10,88'; Size = '130,28' }
$disable = New-Object Windows.Forms.Button -Property @{ Text = 'Disable auto-login'; Location = '150,88'; Size = '130,28' }
$l3c = New-Object Windows.Forms.Label -Property @{ Location = '10,130'; Size = '610,200'; ForeColor = 'DimGray'
    Text = "Use the account password. For a Microsoft account that is the Microsoft account password, not the PIN.`r`n`r`nThe password is checked against Windows, then stored encrypted by Windows itself (not in any NetRefresh file, never logged). The box is cleared afterwards.`r`n`r`nEnabling also turns off 'Windows Hello only' sign-in, which Windows needs for auto-login.`r`n`r`nAnyone who can touch this PC can then sign in without a password, and an administrator can read the stored password with tools. Use Disable when you are back." }
$t3.Controls.AddRange(@($l3a, $l3b, $pass, $enable, $disable, $l3c))

# ---- Extras tab ----
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$chkAwake = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Keep this PC awake while NetRefresh runs (Windows cannot idle-sleep; the screen may still turn off)'; Location = '10,14'; Size = '610,22'; Checked = [bool]($null -eq $set -or $null -eq $set.keepAwake -or $set.keepAwake) }
$chkUpd = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Stop Windows Update restarting the PC by itself while I am signed in'; Location = '10,42'; Size = '610,22'
    Checked = [bool]((Get-ItemProperty $au -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue).NoAutoRebootWithLoggedOnUsers -eq 1) }
$chkTray = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Minimize to the tray icon and show pop-up alerts (starts hidden after a login restart)'; Location = '10,70'; Size = '610,22'; Checked = [bool]($set -and $set.tray) }
$l4a = New-Object Windows.Forms.Label -Property @{ Text = 'Phone alerts (ntfy.sh topic):'; Location = '10,110'; AutoSize = $true }
$ntfyBox = New-Object Windows.Forms.TextBox -Property @{ Location = '170,106'; Width = 240; Text = $script:ntfy }
$ntfyTest = New-Object Windows.Forms.Button -Property @{ Text = 'Send test'; Location = '420,104'; Size = '90,26' }
$l4b = New-Object Windows.Forms.Label -Property @{ Location = '10,142'; Size = '610,140'; ForeColor = 'DimGray'
    Text = "Install the free ntfy app on your phone and subscribe to the same topic. Use a long random topic: anyone who knows it can read the alerts. Letters, digits, - and _ only. Leave empty for no alerts.`r`n`r`nSent for: outage start, recovery (with cause and fix), PC restarts, and PC back after a restart. An alert sent while the internet is down only arrives once it is back, so the recovery message is the reliable one." }
$t4.Controls.AddRange(@($chkAwake, $chkUpd, $chkTray, $l4a, $ntfyBox, $ntfyTest, $l4b))
$ni = New-Object Windows.Forms.NotifyIcon -Property @{ Icon = [Drawing.SystemIcons]::Application; Text = 'NetRefresh'; Visible = $chkTray.Checked }
$ni.ContextMenu = New-Object Windows.Forms.ContextMenu
[void]$ni.ContextMenu.MenuItems.Add('Open', { $f.Show(); $f.WindowState = 'Normal'; $f.Activate() })
[void]$ni.ContextMenu.MenuItems.Add('Exit', { $f.Close() })
$ni.Add_DoubleClick({ $f.Show(); $f.WindowState = 'Normal'; $f.Activate() })
$f.Add_Resize({ if ($chkTray.Checked -and $f.WindowState -eq 'Minimized') { $f.Hide() } })
$f.Add_FormClosed({ $ni.Visible = $false; $ni.Dispose() })
$pg.Add_Paint({ Draw-Graph $_.Graphics $pg.ClientSize.Width $pg.ClientSize.Height $script:outs })

# ---------- helpers ----------
function Log($m) {
    $line = "[{0:dd.MM HH:mm:ss}] $m" -f (Get-Date)
    $box.AppendText("$line`r`n"); Add-Content $logf $line
    [Windows.Forms.Application]::DoEvents()
}
function Send-Ntfy($title, $msg) {   # phone alert through ntfy.sh; the topic name is the only secret
    Invoke-RestMethod -Uri "https://ntfy.sh/$($script:ntfy)" -Method Post -Body $msg -Headers @{ Title = $title } -TimeoutSec 6 | Out-Null
}
function Notify($title, $msg) {
    if ($script:ntfy) { try { Send-Ntfy $title $msg } catch { } }   # an alert must never break the watchdog
    if ($ni -and $chkTray -and $chkTray.Checked) { $ni.ShowBalloonTip(5000, $title, $msg, 'Info') }
}
function Save-Outs {
    $script:outs | Select-Object @{n = 'Start'; e = { $_.Start.ToString('s') } }, @{n = 'End'; e = { if ($_.End) { $_.End.ToString('s') } else { '' } } }, Cause, Fix |
        Export-Csv $csv -NoTypeInformation
}
function Save-Settings {
    @{ time = $pick.Value.ToString('HH:mm'); armed = [bool]$script:next; reboot = $chkRb.Checked; fullRestart = $chkFull.Checked; watchCrd = $chkCrd.Checked; watchTs = $chkTs.Checked; keepAwake = $chkAwake.Checked; tray = $chkTray.Checked; ntfy = $script:ntfy; launch = [string]$combo.SelectedItem; lastReboot = $script:lastReboot.ToString('s') } | ConvertTo-Json | Set-Content $cfg
}
function Refresh-History {
    $wk = @($script:outs | Where-Object { $_.Start -gt [datetime]::Today.AddDays(-6) })
    $mins = 0; foreach ($o in $wk) { $mins += (($(if ($o.End) { $o.End } else { Get-Date })) - $o.Start).TotalMinutes }
    $hrs = $wk | Group-Object { $_.Start.Hour } | Sort-Object Count -Descending | Select-Object -First 1
    $sum.Text = "Last 7 days: $($wk.Count) drops, $([int]$mins) min down" + $(if ($hrs) { ", most often around $('{0:00}' -f [int]$hrs.Name):00" })
    $lv.Items.Clear()
    foreach ($o in @($script:outs | Sort-Object Start -Descending | Select-Object -First 100)) {
        $dur = if ($o.End) { "$([int]($o.End - $o.Start).TotalMinutes) min" } else { 'ongoing' }
        $fix = if ($o.Fix) { $o.Fix } elseif ($o.End) { 'self-recovered' } else { '-' }
        [void]$lv.Items.Add([Windows.Forms.ListViewItem]::new([string[]]@($o.Start.ToString('dd.MM HH:mm'), $dur, $o.Cause, $fix)))
    }
    $pg.Invalidate()
}
function Get-ConsoleUser { (Get-CimInstance Win32_ComputerSystem).UserName }
# Windows decides who auto-logs in (Winlogon); we can only check it matches the user running this app
function Update-Login {
    $me = ((Get-ConsoleUser) -split '\\')[-1]
    $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ($w.AutoAdminLogon -ne '1') { $lblLogin.Text = "Auto-login is OFF. To turn it on for ${me}: Win+R, netplwiz, select $me."; $lblLogin.ForeColor = 'Firebrick' }
    elseif ($w.DefaultUserName -notmatch [regex]::Escape($me)) { $lblLogin.Text = "WARNING: auto-login is set for '$($w.DefaultUserName)', not $me."; $lblLogin.ForeColor = 'Firebrick' }
    else { $lblLogin.Text = "Auto-login is ON for $me."; $lblLogin.ForeColor = 'DarkGreen' }
}
function Set-Next { $n = [datetime]::Today.Add($pick.Value.TimeOfDay); if ($n -le (Get-Date)) { $n = $n.AddDays(1) }; $script:next = $n }
function Run-Reset($mode) { $f.Cursor = 'WaitCursor'; try { Reset-Net ${function:Log} $mode } finally { $f.Cursor = 'Default' } }
function Arm { Set-Next; $btn.Text = 'Stop'; Log "Started, next run $($script:next.ToString('dd.MM HH:mm'))"; Save-Settings }

function Check-Health {
    $h = Get-Health
    if ($h -eq 'ok') {
        $script:fails = 0
        if ($script:cur) {
            $c = $script:cur; $c.End = Get-Date
            if (-not $c.Fix) { $c.Fix = 'self-recovered' }
            Save-Outs; $script:cur = $null; $script:stage = 0
            Log "Internet back UP after $([int]($c.End - $c.Start).TotalMinutes) min. Cause: $($c.Cause). Fixed by: $($c.Fix)"
            Notify 'NetRefresh: back UP' "Down $([int]($c.End - $c.Start).TotalMinutes) min. Cause: $($c.Cause). Fixed by: $($c.Fix)"
            Refresh-History
        }
        return
    }
    if ($script:fails -eq 0) { $script:firstFail = Get-Date }
    $script:fails++
    if ($script:fails -ge 3 -and -not $script:cur) {   # 3 failed checks in a row (~30 s) = real outage
        $script:kind = $h
        $script:cur = [pscustomobject]@{ Start = $script:firstFail; End = $null; Cause = (Diagnose $h); Fix = '' }
        [void]$script:outs.Add($script:cur); Save-Outs
        Log "Internet DOWN since $($script:firstFail.ToString('HH:mm:ss')). Cause: $($script:cur.Cause)"
        Notify 'NetRefresh: DOWN' "Since $($script:firstFail.ToString('HH:mm:ss')). Cause: $($script:cur.Cause)"
        Refresh-History
    }
    if (-not $script:cur -or $script:kind -eq 'tslogin') { return }   # logged out of Tailscale: nothing to restart
    # escalation ladder, each rung once per outage; Tailscale-only problems never go past a service restart
    $d = ((Get-Date) - $script:cur.Start).TotalSeconds
    $tsOnly = $script:kind -in 'tailscale', 'crd'   # remote-tool-only problems: restart that service, never reboot
    if ($script:stage -lt 1 -and $d -ge 90) {
        $script:stage = 1; $script:cur.Fix = 'soft reset'; Save-Outs; Run-Reset $(if ($tsOnly) { 'tailscale' } else { 'soft' })
    } elseif ($script:stage -eq 1 -and $d -ge 300) {
        $script:stage = 2; $script:cur.Fix = 'hard reset'; Save-Outs; Run-Reset $(if ($tsOnly) { 'tailscale' } else { 'hard' })
    } elseif ($script:stage -eq 2 -and $d -ge 900 -and -not $tsOnly -and $chkRb.Checked) {
        $script:stage = 3
        if (((Get-Date) - $script:lastReboot).TotalHours -ge 3) {
            $script:cur.Fix = 'reboot'; Save-Outs; $script:lastReboot = Get-Date; Save-Settings
            Log 'Still down after 15 min: REBOOTING in 30 s'
            Notify 'NetRefresh: rebooting' 'Internet down 15 min even after resets: the PC reboots in 30 s.'
            $null = Exec shutdown '/r /t 30 /c "NetRefresh: internet down 15 min"'
        } else { Log 'Still down, but already rebooted <3 h ago: not rebooting again' }
    }
}

# ---------- wiring ----------
$btn.Add_Click({
    if ($script:next) { $script:next = $null; $btn.Text = 'Start'; $stat.Text = 'Stopped'; Log 'Stopped'; Save-Settings } else { Arm }
})
$pick.Add_ValueChanged({ if ($script:next) { Set-Next; Log "Next run $($script:next.ToString('dd.MM HH:mm'))" }; Save-Settings })
$chkRb.Add_Click({ Save-Settings })
$chkFull.Add_Click({ Save-Settings })
$chkCrd.Add_Click({ $script:watchCrd = $chkCrd.Checked; Save-Settings })
$chkTs.Add_Click({ $script:watchTs = $chkTs.Checked; Save-Settings })
$chkAwake.Add_Click({ [Lsa]::KeepAwake($chkAwake.Checked); Save-Settings; Log "Keep-awake $(if ($chkAwake.Checked) {'on'} else {'off'})" })
$chkTray.Add_Click({ $ni.Visible = $chkTray.Checked; Save-Settings })
$chkUpd.Add_Click({
    try {
        if ($chkUpd.Checked) { New-Item $au -Force | Out-Null; New-ItemProperty $au -Name NoAutoRebootWithLoggedOnUsers -PropertyType DWord -Value 1 -Force | Out-Null; Log 'Windows Update auto-restart blocked while signed in' }
        else { Remove-ItemProperty $au -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue; Log 'Windows Update auto-restart allowed again' }
    } catch { $chkUpd.Checked = -not $chkUpd.Checked; [void][Windows.Forms.MessageBox]::Show("Failed (needs admin): $_", 'NetRefresh') }
})
$ntfyBox.Add_Leave({ $script:ntfy = $ntfyBox.Text -replace '[^A-Za-z0-9_-]', ''; $ntfyBox.Text = $script:ntfy; Save-Settings })
$ntfyTest.Add_Click({
    $script:ntfy = $ntfyBox.Text -replace '[^A-Za-z0-9_-]', ''; $ntfyBox.Text = $script:ntfy; Save-Settings
    if (-not $script:ntfy) { [void][Windows.Forms.MessageBox]::Show('Type a topic first.', 'NetRefresh'); return }
    try { Send-Ntfy 'NetRefresh test' 'If you can read this, phone alerts work.'; Log 'Test alert sent' } catch { Log "Test alert failed: $_" }
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
# started by the login task (-Boot): open the chosen app once, 30 s later so the network is up
$script:launchAt = if ($Boot) { (Get-Date).AddSeconds(30) } else { $null }
$chkAuto.Add_Click({
    if ($chkAuto.Checked) {
        $act = if ($ExePath) { New-ScheduledTaskAction -Execute $ExePath -Argument '-Boot' }
               else { New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Boot" }
        $cu = Get-ConsoleUser   # the person actually sitting at the PC, even if UAC elevated with another admin account
        Register-ScheduledTask NetRefresh -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $cu) `
            -Principal (New-ScheduledTaskPrincipal -UserId $cu -RunLevel Highest) -Force | Out-Null
        Log "Will start when $cu logs in"
        Update-Login
    } else { Unregister-ScheduledTask NetRefresh -Confirm:$false; Log 'Autostart removed' }
})
$now.Add_Click({ Run-Reset 'soft' })
# test of the last-resort reboot: checks the whole chain (auto-login, autostart, Claude opening) without waiting for an outage
$rb.Add_Click({
    $ask = "Restart this PC in 30 seconds?`n`nSave your work first. Press 'Cancel restart' in the app to stop it."
    if ([Windows.Forms.MessageBox]::Show($ask, 'Test PC restart', 'YesNo', 'Warning') -ne 'Yes') { return }
    Log 'TEST: restarting the PC in 30 s'
    [void](Exec shutdown '/r /t 30 /c "NetRefresh: test restart"')
})
$rbCancel.Add_Click({ [void](Exec shutdown '/a'); Log 'Restart cancelled (if one was pending)' })
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
    } catch { [void][Windows.Forms.MessageBox]::Show("Failed: $_", 'NetRefresh') } finally { $pass.Clear(); $pw = $null }
    Update-Login
})
$disable.Add_Click({
    try { [Lsa]::SetSecret('DefaultPassword', $null) } catch { }   # fine if there was none
    Remove-ItemProperty $wl DefaultPassword -ErrorAction SilentlyContinue
    Set-ItemProperty $wl AutoAdminLogon '0'
    Log 'Auto-login disabled'; Update-Login
})

[Lsa]::KeepAwake($chkAwake.Checked)   # tied to this (UI) thread, which lives as long as the app
if ($Boot -and $chkTray.Checked) { $f.Add_Shown({ $f.Hide() }) }
$t = New-Object Windows.Forms.Timer -Property @{ Interval = 1000 }
$t.Add_Tick({
    if ($script:busy) { return }   # Log() pumps messages; don't re-enter a running reset
    $script:busy = $true
    try {
        if ($script:launchAt -and (Get-Date) -ge $script:launchAt) {
            $script:launchAt = $null
            $id = $script:apps[[string]$combo.SelectedItem]
            if ($id) { Log "Opening $($combo.SelectedItem)"; Start-Process explorer.exe "shell:AppsFolder\$id" }
            Notify 'NetRefresh: PC is back' 'The PC started and NetRefresh is running.'
        }
        if ($script:next) {
            $stat.Text = "Next run in {0:hh\:mm\:ss}" -f ($script:next - (Get-Date))
            if ((Get-Date) -ge $script:next) {
                # full restart, unless the PC was restarted in the last 10 min (loop guard); Cancel restart still works for 30 s
                if ($chkFull.Checked -and ((Get-Date) - $script:lastReboot).TotalMinutes -ge 10) {
                    $script:lastReboot = Get-Date; Save-Settings
                    Log 'Scheduled full restart: PC restarts in 30 s'
                    Notify 'NetRefresh: restarting' 'Scheduled daily restart: the PC restarts in 30 s.'
                    [void](Exec shutdown '/r /t 30 /c "NetRefresh: scheduled daily restart"')
                } else { Run-Reset 'soft' }
                Set-Next; Log "Next run $($script:next.ToString('dd.MM HH:mm'))" }
        }
        if (++$script:ping -ge 10) { $script:ping = 0; Check-Health }
        if (++$script:hist -ge 60) { $script:hist = 0; Refresh-History; Update-Login }   # keeps an ongoing outage growing
    } finally { $script:busy = $false }
})
$t.Start()
Log 'Watching the connection every 10 s. Leave this window open.'
Refresh-History
Update-Login; Log $lblLogin.Text
if ($set -and $set.armed) { Arm }
[void]$f.ShowDialog()
