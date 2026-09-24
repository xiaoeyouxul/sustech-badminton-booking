param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Inspect,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out NativeRect rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr hDC, int x, int y);
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

function Register-BookingProcess {
    $pidFile = Join-Path $PSScriptRoot 'booking.pid.json'
    if (Test-Path -LiteralPath $pidFile) {
        $saved = $null
        try { $saved = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json } catch { }
        if ($null -ne $saved) {
            $existing = Get-Process -Id ([int]$saved.process_id) -ErrorAction SilentlyContinue
            if ($null -ne $existing -and
                $existing.ProcessName -in @('powershell', 'pwsh') -and
                $existing.StartTime.ToUniversalTime().Ticks -eq [long]$saved.start_ticks) {
                throw '已有预约脚本正在运行。请先双击 stop-booking.cmd 停止它。'
            }
        }
    }
    $bookingProcess = Get-Process -Id $PID
    @{ process_id = $PID; start_ticks = $bookingProcess.StartTime.ToUniversalTime().Ticks } |
        ConvertTo-Json -Compress |
        Set-Content -LiteralPath $pidFile -Encoding ASCII
}

function Click-WindowRatio($Window, [double]$XRatio, [double]$YRatio) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $rect = New-Object NativeUi+NativeRect
    if ($handle -eq [IntPtr]::Zero -or -not [NativeUi]::GetWindowRect($handle, [ref]$rect)) {
        throw '无法取得窗口位置'
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 800 -or $height -lt 600) { throw '窗口未正确最大化' }
    $x = [int]($rect.Left + $width * $XRatio)
    $y = [int]($rect.Top + $height * $YRatio)
    [void][NativeUi]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 80
    [NativeUi]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [NativeUi]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Get-WindowPixel($Window, [double]$XRatio, [double]$YRatio) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $rect = New-Object NativeUi+NativeRect
    if ($handle -eq [IntPtr]::Zero -or -not [NativeUi]::GetWindowRect($handle, [ref]$rect)) {
        throw '无法读取预约窗口位置'
    }
    $x = [int]($rect.Left + ($rect.Right - $rect.Left) * $XRatio)
    $y = [int]($rect.Top + ($rect.Bottom - $rect.Top) * $YRatio)
    $dc = [NativeUi]::GetDC([IntPtr]::Zero)
    if ($dc -eq [IntPtr]::Zero) { throw '无法读取屏幕颜色' }
    try { $color = [NativeUi]::GetPixel($dc, $x, $y) }
    finally { [void][NativeUi]::ReleaseDC([IntPtr]::Zero, $dc) }
    if ($color -eq [uint32]::MaxValue) { throw '无法读取预约窗口像素' }
    return [pscustomobject]@{
        R = [int]($color -band 0xFF)
        G = [int](($color -shr 8) -band 0xFF)
        B = [int](($color -shr 16) -band 0xFF)
    }
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
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        [void][NativeUi]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 250
        if ([NativeUi]::GetForegroundWindow() -eq $h) { break }
    }
    if ([NativeUi]::GetForegroundWindow() -ne $h) { throw '无法将目标窗口置于前台，请先关闭遮挡窗口再重试' }
    $rect = New-Object NativeUi+NativeRect
    $workArea = [System.Windows.Forms.Screen]::FromHandle($h).WorkingArea
    if (-not [NativeUi]::GetWindowRect($h, [ref]$rect) -or
        ($rect.Right - $rect.Left) -lt $workArea.Width * 0.9 -or
        ($rect.Bottom - $rect.Top) -lt $workArea.Height * 0.9) {
        throw '窗口未成功最大化，请先放大窗口再重试'
    }
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
    $terms = '工作台|校园场馆|场地预约|预约须知|协议|润[杨扬]|号场|今天|明天|后天|选择日期|预约时间|使用人数|手机号码|已满|预约成功|我的'
    $names = foreach ($e in (Elements $Window)) {
        try {
            $n = [string]$e.Current.Name
            if ((Rect-OK $e) -and $n -match $terms -and $n.Length -lt 90) { $n }
        } catch { }
    }
    $names | Sort-Object -Unique | Select-Object -First 100
}

