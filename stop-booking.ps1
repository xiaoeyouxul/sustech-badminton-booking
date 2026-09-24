$ErrorActionPreference = 'Stop'
$pidFile = Join-Path $PSScriptRoot 'booking.pid.json'

if (-not (Test-Path -LiteralPath $pidFile)) {
    Write-Host '没有发现当前文件夹中正在运行的预约脚本。'
    exit 0
}

$saved = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
$target = Get-Process -Id ([int]$saved.process_id) -ErrorAction SilentlyContinue
if ($null -eq $target -or
    $target.ProcessName -notin @('powershell', 'pwsh') -or
    $target.StartTime.ToUniversalTime().Ticks -ne [long]$saved.start_ticks) {
    Remove-Item -LiteralPath $pidFile -Force
    Write-Host '预约脚本已经结束。'
    exit 0
}

Stop-Process -Id $target.Id -Force -ErrorAction Stop
Remove-Item -LiteralPath $pidFile -Force
Write-Host ("已停止预约脚本，进程 ID：{0}" -f $target.Id)
