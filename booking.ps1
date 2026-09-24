param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Inspect,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$bookingProcess = Get-Process -Id $PID
@{ process_id = $PID; start_ticks = $bookingProcess.StartTime.ToUniversalTime().Ticks } |
    ConvertTo-Json -Compress |
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'booking.pid.json') -Encoding ASCII
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeUi {
    public struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out NativeRect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);
}
'@
[void][NativeUi]::SetProcessDPIAware()

function Log([string]$Message) {
    $line = '[{0:HH:mm:ss.fff}] {1}' -f (Get-Date), $Message
    Write-Host $line
    if (-not $Inspect) { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'booking.log') -Value $line -Encoding UTF8 }
}

function Rect-OK($Element) {
    try {
        $r = $Element.Current.BoundingRectangle
        return (-not $Element.Current.IsOffscreen -and $r.Width -gt 2 -and $r.Height -gt 2)
    } catch { return $false }
}

function Elements($Root) {
    if ($null -eq $Root) { return @() }
    try {
        return @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
    } catch { return @() }
}

function Find-Text($Root, [string]$Text, [switch]$Exact) {
    if ($null -eq $Root) { return $null }
    $candidates = if ($Exact) {
        try {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $Text)
            @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))
        } catch { @() }
    } else {
        Elements $Root
    }
    $matches = foreach ($e in $candidates) {
        try {
            if (-not (Rect-OK $e)) { continue }
            $name = [string]$e.Current.Name
            if (($Exact -and $name.Trim() -eq $Text) -or (-not $Exact -and $name.Contains($Text))) { $e }
        } catch { }
    }
    if (@($matches).Count -eq 0) { return $null }
    return @($matches | Sort-Object { $_.Current.BoundingRectangle.Width * $_.Current.BoundingRectangle.Height })[0]
}

function Wait-Text($Root, [string]$Text, [int]$TimeoutSeconds = 8, [switch]$Exact) {
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $hit = Find-Text $Root $Text -Exact:$Exact
        if ($null -ne $hit) { return $hit }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $until)
    return $null
}

function Click-Element($Element) {
    if (-not (Rect-OK $Element)) { return $false }
    $r = $Element.Current.BoundingRectangle
    $x = [int]($r.Left + $r.Width / 2)
    $y = [int]($r.Top + $r.Height / 2)
    [void][NativeUi]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 80
    [NativeUi]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NativeUi]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 180
    return $true
}

function Click-Text($Root, [string]$Text, [switch]$Exact) {
    $e = Find-Text $Root $Text -Exact:$Exact
    if ($null -eq $e) { return $false }
    return Click-Element $e
}

function Click-WindowRatio($Window, [double]$XRatio, [double]$YRatio) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $rect = New-Object NativeUi+NativeRect
    if ($handle -eq [IntPtr]::Zero -or -not [NativeUi]::GetWindowRect($handle, [ref]$rect)) {
        throw '无法取得企业微信窗口位置'
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 800 -or $height -lt 600) { throw '企业微信窗口未正确最大化' }
    $x = [int]($rect.Left + $width * $XRatio)
    $y = [int]($rect.Top + $height * $YRatio)
    [void][NativeUi]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 80
    [NativeUi]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NativeUi]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Top-Windows {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    return @($root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))
}

function Proc-Name($Window) {
    try { return (Get-Process -Id $Window.Current.ProcessId -ErrorAction Stop).ProcessName } catch { return '' }
}

function Find-WeCom {
    foreach ($w in (Top-Windows)) {
        if ((Proc-Name $w) -eq 'WXWork') { return $w }
    }
    return $null
}

function Find-BookingWindow {
    foreach ($w in (Top-Windows)) {
        try {
            $name = [string]$w.Current.Name
            if ($name -match 'reservation\.sustech') { return $w }
            if ((Proc-Name $w) -match 'WXWorkWeb|msedge|chrome' -and $name -match '场地预约') { return $w }
        } catch { }
    }
    return $null
}

function Focus-Maximize($Window) {
    $h = [IntPtr]$Window.Current.NativeWindowHandle
    if ($h -eq [IntPtr]::Zero) { throw '找到了预约页，但无法取得窗口句柄' }
    [void][NativeUi]::ShowWindow($h, 3)
    [void][NativeUi]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 350
}

