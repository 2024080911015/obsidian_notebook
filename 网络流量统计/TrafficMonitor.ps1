#Requires -Version 5.1
<#
.SYNOPSIS
    TrafficMonitor —— 网络流量统计器（关机 / 重启后继续累计）

.DESCRIPTION
    网卡的原始收发字节计数器在每次开机（或网卡重新启用、驱动重载）后都会从 0 重新开始，
    因此直接把网卡计数器当成"总用量"是不行的。本脚本的做法是：

      1. 每隔 N 秒读取一次所有网卡的原始计数器（累计字节）；
      2. 与上一次保存的原始值相减得到增量，累加进持久化的账本 state.json；
      3. 若本次原始值小于上次记录值 —— 说明计数器归零（重启 / 网卡重置），
         则把当前原始值本身当作增量（即"本次开机以来的全部流量"）；
      4. 账本按 天 / 本次开机 / 总计 三个维度保存，并记录开机次数。

    由于账本在磁盘上，关机再开机后计数自动接着走，且开机到登录之间产生的流量也会被补计进来。

.PARAMETER Action
    status     查看当前用量（默认）
    run        进入后台监测循环（通常由计划任务调用）
    report     按天 / 按月出报表
    reset      清零账本，从当前时刻重新计数
    install    复制脚本到状态目录并注册开机自启计划任务
    uninstall  移除计划任务
    selftest   运行内置自检（校验增量算法与跨重启逻辑）
    help       显示帮助

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\TrafficMonitor.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\TrafficMonitor.ps1 -Action install
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\TrafficMonitor.ps1 -Action report -Days 30
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\TrafficMonitor.ps1 -Action run -Live
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'run', 'report', 'reset', 'install', 'uninstall', 'selftest', 'help')]
    [string]$Action = 'status',

    # 采样间隔（秒），越小越精确，代价是 CPU/磁盘写入略增
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 5,

    # 账本文件位置；默认 C:\ProgramData\TrafficMonitor\state.json
    [string]$StatePath,

    # physical = 只统计物理网卡（忽略 VMware / TAP / Tailscale / Wi-Fi Direct 等虚拟网卡，避免重复计数）
    # all      = 统计全部网卡（仅排除回环、隧道伪接口）
    [ValidateSet('physical', 'all')]
    [string]$Scope = 'physical',

    # 额外白名单 / 黑名单，按网卡名或描述做正则匹配
    [string[]]$IncludeAdapter,
    [string[]]$ExcludeAdapter,

    # 数据来源：auto 优先 NetAdapter 命令行，失败时退回性能计数器
    [ValidateSet('auto', 'netadapter', 'perfcounter')]
    [string]$Provider = 'auto',

    # report 显示最近多少天
    [ValidateRange(1, 400)]
    [int]$Days = 7,

    # install 模式：auto = 管理员用开机启动(SYSTEM)，否则用当前用户登录时启动
    [ValidateSet('auto', 'startup', 'logon')]
    [string]$InstallMode = 'auto',

    # 以 JSON 输出（便于其他程序读取）
    [switch]$Json,

    # run 模式下在控制台刷新显示实时速率
    [switch]$Live,

    # run 模式下只采样一次就退出
    [switch]$Once,

    # reset / uninstall 时跳过确认
    [switch]$Force,

    # uninstall 时同时删除账本与脚本副本
    [switch]$Purge
)

$ErrorActionPreference = 'Continue'
$Script:AppName = 'TrafficMonitor'
$Script:TaskName = 'TrafficMonitor'

#region ── 通用小工具 ────────────────────────────────────────────────────────────

function Format-Bytes {
    param([double]$Value)
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $i = 0
    while ([math]::Abs($Value) -ge 1024 -and $i -lt ($units.Count - 1)) { $Value = $Value / 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} B' -f $Value) }
    return ('{0:N2} {1}' -f $Value, $units[$i])
}

function Format-Rate {
    param([double]$BytesPerSecond)
    return ((Format-Bytes -Value $BytesPerSecond) + '/s')
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1) { return ('{0} 天 {1} 小时' -f [int]$Span.TotalDays, $Span.Hours) }
    if ($Span.TotalHours -ge 1) { return ('{0} 小时 {1} 分' -f [int]$Span.TotalHours, $Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ('{0} 分 {1} 秒' -f [int]$Span.TotalMinutes, $Span.Seconds) }
    return ('{0} 秒' -f [int]$Span.TotalSeconds)
}

function Get-PropValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

# 中日韩字符在等宽终端里占 2 列，用 -f 的宽度补齐会错位，这里按显示宽度补齐
function Get-DisplayWidth {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int][char]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { $w += 2 }
        else { $w += 1 }
    }
    return $w
}

function Pad-Right {
    param([string]$Text, [int]$Width)
    $t = [string]$Text
    $pad = $Width - (Get-DisplayWidth -Text $t)
    if ($pad -lt 0) { $pad = 0 }
    return $t + (' ' * $pad)
}

function Pad-Left {
    param([string]$Text, [int]$Width)
    $t = [string]$Text
    $pad = $Width - (Get-DisplayWidth -Text $t)
    if ($pad -lt 0) { $pad = 0 }
    return (' ' * $pad) + $t
}

#endregion

#region ── 路径 / 日志 ───────────────────────────────────────────────────────────

function Ensure-DirWritable {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $probe = Join-Path $Dir ('.write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $fs = [System.IO.File]::Create($probe)
    $fs.Close()
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return $true
}

function Initialize-Paths {
    if ($StatePath) {
        $Script:StateFile = [System.IO.Path]::GetFullPath($StatePath)
        if ([System.IO.Path]::GetExtension($Script:StateFile) -ne '.json') {
            $Script:StateFile = Join-Path $Script:StateFile 'state.json'
        }
        $Script:StateDir = Split-Path -Parent $Script:StateFile
        Ensure-DirWritable -Dir $Script:StateDir | Out-Null
    }
    else {
        $candidates = @()
        if ($env:ProgramData) { $candidates += (Join-Path $env:ProgramData $Script:AppName) }
        if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA $Script:AppName) }
        if ($env:TEMP) { $candidates += (Join-Path $env:TEMP $Script:AppName) }
        foreach ($cand in $candidates) {
            try { Ensure-DirWritable -Dir $cand | Out-Null; $Script:StateDir = $cand; break } catch { }
        }
        if (-not $Script:StateDir) { throw '找不到可写的状态目录（已尝试 ProgramData / LocalAppData / TEMP）。' }
        $Script:StateFile = Join-Path $Script:StateDir 'state.json'
    }
    $Script:LogFile = Join-Path $Script:StateDir 'monitor.log'
    $Script:LockFile = Join-Path $Script:StateDir 'monitor.lock'
    $Script:TargetScript = Join-Path $Script:StateDir 'TrafficMonitor.ps1'
}