function Scroll-To-Bottom($Window) {
    $r = $Window.Current.BoundingRectangle
    [void][NativeUi]::SetCursorPos([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height * 0.65))
    for ($i = 0; $i -lt 16; $i++) {
        [NativeUi]::mouse_event(0x0800, 0, 0, -120, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 15
    }
    Start-Sleep -Milliseconds 250
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

function Test-WorkbenchSelected($Wecom) {
    $sidebar = Get-WindowPixel $Wecom 0.01 0.52
    $tab = Get-WindowPixel $Wecom 0.10 0.034
    return (($sidebar.R -lt 210 -and $sidebar.G -lt 225 -and $sidebar.B -gt 230) -or
        ($tab.R -gt 240 -and $tab.G -gt 240 -and $tab.B -gt 240))
}

function Open-Booking {
    $browser = Find-BookingWindow
    if ($null -ne $browser) { Focus-Maximize $browser; return $browser }
    $wecom = Find-WeCom
    if ($null -eq $wecom) { throw '未找到企业微信。请先登录并打开电脑版企业微信。' }
    Focus-Maximize $wecom
    Log '已放大企业微信，开始打开工作台'
    try {
        if (-not (Test-WorkbenchSelected $wecom)) {
            if (-not (Click-Text $wecom '工作台' -Exact)) {
                Log '未读到工作台按钮，按最大化窗口的左侧位置点击'
                Click-WindowRatio $wecom 0.016 0.529
            }
            Start-Sleep -Milliseconds 500
            if (-not (Test-WorkbenchSelected $wecom)) {
                Log '尚未进入工作台，再尝试点击一次'
                Focus-Maximize $wecom
                Click-WindowRatio $wecom 0.016 0.529
                Start-Sleep -Milliseconds 500
                if (-not (Test-WorkbenchSelected $wecom)) {
                    throw '点击后仍未进入工作台'
                }
            }
        }
        Log '已确认进入工作台，打开校园场馆/会议预约系统'
        $appCard = Wait-Text $wecom '校园场馆/会议预约系统' 1
        if ($null -eq $appCard -or -not (Click-Element $appCard)) {
            Click-WindowRatio $wecom 0.938 0.294
        }
        Start-Sleep -Milliseconds 1500
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            Log ("尝试点击底部场地预约（第 {0} 次）" -f $attempt)
            Click-WindowRatio $wecom 0.267 0.982
            $browser = Wait-BookingWindow 3
            if ($null -ne $browser) { Focus-Maximize $browser; return $browser }
        }
    } catch {
        Log ('企业微信自动导航未完成：' + $_.Exception.Message)
    }
    Log '未检测到预约弹窗。请手动打开「工作台 → 校园场馆/会议预约系统 → 场地预约」；程序再等待 30 秒。'
    $browser = Wait-BookingWindow 30 5
    if ($null -ne $browser) { Focus-Maximize $browser; return $browser }
    throw '预约弹窗未出现。请先在企业微信中打开场地预约弹窗，再运行程序。'
}

function Find-Venue($Browser) {
    foreach ($label in @('润杨羽毛球馆', '润扬羽毛球馆')) {
        $venue = Find-Text $Browser $label -Exact
        if ($null -ne $venue) { return $venue }
    }
    return $null
}

function Scroll-Notice($Browser) {
    $handle = [IntPtr]$Browser.Current.NativeWindowHandle
    $r = New-Object NativeUi+NativeRect
    if (-not [NativeUi]::GetWindowRect($handle, [ref]$r)) { throw '无法读取预约窗口位置' }
    $x = [int]($r.Left + ($r.Right - $r.Left) * 0.5)
    $y = [int]($r.Top + ($r.Bottom - $r.Top) * 0.55)
    [void][NativeUi]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 80
    for ($step = 0; $step -lt 30; $step++) {
        [NativeUi]::mouse_event(0x0800, 0, 0, -120, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 25
    }
}

function Test-NoticeVisible($Browser) {
    $panel = Get-WindowPixel $Browser 0.46 0.23
    $shade = Get-WindowPixel $Browser 0.75 0.45
    return ($panel.R -gt 230 -and $panel.G -gt 230 -and $panel.B -gt 230 -and
        $shade.R -lt 150 -and $shade.G -lt 150 -and $shade.B -lt 150)
}

function Accept-Notice($Browser) {
    Focus-Maximize $Browser
    Log '检查场地预约须知（依据你提供的最大化窗口截图）'
    $until = (Get-Date).AddSeconds(6)
    while (-not (Test-NoticeVisible $Browser)) {
        if ((Get-Date) -ge $until) {
            throw '未能确认场地预约须知弹窗，请检查预约窗口是否最大化及浏览器缩放'
        }
        Start-Sleep -Milliseconds 250
    }
    for ($i = 0; $i -le 4; $i++) {
        $button = Get-WindowPixel $Browser 0.46 0.784
        if ($button.R -lt 70 -and $button.G -gt 140 -and $button.G -lt 230 -and $button.B -lt 150) {
            Log '已滚动到底部，点击「同意本条款」'
            Click-WindowRatio $Browser 0.50 0.795
            $until = (Get-Date).AddSeconds(3)
            do {
                Start-Sleep -Milliseconds 250
                if (-not (Test-NoticeVisible $Browser)) {
                    Log '须知弹窗已关闭'
                    return
                }
            } while ((Get-Date) -lt $until)
            throw '已点击同意本条款，但弹窗仍在；已停止避免重复点击'
        }
        if ($i -eq 4) { break }
        Log ("在须知内容区向下滚动（第 {0} 次）" -f ($i + 1))
        Scroll-Notice $Browser
        Start-Sleep -Milliseconds 300
    }
    throw '滚动后未看到可点击的「同意本条款」，请手动检查页面或重新校准窗口缩放'
}

function Open-Venue($Browser) {
    Log '打开场馆列表中的润杨羽毛球馆'
    Focus-Maximize $Browser
    Scroll-To-Top $Browser
    $before = Get-WindowPixel $Browser 0.05 0.25
    # The fifth venue card is partly visible above the bottom navigation on the maximized page.
    foreach ($attempt in 1..2) {
        if ($attempt -eq 2) {
            Log '场馆页面未变化，向下滚动后重试一次'
            Scroll-In $Browser 2
            Start-Sleep -Milliseconds 250
            $before = Get-WindowPixel $Browser 0.05 0.25
        }
        $y = if ($attempt -eq 1) { 0.925 } else { 0.82 }
        Click-WindowRatio $Browser 0.16 $y
        $until = (Get-Date).AddSeconds(2)
        do {
            Start-Sleep -Milliseconds 250
            $after = Get-WindowPixel $Browser 0.05 0.25
            $change = [Math]::Abs($after.R - $before.R) +
                [Math]::Abs($after.G - $before.G) +
                [Math]::Abs($after.B - $before.B)
            if ($change -gt 75) {
                Log '球场列表已打开'
                return
            }
        } while ((Get-Date) -lt $until)
    }
    throw '点击润杨羽毛球馆后页面未变化；已停止，请检查浏览器缩放和场馆列表位置'
}

function Open-Court($Browser, [int]$Court) {
    # Court cards are ordered as shown in the user's maximized desktop screenshots.
    $topPositions = @{ 5 = 0.20; 3 = 0.34; 8 = 0.47; 2 = 0.61; 1 = 0.75; 7 = 0.89 }
    $bottomPositions = @{ 9 = 0.45; 6 = 0.59; 4 = 0.72; 10 = 0.86 }
    if ($topPositions.ContainsKey($Court)) {
        Log ("定位 {0} 号场：滚动到球场列表顶部" -f $Court)
        Scroll-To-Top $Browser
        $y = $topPositions[$Court]
        $sampleY = 0.35
    } elseif ($bottomPositions.ContainsKey($Court)) {
        Log ("定位 {0} 号场：快速滚动到球场列表底部" -f $Court)
        Scroll-To-Bottom $Browser
        $y = $bottomPositions[$Court]
        $sampleY = $y
    } else {
        return $false
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $before = Get-WindowPixel $Browser 0.05 $sampleY
        Click-WindowRatio $Browser 0.16 $y
        $until = (Get-Date).AddSeconds(2)
        do {
            Start-Sleep -Milliseconds 250
            $after = Get-WindowPixel $Browser 0.05 $sampleY
            $change = [Math]::Abs($after.R - $before.R) +
                [Math]::Abs($after.G - $before.G) +
                [Math]::Abs($after.B - $before.B)
            if ($change -gt 75) {
                Start-Sleep -Milliseconds 750
                Log ("{0} 号场页面已打开" -f $Court)
                return $true
            }
        } while ((Get-Date) -lt $until)
        Log ("{0} 号场第 {1} 次点击后页面未变化" -f $Court, $attempt)
    }
    return $false
}

function Test-DaySelected($Browser, [double]$XRatio) {
    foreach ($dx in @(-0.01, 0, 0.01)) {
        for ($step = 0; $step -le 45; $step++) {
            $y = 0.36 + $step * 0.001
            $pixel = Get-WindowPixel $Browser ($XRatio + $dx) $y
            if ($pixel.R -lt 100 -and $pixel.G -gt 140 -and $pixel.G -lt 220 -and
                $pixel.B -gt 130 -and $pixel.B -lt 220) { return $true }
        }
    }
    return $false
}

function Select-Day($Browser, [datetime]$Day, [timespan]$ReleaseTime) {
    $now = Get-Date
    $offset = [int]($Day.Date - $now.Date).TotalDays
    $label = switch ($offset) { 0 { '今天' } 1 { '明天' } 2 { '后天' } default { throw '目标日期不在今天、明天、后天范围内' } }
    $tabCount = if ($now.TimeOfDay -ge $ReleaseTime) { 3 } else { 2 }
    if ($offset -ge $tabCount) { throw "目标日期 $($Day.ToString('yyyy-MM-dd')) 尚未开放，请在当天开放时间后运行" }
    $x = if ($tabCount -eq 3) { @(0.125, 0.375, 0.625)[$offset] } else { @(0.166, 0.5)[$offset] }
    Log ("选择 {0}（{1}，当前按 {2} 个日期选项定位）" -f $label, $Day.ToString('yyyy-MM-dd'), $tabCount)
    if ($offset -eq 0) {
        Log '球场页默认显示今天，沿用当前日期'
        return
    }
    $until = (Get-Date).AddSeconds(6)
    do {
        if (Test-DaySelected $Browser $x) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $until)
    Click-WindowRatio $Browser $x 0.367
    $until = (Get-Date).AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 150
        if (Test-DaySelected $Browser $x) { return }
    } while ((Get-Date) -lt $until)
    $handle = [IntPtr]$Browser.Current.NativeWindowHandle
    $rect = New-Object NativeUi+NativeRect
    if ([NativeUi]::GetWindowRect($handle, [ref]$rect)) {
        $pixel = Get-WindowPixel $Browser $x 0.388
        Log ("日期校验采样：窗口 {0}x{1}，选中线位置 RGB({2},{3},{4})" -f
            ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top), $pixel.R, $pixel.G, $pixel.B)
    }
    throw "点击 $label 后未确认选中；请检查日期栏是否已刷新"
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

function Slot-Position([string]$Label) {
    $start = [datetime]::ParseExact(($Label -split '-')[0], 'H:mm', $null)
    $index = [int](($start.Hour - 8) * 2 + $start.Minute / 30)
    if ($index -lt 0 -or $index -gt 29) { throw "时段不在页面显示的 08:00–23:00 范围：$Label" }
    $xPositions = @(0.058, 0.160, 0.262, 0.353, 0.455, 0.557, 0.649, 0.751, 0.853, 0.945)
    $yPositions = @(0.432, 0.493, 0.556)
    return [pscustomobject]@{ X = $xPositions[$index % 10]; Y = $yPositions[[int][Math]::Floor($index / 10)] }
}

function Test-SlotSelected($Browser, $Position) {
    $pixel = Get-WindowPixel $Browser $Position.X ($Position.Y - 0.013)
    return ($pixel.R -lt 100 -and $pixel.G -gt 140 -and $pixel.G -lt 220 -and
        $pixel.B -gt 130 -and $pixel.B -lt 220)
}

function Test-SlotAvailable($Browser, $Position) {
    for ($dx = -0.025; $dx -le 0.025; $dx += 0.004) {
        for ($dy = -0.008; $dy -le 0.008; $dy += 0.004) {
            $pixel = Get-WindowPixel $Browser ($Position.X + $dx) ($Position.Y + $dy)
            if ($pixel.R -lt 100 -and $pixel.G -gt 130 -and $pixel.G -lt 230 -and
                $pixel.B -gt 120 -and $pixel.B -lt 230) { return $true }
        }
    }
    return $false
}

function Select-Slots($Browser, $Range) {
    $labels = @(Slot-Labels $Range.start $Range.end)
    foreach ($label in $labels) {
        $position = Slot-Position $label
        if (Test-SlotSelected $Browser $position) { continue }
        if (-not (Test-SlotAvailable $Browser $position)) { Log "时段不可用：$label"; return $false }
        Click-WindowRatio $Browser $position.X $position.Y
        Start-Sleep -Milliseconds 180
        if (-not (Test-SlotSelected $Browser $position)) { throw "点击 $label 后未确认选中，已停止" }
    }
    $selected = 0
    foreach ($hour in 8..22) {
        foreach ($minute in @('00', '30')) {
            $position = Slot-Position ('{0}:{1}-{0}:{1}' -f $hour, $minute)
            if (Test-SlotSelected $Browser $position) { $selected++ }
        }
    }
    if ($selected -ne $labels.Count) { throw "页面选中的半小时格数为 $selected，目标为 $($labels.Count)；已停止" }
    Log ("已确认选中 {0} 个半小时格" -f $selected)
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
    if ($null -eq $direct) { Fill-VisibleField $Browser $Label $Value; return }
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
    Click-WindowRatio $Browser 0.028 0.095
    Start-Sleep -Milliseconds 350
    return $true
}

function Read-FocusedText {
    $previous = [System.Windows.Forms.Clipboard]::GetDataObject()
    try {
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        [System.Windows.Forms.SendKeys]::SendWait('^c')
        Start-Sleep -Milliseconds 120
        return [System.Windows.Forms.Clipboard]::GetText()
    } finally {
        if ($null -ne $previous) {
            $restored = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    [System.Windows.Forms.Clipboard]::SetDataObject($previous, $true, 5, 100)
                    $restored = $true
                    break
                } catch { Start-Sleep -Milliseconds 150 }
            }
            if (-not $restored) { Log '原剪贴板内容暂时无法恢复，请勿依赖本次复制的内容' }
        }
    }
}