function Scroll-In($Window, [int]$Steps = 5, [switch]$Modal) {
    $r = $Window.Current.BoundingRectangle
    $x = [int]($r.Left + $r.Width / 2)
    $y = [int]($r.Top + $r.Height * $(if ($Modal) { 0.5 } else { 0.65 }))
    [void][NativeUi]::SetCursorPos($x, $y)
    for ($i = 0; $i -lt $Steps; $i++) {
        [NativeUi]::mouse_event(0x0800, 0, 0, -120, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 90
    }
}

function Scroll-To-Top($Window) {
    $r = $Window.Current.BoundingRectangle
    [void][NativeUi]::SetCursorPos([int]($r.Left+$r.Width/2), [int]($r.Top+$r.Height*0.65))
    for ($i=0; $i -lt 24; $i++) {
        [NativeUi]::mouse_event(0x0800, 0, 0, 120, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 20
    }
}

function Inspect-Window($Window) {
    $terms = '工作台|校园场馆|场地预约|预约须知|协议|润扬|号场|今天|明天|后天|选择日期|预约时间|使用人数|手机号码|已满|预约成功|我的'
    $names = foreach ($e in (Elements $Window)) {
        try {
            $n = [string]$e.Current.Name
            if ((Rect-OK $e) -and $n -match $terms -and $n.Length -lt 90) { $n }
        } catch { }
    }
    $names | Sort-Object -Unique | Select-Object -First 100
}

function Wait-BookingWindow([int]$TimeoutSeconds, [int]$ProgressSeconds = 0) {
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastProgress = Get-Date
    do {
        $browser = Find-BookingWindow
        if ($null -ne $browser) { return $browser }
        if ($ProgressSeconds -gt 0 -and ((Get-Date) - $lastProgress).TotalSeconds -ge $ProgressSeconds) {
            Log '仍在等待独立的场地预约弹窗'
            $lastProgress = Get-Date
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $until)
    return $null
}

function Open-Booking {
    $browser = Find-BookingWindow
    if ($null -ne $browser) { Focus-Maximize $browser; return $browser }
    $wecom = Find-WeCom
    if ($null -eq $wecom) { throw '未找到企业微信。请先登录并打开电脑版企业微信。' }
    Focus-Maximize $wecom
    Log '已放大企业微信，开始打开工作台'
    try {
        $positionOnly = $false
        if (-not (Click-Text $wecom '工作台' -Exact)) {
            $positionOnly = $true
            Log '未读到工作台控件，按电脑版截图中的左侧位置点击'
            Click-WindowRatio $wecom 0.016 0.529
        }
        Start-Sleep -Milliseconds 650
        Log '尝试打开校园场馆/会议预约系统'
        $appCard = if ($positionOnly) { $null } else { Wait-Text $wecom '校园场馆/会议预约系统' 2 }
        if ($null -eq $appCard -or -not (Click-Element $appCard)) {
            Click-WindowRatio $wecom 0.938 0.294
        }
        Start-Sleep -Milliseconds 850
        Log '尝试点击底部场地预约'
        $bookingTab = if ($positionOnly) { $null } else { Wait-Text $wecom '场地预约' 2 -Exact }
        if ($null -eq $bookingTab -or -not (Click-Element $bookingTab)) {
            Click-WindowRatio $wecom 0.267 0.982
        }
    } catch {
        Log ('企业微信自动导航未完成：' + $_.Exception.Message)
    }
    Log '正在等待独立的场地预约弹窗（最多 8 秒）'
    $browser = Wait-BookingWindow 8
    if ($null -ne $browser) { Focus-Maximize $browser; return $browser }
    Log '未检测到预约弹窗。请手动打开「工作台 → 校园场馆/会议预约系统 → 场地预约」；程序再等待 30 秒。'
    $browser = Wait-BookingWindow 30 5
    if ($null -ne $browser) { Focus-Maximize $browser; return $browser }
    throw '预约弹窗未出现。请先在企业微信中打开场地预约弹窗，再运行程序。'
}

function Accept-Notice($Browser) {
    Log '检查场地预约须知'
    if ($null -eq (Find-Text $Browser '场地预约须知' -Exact)) { return }
    for ($i = 0; $i -lt 36; $i++) {
        if ($i -gt 0 -and $i % 8 -eq 0) { Log '仍在下滑场地预约须知' }
        $agree = Find-Text $Browser '同意本条款' -Exact
        if ($null -ne $agree) {
            try { $enabled = $agree.Current.IsEnabled } catch { $enabled = $false }
            if ($enabled -and (Click-Element $agree)) {
                if ($null -eq (Wait-Text $Browser '场地预约须知' 2 -Exact)) {
                    Log '已同意场地预约须知'
                    return
                }
                Log '同意按钮尚未生效，继续下滑须知'
            }
        }
        Scroll-In $Browser 2 -Modal
    }
    throw '未能滚动到须知底部并确认「同意本条款」，请手动检查页面'
}

function Open-Venue($Browser) {
    Log '寻找润扬羽毛球馆'
    Scroll-To-Top $Browser
    for ($i = 0; $i -lt 16; $i++) {
        if (Click-Text $Browser '润扬羽毛球馆' -Exact) {
            Start-Sleep -Milliseconds 350
            return
        }
        Scroll-In $Browser 2
    }
    throw '未找到润扬羽毛球馆'
}

function Open-Court($Browser, [int]$Court) {
    $label = "${Court}号场"
    Scroll-To-Top $Browser
    for ($i = 0; $i -lt 12; $i++) {
        $hit = Find-Text $Browser $label
        if ($null -ne $hit -and (Click-Element $hit)) {
            Start-Sleep -Milliseconds 300
            if ($null -ne (Wait-Text $Browser '预约时间' 5)) { return $true }
        }
        Scroll-In $Browser 2
    }
    return $false
}

function Select-Day($Browser, [datetime]$Day) {
    $offset = [int]($Day.Date - (Get-Date).Date).TotalDays
    $label = switch ($offset) { 0 { '今天' } 1 { '明天' } 2 { '后天' } default { throw '目标日期不在今天、明天、后天范围内' } }
    if (-not (Click-Text $Browser $label -Exact)) { throw "未找到日期选项 $label" }
    Start-Sleep -Milliseconds 250
}

function Slot-Labels([string]$Start, [string]$End) {
    $cursor = [datetime]::ParseExact($Start, 'HH:mm', $null)
    $last = [datetime]::ParseExact($End, 'HH:mm', $null)
    if ($last -le $cursor -or $cursor.Minute % 30 -ne 0 -or $last.Minute % 30 -ne 0) { throw '时间必须是递增的半小时边界' }
    $result = @()
    while ($cursor -lt $last) {
        $next = $cursor.AddMinutes(30)
        $result += ('{0:H:mm}-{1:H:mm}' -f $cursor, $next)
        $cursor = $next
    }
    return $result
}

function Select-Slots($Browser, $Range) {
    $labels = @(Slot-Labels $Range.start $Range.end)
    foreach ($label in $labels) {
        $slot = Find-Text $Browser $label -Exact
        if ($null -eq $slot) { Log "时段不可用：$label"; return $false }
        try { if (-not $slot.Current.IsEnabled -or $slot.Current.Name -match '已满') { return $false } } catch { return $false }
        if (-not (Click-Element $slot)) { return $false }
        Start-Sleep -Milliseconds 180
    }
    $minutes = Read-BookingMinutes $Browser
    if ($null -eq $minutes) { throw '无法核对页面显示的预约时长，未提交' }
    if ($minutes -ne $labels.Count * 30) { Log '页面显示的预约时长与目标不一致'; return $false }
    return $true
}

function Read-BookingMinutes($Browser) {
    $anchor = Find-Text $Browser '预约时间'
    if ($null -eq $anchor) { return $null }
    $anchorRect = $anchor.Current.BoundingRectangle
    foreach ($e in (Elements $Browser)) {
        try {
            if (-not (Rect-OK $e)) { continue }
            $name = [string]$e.Current.Name
            if ($name -match '预约时间\s*[:：]?\s*(\d+)\s*分钟') { return [int]$Matches[1] }
            $r = $e.Current.BoundingRectangle
            if ($name -match '^\s*(\d+)\s*分钟\s*$' -and [Math]::Abs($r.Top-$anchorRect.Top) -lt 50) { return [int]$Matches[1] }
        } catch { }
    }
    return $null
}

function Fill-Near($Browser, [string]$Label, [string]$Value) {
    $direct = Find-Text $Browser $Label
    if ($null -eq $direct) { throw "未找到表单字段：$Label" }
    $labelRect = $direct.Current.BoundingRectangle
    $edits = foreach ($e in (Elements $Browser)) {
        try {
            if ((Rect-OK $e) -and $e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit) { $e }
        } catch { }
    }
    $closest = @($edits | Sort-Object { $r=$_.Current.BoundingRectangle; [Math]::Abs(($r.Top+$r.Height/2)-($labelRect.Top+$labelRect.Height/2)) + [Math]::Abs($r.Left-$labelRect.Right)/4 }) | Select-Object -First 1
    if ($closest.Count -eq 0) {
        if ($Label -eq '手机号码' -and $null -ne (Find-Text $Browser $Value -Exact)) { return }
        throw "无法识别 $Label 的输入框"
    }
    $editRect = $closest[0].Current.BoundingRectangle
    if ([Math]::Abs(($editRect.Top+$editRect.Height/2)-($labelRect.Top+$labelRect.Height/2)) -gt 80) {
        if ($Label -eq '手机号码' -and $null -ne (Find-Text $Browser $Value -Exact)) { return }
        throw "$Label 附近没有可确认的输入框"
    }
    [void](Click-Element $closest[0])
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    [System.Windows.Forms.SendKeys]::SendWait($Value)
    Start-Sleep -Milliseconds 120
}

function Try-Return($Browser) {
    if (Click-Text $Browser '返回' -Exact) { Start-Sleep -Milliseconds 300; return $true }
    return $false
}

function Reset-To-Courts($Browser) {
    for ($i=0; $i -lt 3; $i++) {
        if ($null -eq (Find-Text $Browser '预约时间')) {
            foreach ($e in (Elements $Browser)) {
                try { if ((Rect-OK $e) -and $e.Current.Name -match '(^|羽毛球馆)\s*\d+号场') { return $true } } catch { }
            }
        }
        if ($null -ne (Find-Text $Browser '润扬羽毛球馆' -Exact)) { Open-Venue $Browser; return $true }
        if (-not (Try-Return $Browser)) { return $false }
    }
    return $false
}

function Reopen-Venue($Browser) {
    for ($i=0; $i -lt 3; $i++) {
        $hasCourt = $false
        foreach ($e in (Elements $Browser)) {
            try { if ((Rect-OK $e) -and $e.Current.Name -match '(^|羽毛球馆)\s*\d+号场') { $hasCourt = $true; break } } catch { }
        }
        if (-not $hasCourt -and $null -ne (Find-Text $Browser '润扬羽毛球馆' -Exact)) {
            Open-Venue $Browser
            return $true
        }
        if (-not (Try-Return $Browser)) { return $false }
    }
    return $false
}

function Verify-Result($Browser, [int]$Court, $Range) {
    $until = (Get-Date).AddSeconds(7)
    do {
        if ($null -ne (Find-Text $Browser '预约成功')) { return 'success' }
        if ($null -ne (Find-Text $Browser '预约失败') -or $null -ne (Find-Text $Browser '已被预约')) { return 'rejected' }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $until)
    return 'unknown'
}

function Resolve-TargetDay([string]$DateSetting) {
    if ($DateSetting -eq 'auto_third_day') { return (Get-Date).Date.AddDays(2) }
    foreach ($format in @('yyyy-MM-dd', 'yyyy-M-d')) {
        try { return [datetime]::ParseExact($DateSetting, $format, [Globalization.CultureInfo]::InvariantCulture) }
        catch { }
    }
    throw 'date 请填 auto_third_day 或年月日，例如 2026-09-25'
}

function Validate-Config($Config) {
    $day = Resolve-TargetDay ([string]$Config.date)
    $offset = [int]($day.Date - (Get-Date).Date).TotalDays
    if ($offset -lt 0 -or $offset -gt 2) { throw 'date 必须是今天、明天或后天' }
    if (@($Config.time_ranges).Count -eq 0) { throw '请配置至少一个时间段' }
    foreach ($range in $Config.time_ranges) { [void](Slot-Labels $range.start $range.end) }
    if (@($Config.court_priority).Count -eq 0) { throw '请配置球场优先顺序' }
    $seen = @{}
    foreach ($court in $Config.court_priority) {
        if ([int]$court -lt 1 -or [int]$court -gt 10 -or $seen.ContainsKey([int]$court)) { throw '场号必须为不重复的 1–10' }
        $seen[[int]$court] = $true
    }
    if ([int]$Config.people -lt 1) { throw '使用人数必须大于 0' }
    if ([string]$Config.phone -notmatch '^\d{11}$') { throw '请在 config.json 填写 11 位手机号' }
}

try {
    if ($Inspect) {
        $browser = Open-Booking
        Inspect-Window $browser
        exit 0
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "找不到配置文件：$ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Validate-Config $config
    if ($ValidateOnly) { Write-Host '配置检查通过'; exit 0 }
    $browser = Open-Booking
    Log '已检测到预约弹窗并放大'
    Accept-Notice $browser
    if ($null -eq (Find-Text $browser '润扬羽毛球馆' -Exact)) {
        if (-not (Click-Text $browser '场地预约' -Exact)) { throw '未找到场地预约首页' }
    }
    Open-Venue $browser
    $release = [datetime]::ParseExact([string]$config.release_time, 'HH:mm:ss', $null)
    if ($config.wait_for_release) {
        $deadline = (Get-Date).Date.Add($release.TimeOfDay)
        if ((Get-Date) -lt $deadline) {
            Log ("已就绪，等待 {0:HH:mm:ss} 开放" -f $deadline)
            $lastWaitLog = Get-Date
            while ((Get-Date) -lt $deadline) {
                $remaining = ($deadline - (Get-Date)).TotalSeconds
                if (((Get-Date) - $lastWaitLog).TotalSeconds -ge 30) {
                    Log ("正在等待开放，约剩 {0} 秒" -f [Math]::Ceiling($remaining))
                    $lastWaitLog = Get-Date
                }
                if ($remaining -gt 10) { Start-Sleep -Milliseconds 1000 }
                else { Start-Sleep -Milliseconds 100 }
            }
            Log '已到开放时间，开始尝试'
        }
    }
    $pairs = @()
    if ($config.priority_mode -eq 'court_first') {
        foreach ($court in $config.court_priority) { foreach ($range in $config.time_ranges) { $pairs += [pscustomobject]@{ Court=[int]$court; Range=$range } } }
    } else {
        foreach ($range in $config.time_ranges) { foreach ($court in $config.court_priority) { $pairs += [pscustomobject]@{ Court=[int]$court; Range=$range } } }
    }
    $attempts = 0
    $resets = 0
    $backs = 0
    foreach ($pair in $pairs) {
        if ($attempts -ge [int]$config.max_attempts) { break }
        $attempts++
        Log ("尝试第 {0} 项：{1} 号场 {2}–{3}" -f $attempts, $pair.Court, $pair.Range.start, $pair.Range.end)
        if (-not (Open-Court $browser $pair.Court)) {
            $resets++
            if ($resets -gt [int]$config.max_navigation_resets -or -not (Reset-To-Courts $browser)) { throw '无法稳定进入目标球场，已停止' }
            continue
        }
        $targetDay = Resolve-TargetDay ([string]$config.date)
        Select-Day $browser $targetDay
        if (-not (Select-Slots $browser $pair.Range)) {
            Log '所选时段已满或无法点击'
            if (-not (Try-Return $browser)) {
                $resets++
                if ($resets -gt [int]$config.max_navigation_resets -or -not (Reopen-Venue $browser)) { throw '回退失败，已停止' }
                $backs = 0
            } else {
                $backs++
                if ($backs -ge 2) {
                    $resets++
                    if ($resets -gt [int]$config.max_navigation_resets -or -not (Reopen-Venue $browser)) { throw '回退过多，重新进入球馆失败' }
                    $backs = 0
                }
            }
            continue
        }
        $backs = 0
        Fill-Near $browser '使用人数' ([string]$config.people)
        Fill-Near $browser '手机号码' ([string]$config.phone)
        if ($config.dry_run) { Log '试运行已填写表单，未提交'; exit 0 }
        if (-not (Click-Text $browser '预约' -Exact)) { throw '找不到预约按钮，未提交' }
        $result = Verify-Result $browser $pair.Court $pair.Range
        if ($result -eq 'success') { Log '页面显示预约成功，请在我的预约中核对详情'; exit 0 }
        if ($result -eq 'unknown') { throw '提交状态不明，请手动检查我的预约；程序不会重复提交' }
        Log '预约被拒绝，改试下一个备选项'
        $resets++
        if ($resets -gt [int]$config.max_navigation_resets -or -not (Reopen-Venue $browser)) { throw '重进球馆失败，已停止' }
    }
    Log '备选球场和时段已尝试完毕，未预约成功'
} catch {
    Log ("已停止：" + $_.Exception.Message)
    exit 1
}