$Script:LogWriteCount = 0
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    if (-not $Script:LogFile) { return }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    $Script:LogWriteCount++
    if ($Script:LogWriteCount % 200 -eq 0) { Limit-LogFile }
}

function Limit-LogFile {
    try {
        if (-not (Test-Path -LiteralPath $Script:LogFile)) { return }
        if ((Get-Item -LiteralPath $Script:LogFile).Length -lt 1MB) { return }
        $lines = Get-Content -LiteralPath $Script:LogFile -Tail 1000 -ErrorAction Stop
        Set-Content -LiteralPath $Script:LogFile -Value $lines -Encoding UTF8
    }
    catch { }
}

function Enter-MonitorLock {
    try {
        $fs = [System.IO.File]::Open($Script:LockFile, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return $fs
    }
    catch { return $null }
}

function Release-MonitorLock {
    if ($Script:LockHandle) {
        try { $Script:LockHandle.Close(); $Script:LockHandle.Dispose() } catch { }
        $Script:LockHandle = $null
    }
}

function Test-MonitorRunning {
    $fs = Enter-MonitorLock
    if ($fs) { $fs.Close(); $fs.Dispose(); return $false }
    return $true
}

#endregion

#region ── 账本（state.json） ───────────────────────────────────────────────────

function New-EmptyState {
    $now = (Get-Date).ToString('o')
    return [ordered]@{
        version     = 1
        createdAt   = $now
        updatedAt   = $now
        initialized = $false
        bootId      = $null
        bootCount   = 0
        totalRx     = [long]0
        totalTx     = [long]0
        session     = [ordered]@{ bootId = $null; startedAt = $now; rx = [long]0; tx = [long]0 }
        days        = [ordered]@{}
        ifaces      = [ordered]@{}
    }
}

function Get-State {
    if (-not (Test-Path -LiteralPath $Script:StateFile)) { return (New-EmptyState) }
    $raw = ''
    try { $raw = Get-Content -LiteralPath $Script:StateFile -Raw -Encoding UTF8 -ErrorAction Stop } catch { return (New-EmptyState) }
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-EmptyState) }

    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $bak = $Script:StateFile + '.corrupt-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $Script:StateFile -Destination $bak -Force -ErrorAction SilentlyContinue
        Write-Log "state.json 解析失败，已备份为 $bak 并重建：$($_.Exception.Message)" 'ERROR'
        return (New-EmptyState)
    }

    $s = New-EmptyState
    $s.version = [int](Get-PropValue $obj 'version' 1)
    $s.createdAt = [string](Get-PropValue $obj 'createdAt' $s.createdAt)
    $s.updatedAt = [string](Get-PropValue $obj 'updatedAt' $s.updatedAt)
    $s.initialized = [bool](Get-PropValue $obj 'initialized' $false)
    $s.bootId = [string](Get-PropValue $obj 'bootId' $null)
    $s.bootCount = [int](Get-PropValue $obj 'bootCount' 0)
    $s.totalRx = [long](Get-PropValue $obj 'totalRx' 0)
    $s.totalTx = [long](Get-PropValue $obj 'totalTx' 0)

    $sess = Get-PropValue $obj 'session' $null
    if ($sess) {
        $s.session = [ordered]@{
            bootId    = [string](Get-PropValue $sess 'bootId' $null)
            startedAt = [string](Get-PropValue $sess 'startedAt' $s.createdAt)
            rx        = [long](Get-PropValue $sess 'rx' 0)
            tx        = [long](Get-PropValue $sess 'tx' 0)
        }
    }

    $days = Get-PropValue $obj 'days' $null
    if ($days) {
        foreach ($d in $days.PSObject.Properties) {
            $s.days[$d.Name] = [ordered]@{
                rx = [long](Get-PropValue $d.Value 'rx' 0)
                tx = [long](Get-PropValue $d.Value 'tx' 0)
            }
        }
    }

    $ifaces = Get-PropValue $obj 'ifaces' $null
    if ($ifaces) {
        foreach ($i in $ifaces.PSObject.Properties) {
            $s.ifaces[$i.Name] = [ordered]@{
                name   = [string](Get-PropValue $i.Value 'name' $i.Name)
                desc   = [string](Get-PropValue $i.Value 'desc' '')
                lastRx = [long](Get-PropValue $i.Value 'lastRx' 0)
                lastTx = [long](Get-PropValue $i.Value 'lastTx' 0)
                rx     = [long](Get-PropValue $i.Value 'rx' 0)
                tx     = [long](Get-PropValue $i.Value 'tx' 0)
                seenAt = [string](Get-PropValue $i.Value 'seenAt' $null)
            }
        }
    }
    return $s
}

function Save-State {
    param($State)
    $State.updatedAt = (Get-Date).ToString('o')
    $json = $State | ConvertTo-Json -Depth 8
    $tmp = $Script:StateFile + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Script:StateFile -Force
}

#endregion

#region ── 核心算法：增量计算 ───────────────────────────────────────────────────

<#
  计数器增量。
    Prev     : 上次记录的原始计数值（$null 表示该网卡第一次被看到）
    Current  : 本次读到的原始计数值
  规则：
    Current >= Prev  → 正常增长，增量 = Current - Prev
    Current <  Prev  → 计数器已归零（重启 / 驱动重载 / 网卡禁用后重新启用），
                       此时"自归零以来"的流量就是 Current 本身
    Prev 为 $null    → 新出现的网卡，计数器从 0 开始，增量 = Current
#>
function Get-TrafficDelta {
    param($Prev, [long]$Current)
    if ($Current -lt 0) { return [long]0 }
    if ($null -eq $Prev) { return [long]$Current }
    $p = [long]$Prev
    if ($p -lt 0) { return [long]$Current }
    if ($Current -ge $p) { return [long]($Current - $p) }
    return [long]$Current
}