function Fill-VisibleField($Browser, [string]$Label, [string]$Value) {
    $y = switch ($Label) { '使用人数' { 0.739 } '手机号码' { 0.700 } default { throw "未找到表单字段：$Label" } }
    Click-WindowRatio $Browser 0.11 $y
    $current = [string](Read-FocusedText)
    if ($current.Trim() -eq $Value) { Log ("已核对{0}" -f $Label); return }
    if ($Label -eq '手机号码' -and $current -match ('手机号码\s*[:：]?\s*' + [regex]::Escape($Value))) {
        Log '页面预填手机号与配置一致'
        return
    }
    if ($current.Length -gt 30) { throw "$Label 的输入框未获得焦点，已停止" }
    [System.Windows.Forms.SendKeys]::SendWait($Value)
    Start-Sleep -Milliseconds 150
    Click-WindowRatio $Browser 0.11 $y
    $entered = [string](Read-FocusedText)
    if ($entered.Trim() -ne $Value) { throw "$Label 填写后无法核对，已停止" }
    Log ("已填写并核对{0}" -f $Label)
}

function Reset-To-Courts($Browser) {
    for ($i=0; $i -lt 3; $i++) {
        if ($null -eq (Find-Text $Browser '预约时间')) {
            foreach ($e in (Elements $Browser)) {
                try { if ((Rect-OK $e) -and $e.Current.Name -match '(^|羽毛球馆)\s*\d+号场') { return $true } } catch { }
            }
        }
        if ($null -ne (Find-Venue $Browser)) { Open-Venue $Browser; return $true }
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
        if (-not $hasCourt -and $null -ne (Find-Venue $Browser)) {
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
        Register-BookingProcess
        $browser = Open-Booking
        Inspect-Window $browser
        exit 0
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "找不到配置文件：$ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Validate-Config $config
    if ($ValidateOnly) { Write-Host '配置检查通过'; exit 0 }
    Register-BookingProcess
    $browser = Open-Booking
    Log '已检测到预约弹窗并放大'
    Accept-Notice $browser
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
        Select-Day $browser $targetDay $release.TimeOfDay
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
        if (-not (Click-Text $browser '预约' -Exact)) {
            Log '未读到预约按钮，按可见页面底部位置点击'
            Click-WindowRatio $browser 0.50 0.780
        }
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