$Script:PseudoRegex = 'Loopback|Pseudo-Interface|Teredo|6to4|IP-HTTPS|Kernel Debug|内核调试|WAN Miniport'

function Test-AdapterInScope {
    param(
        [string]$Name,
        [string]$Desc,
        $Physical,
        [string]$ScopeMode = 'physical',
        [string[]]$Include,
        [string[]]$Exclude
    )
    $text = "$Name $Desc"
    if ($text -match $Script:PseudoRegex) { return $false }

    if ($Exclude) { foreach ($p in $Exclude) { if ($text -match $p) { return $false } } }
    if ($Include) {
        foreach ($p in $Include) { if ($text -match $p) { return $true } }
        return $false
    }
    if ($ScopeMode -eq 'all') { return $true }
    if ($null -eq $Physical) { return $true }   # 类型未知时保守计入
    return [bool]$Physical
}

<#
  把一次采样合并进账本，返回本次新增的流量。
  Baseline = $true 时只记录基线不计流量（首次运行 / reset 之后）。
#>
function Update-StateFromSample {
    param($State, $Sample, [switch]$Baseline)

    $now = $Sample.time
    $dateKey = $now.ToString('yyyy-MM-dd')
    if (-not $State.days.Contains($dateKey)) {
        $State.days[$dateKey] = [ordered]@{ rx = [long]0; tx = [long]0 }
    }
    $day = $State.days[$dateKey]

    $addRx = [long]0
    $addTx = [long]0

    foreach ($key in @($Sample.ifaces.Keys)) {
        $s = $Sample.ifaces[$key]
        $entry = $null
        if ($State.ifaces.Contains($key)) { $entry = $State.ifaces[$key] }

        if ($Baseline) {
            $dRx = [long]0
            $dTx = [long]0
        }
        else {
            $prevRx = $null
            $prevTx = $null
            if ($entry) { $prevRx = $entry.lastRx; $prevTx = $entry.lastTx }
            $dRx = Get-TrafficDelta -Prev $prevRx -Current ([long]$s.rx)
            $dTx = Get-TrafficDelta -Prev $prevTx -Current ([long]$s.tx)
        }

        if (-not $entry) {
            $entry = [ordered]@{
                name = [string]$s.name; desc = [string]$s.desc
                lastRx = [long]0; lastTx = [long]0; rx = [long]0; tx = [long]0; seenAt = $null
            }
            $State.ifaces[$key] = $entry
        }

        $entry.name = [string]$s.name
        $entry.desc = [string]$s.desc
        $entry.lastRx = [long]$s.rx
        $entry.lastTx = [long]$s.tx
        $entry.seenAt = $now.ToString('o')

        $inScope = Test-AdapterInScope -Name $s.name -Desc $s.desc -Physical $s.physical `
            -ScopeMode $Script:Opt.Scope -Include $Script:Opt.Include -Exclude $Script:Opt.Exclude
        if ($inScope) {
            $entry.rx = [long]$entry.rx + $dRx
            $entry.tx = [long]$entry.tx + $dTx
            $addRx += $dRx
            $addTx += $dTx
        }
    }

    $State.totalRx = [long]$State.totalRx + $addRx
    $State.totalTx = [long]$State.totalTx + $addTx
    $day.rx = [long]$day.rx + $addRx
    $day.tx = [long]$day.tx + $addTx
    $State.session.rx = [long]$State.session.rx + $addRx
    $State.session.tx = [long]$State.session.tx + $addTx

    return @{ rx = $addRx; tx = $addTx }
}

#endregion

#region ── 采样：读取网卡原始计数器 ─────────────────────────────────────────────

$Script:AdapterMap = $null
$Script:AdapterMapTime = [datetime]::MinValue

function Update-AdapterMap {
    $map = @{}
    try {
        $adapters = Get-NetAdapter -IncludeHidden -ErrorAction Stop
        foreach ($a in $adapters) {
            $map[[string]$a.Name] = [ordered]@{
                guid     = [string]$a.InterfaceGuid
                desc     = [string]$a.InterfaceDescription
                physical = [bool]$a.HardwareInterface
                virtual  = [bool]$a.Virtual
                status   = [string]$a.Status
            }
        }
    }
    catch { Write-Log "Get-NetAdapter 调用失败（将用网卡名做键）：$($_.Exception.Message)" 'WARN' }
    $Script:AdapterMap = $map
    $Script:AdapterMapTime = Get-Date
}

function Get-BootId {
    if ($Script:BootId) { return $Script:BootId }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop
        $Script:BootId = ([datetime]$os.LastBootUpTime).ToString('o')
    }
    catch {
        try { $Script:BootId = (Get-Date).AddMilliseconds(-[Environment]::TickCount).ToString('o') }
        catch { $Script:BootId = 'unknown' }
    }
    return $Script:BootId
}

<#
  返回 [ordered]@{ provider; time; ifaces = @{ <键> = @{ name; desc; physical; rx; tx } } }
  rx / tx 一律是"累计字节"语义，便于统一走增量算法。
#>
function Get-TrafficSample {
    param(
        [ValidateSet('auto', 'netadapter', 'perfcounter')][string]$Preferred = 'auto',
        $State = $null
    )
    $now = Get-Date
    if ($null -eq $Script:AdapterMap -or ($now - $Script:AdapterMapTime).TotalSeconds -gt 60) { Update-AdapterMap }

    $sample = @{}
    $used = $null

    if ($Preferred -ne 'perfcounter') {
        try {
            $stats = Get-NetAdapterStatistics -ErrorAction Stop
            foreach ($s in $stats) {
                $name = [string]$s.Name
                $info = $null
                if ($Script:AdapterMap.ContainsKey($name)) { $info = $Script:AdapterMap[$name] }
                else {
                    # 新出现的网卡（例如刚插上的 USB 网卡），刷新一次映射
                    Update-AdapterMap
                    if ($Script:AdapterMap.ContainsKey($name)) { $info = $Script:AdapterMap[$name] }
                }
                $key = if ($info) { $info.guid } else { 'name:' + $name }
                $desc = [string]$s.InterfaceDescription
                $physical = $null
                if ($info) { $desc = $info.desc; $physical = $info.physical }
                $sample[$key] = [ordered]@{
                    name     = $name
                    desc     = $desc
                    physical = $physical
                    rx       = [long]$s.ReceivedBytes
                    tx       = [long]$s.SentBytes
                }
            }
            $used = 'netadapter'
        }
        catch {
            if ($Preferred -eq 'netadapter') { throw }
            Write-Log "Get-NetAdapterStatistics 不可用，改用性能计数器：$($_.Exception.Message)" 'WARN'
        }
    }

    if (-not $used) {
        $data = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
        foreach ($d in $data) {
            $name = [string]$d.Name
            $key = 'perf:' + $name
            $prev = $null
            if ($State -and $State.ifaces.Contains($key)) { $prev = $State.ifaces[$key] }

            $elapsed = [double]$IntervalSeconds
            if ($prev -and $prev.seenAt) {
                try { $elapsed = ($now - [datetime]$prev.seenAt).TotalSeconds } catch { $elapsed = [double]$IntervalSeconds }
            }
            if ($elapsed -lt 0.5 -or $elapsed -gt 300) { $elapsed = [double]$IntervalSeconds }

            $baseRx = [long]0
            $baseTx = [long]0
            if ($prev) { $baseRx = [long]$prev.lastRx; $baseTx = [long]$prev.lastTx }

            $sample[$key] = [ordered]@{
                name     = $name
                desc     = $name
                physical = $null
                rx       = $baseRx + [long]([double]$d.BytesReceivedPersec * $elapsed)
                tx       = $baseTx + [long]([double]$d.BytesSentPersec * $elapsed)
            }
        }
        $used = 'perfcounter'
    }

    return [ordered]@{ provider = $used; time = $now; ifaces = $sample }
}

function Get-LiveRate {
    param([double]$Seconds = 1.2, [string]$Preferred = 'auto')
    $a = Get-TrafficSample -Preferred $Preferred
    if ($a.provider -eq 'perfcounter') {
        try {
            $data = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
            $rx = 0.0; $tx = 0.0
            foreach ($d in $data) {
                if (-not (Test-AdapterInScope -Name ([string]$d.Name) -Desc ([string]$d.Name) -Physical $null `
                            -ScopeMode $Script:Opt.Scope -Include $Script:Opt.Include -Exclude $Script:Opt.Exclude)) { continue }
                $rx += [double]$d.BytesReceivedPersec
                $tx += [double]$d.BytesSentPersec
            }
            return @{ rx = $rx; tx = $tx; exact = $false }
        }
        catch { return @{ rx = 0.0; tx = 0.0; exact = $false } }
    }

    Start-Sleep -Milliseconds ([int]($Seconds * 1000))
    $b = Get-TrafficSample -Preferred $Preferred
    $sumRx = 0.0; $sumTx = 0.0
    foreach ($k in $b.ifaces.Keys) {
        if (-not $a.ifaces.Contains($k)) { continue }
        $sa = $a.ifaces[$k]; $sb = $b.ifaces[$k]
        if (-not (Test-AdapterInScope -Name $sb.name -Desc $sb.desc -Physical $sb.physical `
                    -ScopeMode $Script:Opt.Scope -Include $Script:Opt.Include -Exclude $Script:Opt.Exclude)) { continue }
        $sumRx += (Get-TrafficDelta -Prev $sa.rx -Current $sb.rx)
        $sumTx += (Get-TrafficDelta -Prev $sa.tx -Current $sb.tx)
    }
    $real = ($b.time - $a.time).TotalSeconds
    if ($real -le 0.1) { $real = $Seconds }
    return @{ rx = ($sumRx / $real); tx = ($sumTx / $real); exact = $true }
}

#endregion

#region ── 账本查询辅助 ─────────────────────────────────────────────────────────

function Get-PeriodTotals {
    param($State, [datetime]$From, [datetime]$To)
    $rx = [long]0; $tx = [long]0
    foreach ($k in @($State.days.Keys)) {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($k, 'yyyy-MM-dd', $null, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { continue }
        if ($d -ge $From.Date -and $d -le $To.Date) {
            $rx += [long]$State.days[$k].rx
            $tx += [long]$State.days[$k].tx
        }
    }
    return @{ rx = $rx; tx = $tx }
}

#endregion

#region ── 动作：status ────────────────────────────────────────────────────────

function Show-Status {
    $state = Get-State
    $running = Test-MonitorRunning
    $now = Get-Date

    $today = Get-PeriodTotals -State $state -From $now -To $now
    $monthStart = Get-Date -Year $now.Year -Month $now.Month -Day 1
    $month = Get-PeriodTotals -State $state -From $monthStart -To $now

    $providerName = if ($Provider -eq 'auto') { 'auto（NetAdapter → 性能计数器）' } else { $Provider }

    if ($Json) {
        $out = [ordered]@{
            stateFile     = $Script:StateFile
            running       = $running
            updatedAt     = $state.updatedAt
            createdAt     = $state.createdAt
            bootCount     = $state.bootCount
            session       = @{ rx = [long]$state.session.rx; tx = [long]$state.session.tx }
            today         = @{ rx = $today.rx; tx = $today.tx }
            month         = @{ rx = $month.rx; tx = $month.tx }
            total         = @{ rx = [long]$state.totalRx; tx = [long]$state.totalTx }
            scope         = $Scope
            interfaces    = @()
        }
        foreach ($k in @($state.ifaces.Keys)) {
            $i = $state.ifaces[$k]
            $out.interfaces += [ordered]@{ key = $k; name = $i.name; desc = $i.desc; rx = [long]$i.rx; tx = [long]$i.tx }
        }
        $out | ConvertTo-Json -Depth 6
        return
    }

    $line = '=' * 66
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ' TrafficMonitor · 网络流量统计' -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host (' 状态文件   : {0}' -f $Script:StateFile)
    Write-Host (' 采集方式   : {0}' -f $providerName)
    Write-Host (' 统计范围   : {0}' -f $(if ($Scope -eq 'physical') { 'physical（仅物理网卡，忽略虚拟/隧道网卡）' } else { 'all（全部网卡）' }))

    if ($running) {
        $age = '未知'
        if ($state.updatedAt) { try { $age = Format-Duration -Span ($now - [datetime]$state.updatedAt) } catch { } }
        Write-Host (' 监测进程   : {0}' -f "运行中（$age 前更新）") -ForegroundColor Green
    }
    else {
        Write-Host ' 监测进程   : 未运行（执行 -Action install 可注册开机自启）' -ForegroundColor Yellow
    }

    if ((Test-Path -LiteralPath $Script:StateFile) -and $state.createdAt) {
        try {
            $started = [datetime]$state.createdAt
            Write-Host (' 监测开始   : {0}' -f $started.ToString('yyyy-MM-dd HH:mm:ss'))
            Write-Host (' 已监测     : {0}（跨 {1} 次开机）' -f (Format-Duration -Span ($now - $started)), $state.bootCount)
        }
        catch { }
    }
    else {
        Write-Host ' 监测开始   : 尚未开始（还没有账本，请执行 -Action install 注册自启）' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host (' ' + (Pad-Right -Text '' -Width 16) + (Pad-Left -Text '接收(下载)' -Width 16) + (Pad-Left -Text '发送(上传)' -Width 16) + (Pad-Left -Text '合计' -Width 16)) -ForegroundColor DarkGray
    Write-Host (' ' + ('-' * 62)) -ForegroundColor DarkGray
    $rows = @(
        @{ n = '本次开机'; rx = [long]$state.session.rx; tx = [long]$state.session.tx }
        @{ n = '今天'; rx = $today.rx; tx = $today.tx }
        @{ n = '本月'; rx = $month.rx; tx = $month.tx }
        @{ n = '总计(自监测开始)'; rx = [long]$state.totalRx; tx = [long]$state.totalTx }
    )
    foreach ($r in $rows) {
        Write-Host (' ' + (Pad-Right -Text $r.n -Width 16) +
            (Pad-Left -Text (Format-Bytes -Value $r.rx) -Width 16) +
            (Pad-Left -Text (Format-Bytes -Value $r.tx) -Width 16) +
            (Pad-Left -Text (Format-Bytes -Value ($r.rx + $r.tx)) -Width 16))
    }
    Write-Host ''

    $rate = Get-LiveRate -Preferred $Provider
    $suffix = ''
    if (-not $rate.exact) { $suffix = '（性能计数器近似值）' }
    Write-Host (' 实时速率   ↓ {0}   ↑ {1}{2}' -f (Format-Rate -BytesPerSecond $rate.rx), (Format-Rate -BytesPerSecond $rate.tx), $suffix) -ForegroundColor Green
    Write-Host ''

    $list = @()
    foreach ($k in @($state.ifaces.Keys)) {
        $i = $state.ifaces[$k]
        if (([long]$i.rx + [long]$i.tx) -le 0) { continue }
        $list += [pscustomobject]@{ Name = $i.name; Desc = $i.desc; Rx = [long]$i.rx; Tx = [long]$i.tx; Total = [long]$i.rx + [long]$i.tx }
    }
    if ($list.Count -gt 0) {
        Write-Host ' 各网卡累计：' -ForegroundColor DarkGray
        foreach ($x in ($list | Sort-Object Total -Descending | Select-Object -First 10)) {
            Write-Host ('   ' + (Pad-Right -Text $x.Name -Width 26) + '↓ ' + (Pad-Right -Text (Format-Bytes -Value $x.Rx) -Width 12) + '↑ ' + (Pad-Right -Text (Format-Bytes -Value $x.Tx) -Width 12))
        }
    }
    Write-Host $line -ForegroundColor DarkCyan
}

#endregion

#region ── 动作：report ────────────────────────────────────────────────────────

function Show-Report {
    $state = Get-State
    $today = (Get-Date).Date
    $from = $today.AddDays(-1 * ($Days - 1))

    if ($Json) {
        $out = @()
        for ($i = 0; $i -lt $Days; $i++) {
            $d = $from.AddDays($i)
            $k = $d.ToString('yyyy-MM-dd')
            $rx = [long]0; $tx = [long]0
            if ($state.days.Contains($k)) { $rx = [long]$state.days[$k].rx; $tx = [long]$state.days[$k].tx }
            $out += [ordered]@{ date = $k; rx = $rx; tx = $tx }
        }
        $out | ConvertTo-Json -Depth 4
        return
    }

    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host (' TrafficMonitor · 用量报表（最近 {0} 天）' -f $Days) -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host (' ' + (Pad-Right -Text '日期' -Width 14) + (Pad-Left -Text '接收(下载)' -Width 16) + (Pad-Left -Text '发送(上传)' -Width 16) + (Pad-Left -Text '合计' -Width 16)) -ForegroundColor DarkGray
    Write-Host (' ' + ('-' * 62)) -ForegroundColor DarkGray

    $sumRx = [long]0; $sumTx = [long]0
    for ($i = 0; $i -lt $Days; $i++) {
        $d = $from.AddDays($i)
        $k = $d.ToString('yyyy-MM-dd')
        $rx = [long]0; $tx = [long]0
        if ($state.days.Contains($k)) { $rx = [long]$state.days[$k].rx; $tx = [long]$state.days[$k].tx }
        $sumRx += $rx; $sumTx += $tx
        $mark = ''
        if ($d -eq $today) { $mark = '  ← 今天' }
        Write-Host (' ' + (Pad-Right -Text $k -Width 14) +
            (Pad-Left -Text (Format-Bytes -Value $rx) -Width 16) +
            (Pad-Left -Text (Format-Bytes -Value $tx) -Width 16) +
            (Pad-Left -Text (Format-Bytes -Value ($rx + $tx)) -Width 16) + $mark)
    }
    Write-Host (' ' + ('-' * 62)) -ForegroundColor DarkGray
    Write-Host (' ' + (Pad-Right -Text '区间合计' -Width 14) +
        (Pad-Left -Text (Format-Bytes -Value $sumRx) -Width 16) +
        (Pad-Left -Text (Format-Bytes -Value $sumTx) -Width 16) +
        (Pad-Left -Text (Format-Bytes -Value ($sumRx + $sumTx)) -Width 16)) -ForegroundColor Green

    # 按月汇总
    $months = @{}
    foreach ($k in @($state.days.Keys)) {
        $mk = $k.Substring(0, [Math]::Min(7, $k.Length))
        if (-not $months.ContainsKey($mk)) { $months[$mk] = @{ rx = [long]0; tx = [long]0 } }
        $months[$mk].rx += [long]$state.days[$k].rx
        $months[$mk].tx += [long]$state.days[$k].tx
    }
    if ($months.Count -gt 0) {
        Write-Host ''
        Write-Host ' 按月汇总：' -ForegroundColor DarkGray
        foreach ($mk in ($months.Keys | Sort-Object -Descending)) {
            Write-Host ('   {0,-12} ↓ {1,-12} ↑ {2,-12} 合计 {3}' -f $mk,
                (Format-Bytes -Value $months[$mk].rx), (Format-Bytes -Value $months[$mk].tx),
                (Format-Bytes -Value ($months[$mk].rx + $months[$mk].tx)))
        }
    }

    Write-Host ''
    Write-Host (' 累计总量：↓ {0}   ↑ {1}   合计 {2}' -f (Format-Bytes -Value $state.totalRx), (Format-Bytes -Value $state.totalTx), (Format-Bytes -Value ([long]$state.totalRx + [long]$state.totalTx))) -ForegroundColor Cyan
    Write-Host (' 账本文件：{0}' -f $Script:StateFile)
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}

#endregion

#region ── 动作：run ───────────────────────────────────────────────────────────

function Invoke-MonitorLoop {
    $lock = Enter-MonitorLock
    if (-not $lock) {
        Write-Host '已有 TrafficMonitor 监测进程在运行，本进程退出。' -ForegroundColor Yellow
        return 2
    }
    $Script:LockHandle = $lock

    Limit-LogFile
    Write-Log ("监测启动 PID=$PID 间隔=${IntervalSeconds}s 范围=$($Script:Opt.Scope) 采集=$($Script:Opt.Provider)")

    $state = Get-State
    $bootId = Get-BootId
    $lastSave = Get-Date
    $prevSampleTime = $null
    $exitCode = 0

    try {
        while ($true) {
            $tick = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $sample = Get-TrafficSample -Preferred $Script:Opt.Provider -State $state

                if ($state.bootId -ne $bootId) {
                    $state.bootId = $bootId
                    $state.bootCount = [int]$state.bootCount + 1
                    $state.session = [ordered]@{
                        bootId = $bootId; startedAt = $sample.time.ToString('o'); rx = [long]0; tx = [long]0
                    }
                    Write-Log "检测到新的开机会话（第 $($state.bootCount) 次开机），本次开机计数已重置"
                }

                $baseline = -not $state.initialized
                $delta = Update-StateFromSample -State $state -Sample $sample -Baseline:$baseline
                if ($baseline) {
                    $state.initialized = $true
                    Write-Log '首次运行：已记录各网卡计数基线，从现在开始累计'
                }

                $elapsedSec = [double]$IntervalSeconds
                if ($prevSampleTime) {
                    $e = ($sample.time - $prevSampleTime).TotalSeconds
                    if ($e -ge 0.5 -and $e -le 300) { $elapsedSec = $e }
                }
                $prevSampleTime = $sample.time

                $needSave = $baseline -or $delta.rx -gt 0 -or $delta.tx -gt 0 -or ((Get-Date) - $lastSave).TotalSeconds -ge 60
                if ($needSave) {
                    Save-State -State $state
                    $lastSave = Get-Date
                }

                if ($Live) {
                    $msg = ' {0}  ↓ {1}  ↑ {2}   今日 ↓ {3} ↑ {4}   总计 {5}   ' -f (Get-Date -Format 'HH:mm:ss'),
                        (Format-Rate -BytesPerSecond ($delta.rx / $elapsedSec)),
                        (Format-Rate -BytesPerSecond ($delta.tx / $elapsedSec)),
                        (Format-Bytes -Value ([long]$state.days[$sample.time.ToString('yyyy-MM-dd')].rx)),
                        (Format-Bytes -Value ([long]$state.days[$sample.time.ToString('yyyy-MM-dd')].tx)),
                        (Format-Bytes -Value ([long]$state.totalRx + [long]$state.totalTx))
                    Write-Host $msg -NoNewline -ForegroundColor Green
                }
            }
            catch {
                Write-Log "采样失败：$($_.Exception.Message)" 'ERROR'
            }

            if ($Once) { break }

            $wait = ($IntervalSeconds * 1000) - $tick.ElapsedMilliseconds
            if ($wait -lt 100) { $wait = 100 }
            Start-Sleep -Milliseconds ([int]$wait)
        }
    }
    finally {
        try { Save-State -State $state; Write-Log '监测停止，账本已保存' } catch { }
        if ($Live) { Write-Host '' }
        Release-MonitorLock
    }
    return $exitCode
}

#endregion

#region ── 动作：reset / install / uninstall ───────────────────────────────────

function Reset-Counters {
    $task = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    $wasRunning = $false
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        $wasRunning = $true
        Start-Sleep -Milliseconds 1000
    }

    if (Test-MonitorRunning) {
        if (-not $Force) { throw '监测进程仍在运行，无法清零。请先停止计划任务（Stop-ScheduledTask -TaskName TrafficMonitor），或加 -Force 重试。' }
        Write-Host ' 监测进程仍在运行，等待其退出…' -ForegroundColor Yellow
        $waited = 0
        while ((Test-MonitorRunning) -and $waited -lt 10000) { Start-Sleep -Milliseconds 500; $waited += 500 }
        if (Test-MonitorRunning) { throw '监测进程未退出，清零中止。' }
    }

    if (-not $Force) {
        $ans = Read-Host (' 确认清零 {0} 的全部流量记录？(y/N)' -f $Script:StateFile)
        if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host ' 已取消。'; return }
    }

    $backup = $Script:StateFile + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (Test-Path -LiteralPath $Script:StateFile) {
        Copy-Item -LiteralPath $Script:StateFile -Destination $backup -Force
        Write-Host (' 旧账本已备份：{0}' -f $backup)
    }
    $fresh = New-EmptyState
    $fresh.bootCount = 1
    $fresh.bootId = Get-BootId
    $fresh.session = [ordered]@{ bootId = $fresh.bootId; startedAt = (Get-Date).ToString('o'); rx = [long]0; tx = [long]0 }
    Save-State -State $fresh
    Write-Log '账本已清零（reset）'
    Write-Host ' 已清零。下次采样会重新记录基线，从当前时刻开始计数。' -ForegroundColor Green

    if ($wasRunning) {
        Start-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        Write-Host ' 监测任务已重新启动。'
    }
}

function Get-SelfPath {
    if ($PSCommandPath) { return $PSCommandPath }
    if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
    return $null
}

function Install-Monitor {
    $self = Get-SelfPath
    if (-not $self -or -not (Test-Path -LiteralPath $self)) { throw '无法定位脚本自身路径，无法安装。' }

    # 重新安装时先停掉旧实例，确保新脚本副本被加载
    $existing = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    if ($existing -and $existing.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1000
    }

    $target = $Script:TargetScript
    if ([System.IO.Path]::GetFullPath($self) -ne [System.IO.Path]::GetFullPath($target)) {
        Copy-Item -LiteralPath $self -Destination $target -Force
        Write-Host (' 脚本已复制到：{0}' -f $target)
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $mode = $InstallMode
    if ($mode -eq 'auto') { if ($isAdmin) { $mode = 'startup' } else { $mode = 'logon' } }
    if ($mode -eq 'startup' -and -not $isAdmin) {
        throw '开机启动模式需要管理员权限。请以管理员身份运行 PowerShell 后重试，或使用 -InstallMode logon。'
    }

    $argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action run -IntervalSeconds {1} -StatePath "{2}" -Scope {3}' -f `
        $target, $IntervalSeconds, $Script:StateFile, $Scope
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine

    if ($mode -eq 'startup') {
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }
    else {
        $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    $desc = 'TrafficMonitor 网络流量统计（跨重启累计）'
    try {
        Register-ScheduledTask -TaskName $Script:TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description $desc -Force -ErrorAction Stop | Out-Null
    }
    catch {
        throw ("注册计划任务失败：{0}`n可尝试以管理员身份重新运行，或手动执行：`nschtasks /Create /TN TrafficMonitor /SC ONLOGON /TR `"powershell.exe $argLine`" /F" -f $_.Exception.Message)
    }

    # 让普通用户也能读写状态目录（SYSTEM 创建目录时用户默认只有读权限）
    if ($isAdmin) {
        try {
            $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')  # BUILTIN\Users
            icacls $Script:StateDir /grant ('*' + $sid.Value + ':(OI)(CI)M') /T /C | Out-Null
        }
        catch { Write-Host ' 提示：未能自动调整状态目录权限，普通用户可能无法执行 status/reset。' -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host ' 安装完成 √' -ForegroundColor Green
    Write-Host ('   模式      : {0}' -f $(if ($mode -eq 'startup') { '开机启动（SYSTEM 服务级，开机后立刻采样，最精确）' } else { '当前用户登录时启动（无需管理员）' }))
    Write-Host ('   脚本      : {0}' -f $target)
    Write-Host ('   账本      : {0}' -f $Script:StateFile)
    Write-Host ('   日志      : {0}' -f $Script:LogFile)
    Write-Host ('   采样间隔  : {0} 秒' -f $IntervalSeconds)
    if ($mode -eq 'logon') {
        Write-Host '   说明      : 开机到登录之间产生的流量，会在登录后第一次采样时一并补计进来，' -ForegroundColor DarkGray
        Write-Host '               因为网卡计数器自开机起累计，登录后读到的就是"本次开机以来"的值。' -ForegroundColor DarkGray
        Write-Host '               以管理员身份重新 install，可切换为服务级开机启动。' -ForegroundColor DarkGray
    }

    Start-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    $t = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    if ($t) { Write-Host ('   任务状态  : {0}' -f $t.State) }
    Write-Host '   查看用量  : TrafficMonitor.cmd   （或 -Action status）'
}

function Uninstall-Monitor {
    if (-not $Force) {
        $ans = Read-Host ' 确认移除 TrafficMonitor 计划任务？(y/N)'
        if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host ' 已取消。'; return }
    }
    $task = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
        Write-Host ' 计划任务已移除。' -ForegroundColor Green
    }
    else { Write-Host ' 未找到 TrafficMonitor 计划任务。' }

    if ($Purge) {
        if (Test-MonitorRunning) { throw '监测进程仍在运行，未能删除账本。' }
        foreach ($f in @($Script:TargetScript, $Script:StateFile, $Script:LogFile, $Script:LockFile)) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
        Write-Host ' 脚本副本与账本已删除（-Purge）。' -ForegroundColor Yellow
    }
    else {
        Write-Host (' 账本保留在：{0}（加 -Purge 可一并删除）' -f $Script:StateFile)
    }
}

#endregion

#region ── 动作：selftest ─────────────────────────────────────────────────────

function Invoke-SelfTest {
    $script:fail = 0
    function Assert-Equal {
        param($Expected, $Actual, [string]$Name)
        if ([string]$Expected -eq [string]$Actual) {
            Write-Host ('   [PASS] {0}  (期望 {1}，实际 {2})' -f $Name, $Expected, $Actual) -ForegroundColor Green
        }
        else {
            Write-Host ('   [FAIL] {0}  (期望 {1}，实际 {2})' -f $Name, $Expected, $Actual) -ForegroundColor Red
            $script:fail++
        }
    }

    Write-Host ' 1) 增量算法 Get-TrafficDelta' -ForegroundColor Cyan
    Assert-Equal 100 (Get-TrafficDelta -Prev 1000 -Current 1100) '正常增长'
    Assert-Equal 0 (Get-TrafficDelta -Prev 5 -Current 5) '计数器未变化'
    Assert-Equal 50 (Get-TrafficDelta -Prev 9000 -Current 50) '重启后计数器归零 → 取当前值'
    Assert-Equal 50 (Get-TrafficDelta -Prev $null -Current 50) '新网卡首次出现 → 取当前值'
    Assert-Equal 4294967296 (Get-TrafficDelta -Prev 0 -Current 4294967296) '超过 4GB 不溢出'
    Assert-Equal 0 (Get-TrafficDelta -Prev 10 -Current -1) '异常负值按 0 处理'

    Write-Host ' 2) 跨重启累计（含虚拟网卡过滤）' -ForegroundColor Cyan
    $savedOpt = $Script:Opt
    $Script:Opt = [ordered]@{ Scope = 'physical'; Include = $null; Exclude = $null; Provider = 'netadapter' }
    try {
        $st = New-EmptyState
        $t0 = Get-Date '2026-01-01 10:00:00'

        # 第一次运行：只记基线
        $s1 = [ordered]@{ provider = 'netadapter'; time = $t0; ifaces = @{
                'guid-lan'  = [ordered]@{ name = '以太网'; desc = 'Realtek'; physical = $true; rx = 1000; tx = 200 }
                'guid-vm'   = [ordered]@{ name = 'VMnet8'; desc = 'VMware'; physical = $false; rx = 777; tx = 777 }
            } }
        $d1 = Update-StateFromSample -State $st -Sample $s1 -Baseline
        $st.initialized = $true
        Assert-Equal 0 $d1.rx '基线采样不计流量'
        Assert-Equal 777 $st.ifaces['guid-vm'].lastRx '虚拟网卡原始值仍被记录（便于换 Scope 后不重复计数）'

        # 正常运行 10 分钟
        $s2 = [ordered]@{ provider = 'netadapter'; time = $t0.AddMinutes(10); ifaces = @{
                'guid-lan'  = [ordered]@{ name = '以太网'; desc = 'Realtek'; physical = $true; rx = 6000; tx = 1200 }
                'guid-vm'   = [ordered]@{ name = 'VMnet8'; desc = 'VMware'; physical = $false; rx = 5000; tx = 5000 }
            } }
        $d2 = Update-StateFromSample -State $st -Sample $s2
        Assert-Equal 5000 $d2.rx '物理网卡增量 = 6000-1000'
        Assert-Equal 1000 $d2.tx '物理网卡增量 = 1200-200'
        Assert-Equal 0 $st.ifaces['guid-vm'].rx '虚拟网卡不计入统计范围'

        # 关机重启：计数器归零
        $s3 = [ordered]@{ provider = 'netadapter'; time = $t0.AddDays(1); ifaces = @{
                'guid-lan'  = [ordered]@{ name = '以太网'; desc = 'Realtek'; physical = $true; rx = 300; tx = 100 }
            } }
        $d3 = Update-StateFromSample -State $st -Sample $s3
        Assert-Equal 300 $d3.rx '重启后按新计数器继续累计'
        Assert-Equal 100 $d3.tx '重启后按新计数器继续累计'
        Assert-Equal 5300 $st.totalRx '总计 = 5000 + 300（跨重启不丢）'
        Assert-Equal 1100 $st.totalTx '总计 = 1000 + 100（跨重启不丢）'
        Assert-Equal 5000 $st.days['2026-01-01'].rx '按天分桶正确'
        Assert-Equal 300 $st.days['2026-01-02'].rx '按天分桶正确（重启后新的一天）'

        # 再开机（提前于重启前的数值，验证不会重复计数）
        $s4 = [ordered]@{ provider = 'netadapter'; time = $t0.AddDays(1).AddMinutes(5); ifaces = @{
                'guid-lan'  = [ordered]@{ name = '以太网'; desc = 'Realtek'; physical = $true; rx = 500; tx = 200 }
            } }
        $d4 = Update-StateFromSample -State $st -Sample $s4
        Assert-Equal 200 $d4.rx '同一开机内继续按差值累计'
        Assert-Equal 5500 $st.totalRx '总计 = 5300 + 200'
    }
    finally { $Script:Opt = $savedOpt }

    Write-Host ' 3) 序列化往返' -ForegroundColor Cyan
    $tmpState = Join-Path $env:TEMP ('tm-selftest-' + [Guid]::NewGuid().ToString('N') + '.json')
    $saveFile = $Script:StateFile
    try {
        $Script:StateFile = $tmpState
        $rt = New-EmptyState
        $rt.initialized = $true
        $rt.totalRx = 12345678901
        $rt.days['2026-01-01'] = [ordered]@{ rx = 555; tx = 666 }
        $rt.ifaces['g1'] = [ordered]@{ name = '以太网'; desc = 'd'; lastRx = 1; lastTx = 2; rx = 3; tx = 4; seenAt = '2026-01-01T00:00:00' }
        Save-State -State $rt
        $back = Get-State
        Assert-Equal 12345678901 $back.totalRx '大数值（>4GB）往返无损'
        Assert-Equal 555 $back.days['2026-01-01'].rx '按天数据往返无损'
        Assert-Equal '以太网' $back.ifaces['g1'].name '中文网卡名往返无损'
    }
    finally {
        $Script:StateFile = $saveFile
        Remove-Item -LiteralPath $tmpState -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    if ($script:fail -eq 0) { Write-Host ' 全部自检通过 √' -ForegroundColor Green; return 0 }
    Write-Host (' 自检失败 {0} 项 ×' -f $script:fail) -ForegroundColor Red
    return 1
}

#endregion

#region ── 帮助 / 主入口 ───────────────────────────────────────────────────────

function Show-Help {
    Get-Help -Name $PSCommandPath -Full -ErrorAction SilentlyContinue
    if ($?) { return }
    Write-Host @'
TrafficMonitor —— 网络流量统计器（关机 / 重启后继续累计）

用法：
  TrafficMonitor.ps1 [-Action <status|run|report|reset|install|uninstall|selftest|help>] [选项]

常用：
  -Action status                 查看本次开机 / 今天 / 本月 / 总计用量（默认）
  -Action report -Days 30        最近 30 天日报表 + 按月汇总
  -Action install                注册开机自启（非管理员=登录时启动；管理员=SYSTEM 开机启动）
  -Action install -InstallMode startup   强制服务级开机启动（需管理员）
  -Action uninstall [-Purge]     移除计划任务（-Purge 连账本一起删）
  -Action reset [-Force]         清零账本，从当前时刻重新计数
  -Action run -Live              前台运行并实时刷新速率（Ctrl+C 退出，退出时自动保存）
  -Action selftest               运行算法自检
  -Json                          以 JSON 输出 status / report 结果

选项：
  -IntervalSeconds 5   采样间隔（秒）
  -Scope physical      统计范围：physical 仅物理网卡（默认）/ all 全部网卡
  -IncludeAdapter, -ExcludeAdapter   按网卡名或描述做正则过滤
  -StatePath <路径>    指定账本文件位置
  -Provider auto       采集方式：auto / netadapter / perfcounter
'@
}

Initialize-Paths
$Script:Opt = [ordered]@{
    Scope    = $Scope
    Include  = $IncludeAdapter
    Exclude  = $ExcludeAdapter
    Provider = $Provider
}

switch ($Action) {
    'status' { Show-Status }
    'report' { Show-Report }
    'reset' { Reset-Counters }
    'install' { Install-Monitor }
    'uninstall' { Uninstall-Monitor }
    'selftest' { $code = Invoke-SelfTest; exit $code }
    'help' { Show-Help }
    'run' { $code = Invoke-MonitorLoop; exit $code }
}

#endregion
