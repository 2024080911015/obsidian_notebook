# 网络流量统计（TrafficMonitor）

一个单文件 PowerShell 脚本，持续统计本机**累计用了多少流量**（接收/发送）。
账本存在磁盘上，**关机、重启、注销后都接着计数**，不丢也不重复。

实际运行效果：

```
==================================================================
 TrafficMonitor · 网络流量统计
==================================================================
 状态文件   : C:\ProgramData\TrafficMonitor\state.json
 采集方式   : auto（NetAdapter → 性能计数器）
 统计范围   : physical（仅物理网卡，忽略虚拟/隧道网卡）
 监测进程   : 运行中（2 秒前更新）
 监测开始   : 2026-10-10 13:11:49
 已监测     : 5 分 3 秒（跨 1 次开机）

                       接收(下载)      发送(上传)            合计
 --------------------------------------------------------------
 本次开机                 8.18 MB       621.18 MB       629.36 MB
 今天                     8.18 MB       621.18 MB       629.36 MB
 本月                     8.18 MB       621.18 MB       629.36 MB
 总计(自监测开始)         8.18 MB       621.18 MB       629.36 MB

 实时速率   ↓ 10.57 KB/s   ↑ 540 B/s
==================================================================
```

本笔记同目录下即是工具本体：

| 文件 | 说明 |
| --- | --- |
| `TrafficMonitor.ps1` | 主程序（唯一必需，含注释与 `-Action help` 帮助） |
| `TrafficMonitor.cmd` | 双击即看用量的启动器 |

---

## 一、要解决的问题

Windows 自带的"设置 → 网络和 Internet → 数据使用量"只能看最近 30 天、且按应用拆分，看不到"我这台机器从装好到现在一共跑了多少流量"，也不会跨重启累计。

自己写一个，难点不在读数，而在**两件事**：

1. 网卡计数器**每次开机都归零**，不能直接当作累计值；
2. 不能把重启前已经算过的流量**再算一遍**。

---

## 二、核心原理：计数器为什么会归零

Windows 把每块网卡的收发字节数记在**网卡驱动**里，通过 `Get-NetAdapterStatistics` 读出：

```powershell
Get-NetAdapterStatistics | Select-Object Name, ReceivedBytes, SentBytes
```

| 字段 | 含义 |
| --- | --- |
| `ReceivedBytes` | 自**网卡本次初始化**以来接收的总字节 |
| `SentBytes` | 自**网卡本次初始化**以来发送的总字节 |

关键词是"自本次初始化以来"。网卡初始化发生在：**开机、驱动重载、网卡禁用后重新启用**。所以这个值：

- 是**单调递增**的（64 位计数器，不会回绕）；
- 但**会突然变小甚至归零** —— 只要机器重启过。

结论：它是一个"**本次开机以来**"的读数，想得到"**累计**"必须自己攒。

---

## 三、算法设计

### 3.1 增量计算规则

设 `last` 为上次记录的原始值，`current` 为本次读到的原始值：

| 情况 | 判断 | 增量 |
| --- | --- | --- |
| 正常增长 | `current >= last` | `current - last` |
| 计数器归零 | `current < last` | `current`（即"自归零以来的全部流量"） |
| 新网卡 | 没有 `last` | `current` |
| 异常负值 | `current < 0` | `0` |

对应脚本里的纯函数：

```powershell
function Get-TrafficDelta {
    param($Prev, [long]$Current)
    if ($Current -lt 0) { return [long]0 }
    if ($null -eq $Prev) { return $Current }      # 新网卡：从 0 开始
    $p = [long]$Prev
    if ($p -lt 0) { return $Current }
    if ($Current -ge $p) { return [long]($Current - $p) }
    return [long]$Current                          # 计数器已归零
}
```

### 3.2 主循环伪代码

```
每 5 秒：
    sample = 读取所有网卡的 (ReceivedBytes, SentBytes)，以网卡 GUID 为键
    for 每块网卡:
        delta = Get-TrafficDelta(last[guid], sample[guid])
        last[guid] = sample[guid]                  # 原始值照记，不参与统计
        if 该网卡在统计范围内:
            总量 += delta
            今日 += delta
            本次开机 += delta
    写 state.json（原子写：先写 .tmp 再改名）
```

### 3.3 为什么不会重复计数（场景推演）

假设 15:00 时账本记录 `last = 1000 MB`，随后关机，第二天开机。

| 时刻 | 事件 | 网卡原始值 | `last` | 判定 | 增量 | 累计 |
| --- | --- | --- | --- | --- | --- | --- |
| 15:00 | 关机前最后一次采样 | 1000 MB | 1000 MB | — | — | 1000 MB |
| 次日 09:00 | 开机，登录后第一次采样 | 80 MB | 1000 MB | `80 < 1000` → 归零 | **80 MB** | 1080 MB |
| 次日 09:05 | 正常采样 | 120 MB | 80 MB | 正常增长 | 40 MB | 1120 MB |

**既没有丢掉关机前的量，也没有把 1000 MB 重算一遍。** 而且因为重启后计数器是从 0 开始累计的，登录后第一次采样读到的 80 MB 天然包含了"**开机 → 登录之间**"产生的流量，等于顺手把它补计进来了。

### 3.4 三个关键细节

**① 账本原子写，防止断电损坏**

```powershell
$json = $State | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $StateFile -Force
```

先写 `.tmp` 再 `Move-Item` 覆盖，避免写到一半断电留下半截 JSON。解析失败时会自动备份成 `.corrupt-时间戳` 并重建，不至于整个账本报废。

**② 单实例锁，防止两份进程各加一遍**

用文件独占句柄做跨会话的互斥（普通用户没有 `SeCreateGlobalPrivilege`，用 `Global\` 命名互斥体会失败，所以不用互斥体）：

```powershell
$fs = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
# 拿不到就是已有实例在跑 → 退出码 2
```

进程崩溃时句柄由系统释放，不会留下"死锁"。

**③ 被排除的网卡也要记录原始值**

统计范围可以过滤虚拟网卡，但**原始计数器照记不误**，只是不计入总量。这样中途改 `-Scope` 时不会因为"重新建立基线"而重复或漏算。

---

## 四、安装与使用

### 4.1 快速开始

在 `网络流量统计/` 目录（本笔记同目录）下执行：

```powershell
# ① 安装开机自启，并立刻开始计数
powershell -ExecutionPolicy Bypass -File .\TrafficMonitor.ps1 -Action install

# ② 查看用了多少流量（默认动作就是 status）
powershell -ExecutionPolicy Bypass -File .\TrafficMonitor.ps1

# ③ 最近 30 天日报表
powershell -ExecutionPolicy Bypass -File .\TrafficMonitor.ps1 -Action report -Days 30
```

也可以直接双击 `TrafficMonitor.cmd` 看用量。

### 4.2 全部命令

| 动作 | 说明 |
| --- | --- |
| `status` | 查看本次开机 / 今天 / 本月 / 总计 + 实时速率 + 各网卡累计（**默认**） |
| `report` | 最近 N 天日报表 + 按月汇总 |
| `run` | 后台监测循环（由计划任务调用）；加 `-Live` 可前台实时刷新，Ctrl+C 退出时自动保存 |
| `install` | 复制脚本到状态目录并注册开机自启计划任务 |
| `uninstall` | 移除计划任务；加 `-Purge` 连账本一起删 |
| `reset` | 清零账本，从当前时刻重新计数（自动停止监测、旧账本备份为 `.bak-时间戳`） |
| `selftest` | 内置自检，22 项断言校验增量算法与跨重启逻辑 |
| `help` | 帮助 |

### 4.3 参数表

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-IntervalSeconds` | `5` | 采样间隔（秒）。越小越精确，5 秒足够，不建议小于 2 |
| `-Scope` | `physical` | `physical` 只统计物理网卡；`all` 统计全部网卡 |
| `-IncludeAdapter` | 无 | 白名单，按"网卡名 + 描述"做正则匹配，可传多个 |
| `-ExcludeAdapter` | 无 | 黑名单，正则匹配，优先级高于白名单 |
| `-StatePath` | `C:\ProgramData\TrafficMonitor\state.json` | 账本位置；若指向目录会自动追加 `state.json` |
| `-Provider` | `auto` | 采集方式：`netadapter` / `perfcounter` / `auto`（优先前者，失败自动降级） |
| `-InstallMode` | `auto` | `auto`＝管理员用开机启动，否则用登录时启动；可强制 `startup` / `logon` |
| `-WatchdogMinutes` | `5` | 自愈检查间隔（分钟）；进程被意外终止后最多这么久自动拉起，`0` 关闭 |
| `-Days` | `7` | `report` 显示最近多少天 |
| `-Json` | 关 | `status` / `report` 以 JSON 输出，便于其他程序读取 |
| `-Watch` / `-Live` | 关 | `run` 模式下在控制台实时刷新速率 |
| `-Force` | 关 | `reset` / `uninstall` 跳过交互确认 |

### 4.4 常用示例

```powershell
# 前台实时看速率（Ctrl+C 退出，退出时自动落盘）
.\TrafficMonitor.ps1 -Action run -Live

# 只统计以太网和 WLAN
.\TrafficMonitor.ps1 -Action status -Scope all -IncludeAdapter '以太网','WLAN'

# 排除蓝牙网络连接
.\TrafficMonitor.ps1 -Action status -ExcludeAdapter '蓝牙'

# 2 秒采样一次安装
.\TrafficMonitor.ps1 -Action install -IntervalSeconds 2

# 账本换个位置（install 会把这个路径写进计划任务）
.\TrafficMonitor.ps1 -Action install -StatePath 'D:\流量统计\state.json'

# 清零重来 / 彻底卸载
.\TrafficMonitor.ps1 -Action reset
.\TrafficMonitor.ps1 -Action uninstall -Purge

# 供其他程序读取的 JSON
.\TrafficMonitor.ps1 -Action status -Json
```

### 4.5 运行期文件

默认都在 `C:\ProgramData\TrafficMonitor\`：

| 文件 | 说明 |
| --- | --- |
| `state.json` | **账本**，所有累计数据；删掉等于清零 |
| `monitor.log` | 运行日志（超 1 MB 自动只留最后 1000 行） |
| `monitor.lock` | 单实例锁 |
| `TrafficMonitor.ps1` | `install` 时自动复制的脚本副本（计划任务执行的是它，所以原文件改名/移动不影响运行） |
| `TrafficMonitor.cmd` | `install` 时一并复制的启动器，在安装目录里直接双击即可看用量 |

### 4.6 两种自启模式

`install` 会根据权限自动选择：

| 模式 | 触发 | 权限 | 特点 |
| --- | --- | --- | --- |
| `startup` | 开机时（SYSTEM 账户） | **需管理员** | 开机数秒后即开始采样，最精确，不受登录/注销影响 |
| `logon` | 当前用户登录时 | 普通用户即可 | 开机到登录之间的流量会在登录后第一次采样时一并补计 |

非管理员运行 `install` 只有 `logon` 一条路（注册 SYSTEM 级任务必须提权）。想升级：

```powershell
# 以管理员身份打开 PowerShell 再执行
.\TrafficMonitor.ps1 -Action install -InstallMode startup
```

### 4.7 自愈：进程被杀掉也会自己回来

长期驻留的服务最怕"悄悄死掉" —— 用户不会天天去看它还在不在。所以 `install` 会注册**两个触发器**：

| 触发器 | 作用 |
| --- | --- |
| `LogonTrigger`（或 `BootTrigger`） | 登录/开机后立刻开始计数 |
| `TimeTrigger` + `Repetition=PT5M`（**无限期**重复） | 每 5 分钟让调度器检查一次；配合 `MultipleInstances=IgnoreNew`，正在跑时新实例被**直接忽略**（不产生额外进程、不耗 CPU），一旦进程被意外终止，最多 5 分钟自动拉起 |

两个坑记一下：

- **`-RepetitionDuration` 千万别给 `[TimeSpan]::MaxValue`** —— PowerShell 会生成 `P99999999DT23H59M59S`，注册时报
  `The task XML contains a value which is incorrectly formatted or out of range`。
  正确做法是**完全不给 Duration**，这才是真正的"无限期"：
  ```powershell
  New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
  # → <Repetition><Interval>PT5M</Interval><StopAtDurationEnd>true</StopAtDurationEnd></Repetition>
  ```
- **`New-ScheduledTaskSettingsSet` 默认生成 `StopOnIdleEnd=true`**，而 PS 5.1 **没有 `New-ScheduledTaskIdleSettings`**
  这个 cmdlet（我实测报 `CommandNotFoundException`），所以只能导出 XML 改值再注册：
  ```powershell
  $xml = Export-ScheduledTask -TaskName TrafficMonitor
  $patched = $xml -replace '(<StopOnIdleEnd[^>]*>)true(</StopOnIdleEnd>)', '${1}false${2}'
  Register-ScheduledTask -TaskName TrafficMonitor -Xml $patched -Force
  ```

**断一小段也不丢数据**：网卡计数器一直在累加，重启后按差值一次性补计，所以自愈间隔内的流量不会丢。

```powershell
.\TrafficMonitor.ps1 -Action install -WatchdogMinutes 2   # 改成 2 分钟
.\TrafficMonitor.ps1 -Action install -WatchdogMinutes 0   # 关闭自愈
```

想事后追因（计划任务的操作日志默认关闭，且**开启需要管理员**）：

```powershell
wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational -MaxEvents 30
```

---

## 五、统计范围：为什么默认不统计所有网卡

如果把所有网卡的流量加起来，会**重复计数**，典型重复源：

| 网卡 | 为什么会重复 |
| --- | --- |
| `Tailscale` / `WireGuard` / `OpenVPN` | 隧道流量本身就跑在物理网卡上 |
| `VMware Network Adapter VMnet1/8` | 宿主与虚拟机之间的本地虚拟网络 |
| `Hyper-V` / `vEthernet` / `Wintun` / `TAP-Windows` | 虚拟网卡，数据实际由物理网卡收发 |
| `Microsoft Wi-Fi Direct Virtual Adapter`（"本地连接* 2"） | 热点/直连虚拟网卡，数据实际从 `WLAN` 收发 |

所以默认 `-Scope physical`，只统计 `HardwareInterface = $true` 的物理网卡，并始终排除回环、Teredo、6to4、IP-HTTPS 等伪接口。本机（装了 VMware、Tailscale、代理 TUN）判定的结果就是"以太网 + WLAN"两块。

需要全都算时用 `-Scope all`。

---

## 六、账本数据结构

`state.json` 大致长这样（每个网卡以 **GUID** 为键，不怕改名）：

```json
{
  "version": 1,
  "createdAt": "2026-10-10T13:11:49.9901415+08:00",
  "updatedAt": "2026-10-10T13:16:29.4019644+08:00",
  "initialized": true,
  "bootId": "2026-10-10T12:44:50.5000000+08:00",
  "bootCount": 1,
  "totalRx": 7725116,
  "totalTx": 650458174,
  "session": { "bootId": "...", "startedAt": "...", "rx": 0, "tx": 0 },
  "days": {
    "2026-10-10": { "rx": 7725116, "tx": 650458174 }
  },
  "ifaces": {
    "{C445FBF8-E8E0-4691-98FA-CF2777BC48EE}": {
      "name": "以太网", "desc": "Realtek PCIe GbE Family Controller",
      "lastRx": 145676986, "lastTx": 1156347765,
      "rx": 7725116, "tx": 650458174,
      "seenAt": "2026-10-10T13:16:29+08:00"
    }
  }
}
```

| 字段 | 含义 |
| --- | --- |
| `initialized` | 是否已建立基线。首次运行/清零后为 `false`，此时只记原始值不计流量 |
| `bootId` / `bootCount` | 开机标识与开机次数，用于统计"跨了几次开机"和重置"本次开机" |
| `totalRx` / `totalTx` | 自监测开始的总量，**权威值** |
| `days` | 按天分桶，用于日报表和"今天/本月" |
| `ifaces[*].lastRx/lastTx` | **原始计数器快照**，增量算法的输入 |
| `ifaces[*].rx/tx` | 该网卡的累计贡献（只统计范围内的） |

不变式（自检里会校验）：`total == 各天之和 == 范围内各网卡累计之和`。

---

## 七、精度与已知边界

| 情况 | 影响 |
| --- | --- |
| 采样间隔 | 进程被强杀 / 直接断电时，最多丢失最后一个周期的流量（默认 ≤ 5 秒） |
| 正常关机 / 注销 | 退出时会把账本落盘，几乎不丢 |
| 重启边界 | 若上次会话计数器很小（记为 A），而本次开机到第一次采样间已超过 A，则最多少计 A。**该偏差自限**：A 越小偏差越小，最大也只是一个"很小的上次会话量" |
| 睡眠 / 休眠 | 计数器不清零，按差值照常统计，无影响 |
| 计数器回绕 | 64 位计数器不会回绕；万一变小一律按"重置"处理，不会算出天文数字 |
| 网卡热插拔 | 新网卡按"从 0 开始"计入 |
| 统计对象 | 只统计**总量**；"哪个程序用了多少"请看系统自带的数据使用量 |

**理想的部署方式**是管理员模式的 `startup`：开机数秒后就开始采样，"重启边界"这个边界情况在原理上被消除。

---

## 八、常见问题排查

**Q：怎么确认它真的在跑？**

```powershell
.\TrafficMonitor.ps1 -Action status          # 看 "监测进程 : 运行中（N 秒前更新）"
Get-ScheduledTask -TaskName TrafficMonitor   # 看计划任务状态
Get-Content C:\ProgramData\TrafficMonitor\monitor.log -Tail 20
```

日志里应该能看到 `监测启动`、`检测到新的开机会话（第 N 次开机）` 这类记录。

**Q：数字看着不对，怀疑重复计数？**

```powershell
# 直接对比原始计数器，看 10 秒漂移量是否符合预期
$a = Get-NetAdapterStatistics | Where-Object Name -eq '以太网'
Start-Sleep 10
$b = Get-NetAdapterStatistics | Where-Object Name -eq '以太网'
"recv={0} sent={1}" -f ($b.ReceivedBytes - $a.ReceivedBytes), ($b.SentBytes - $a.SentBytes)
```

也可以和 `netstat -e` 的 Bytes 行交叉验证。注意本机若长期有后台上传（云盘、代理、种子），数字会比预期大，属正常。

**Q：中文乱码？**

脚本是 **UTF-8 with BOM**。PowerShell 5.1 对无 BOM 的 UTF-8 会按 GBK 解析导致中文和语法双双出错。改脚本时务必保持带 BOM：

```powershell
$t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true)))
```

**Q：资源占用多少？**

实测稳定态 **CPU ≈ 1.5% 单核**（每 5 秒一次 `Get-NetAdapterStatistics`，单次约 130 ms；首次含网卡映射建立约 1.1 s），内存约 80 MB（PowerShell 进程自身开销）。嫌高就把 `-IntervalSeconds` 调到 10~30。

**Q：会不会装了两个实例重复计数？**

不会，`monitor.lock` 独占占用，第二个实例直接退出（退出码 2）。`reset` / `install` 也会先停掉正在运行的实例。

---

### 案例：上传流量飙到 3.4 MB/s，一路排查到 Moonlight 串流

现象：`status` 显示 20 分钟上传了 **2.19 GB**，而接收只有 8 MB —— 典型的"只发不收"。

**排查路径（按顺序排除）：**

| 步骤 | 手段 | 结果 |
| --- | --- | --- |
| ① 定位到哪块网卡 | 各网卡 10 秒增量对比 | 只有 `以太网` 在发（3.4 MB/s），`Mihomo`/`Tailscale`/`WLAN`/热点网卡都是 0 |
| ② 怀疑代理 | Clash 的 `/connections` 接口（`127.0.0.1:9097`，secret 从 `clash-verge-check.yaml` 取） | mihomo 累计只上传 **39.6 MB**，排除 |
| ③ 怀疑 Windows 传递优化 | `Get-DeliveryOptimizationStatus` | 无任务，排除 |
| ④ 怀疑热点转发 | `192.168.137.x` 是 ICS 热点网段，检查 `SharedAccess` 服务 | 热点网卡 10 秒增量为 0，排除 |
| ⑤ 怀疑 iCloud | 进程连的是 Apple 的 `17.248.216.x` | 读它的日志发现只是每 20 分钟一次的 SQLite 重复报错，排除 |
| ⑥ **查串流服务端日志** | `Sunshine\config\sunshine.log` | **命中** |

**决定性证据：**

```
[13:06:11] Info: New streaming session started [active sessions: 1]
[13:06:12] Info: CLIENT CONNECTED
[13:14:48] Info: CLIENT DISCONNECTED
[13:18:54] Info: New streaming session started [active sessions: 1]
[13:18:54] Info: CLIENT CONNECTED
[13:18:54] Info: Creating encoder [hevc_nvenc]    ← 1080p60 / NVENC / Opus
```

实测上行 29 Mbps，正好是 1080p60 HEVC 串流的典型码率；而会话时间线（13:06–13:14、13:18:54 至今）
与观测到的上传曲线**完全吻合**。Moonlight 的视频流走 **UDP 47998/47999/48000**，
所以 `Get-NetTCPConnection` 里根本看不到它 —— 这也是前几步排查全部落空的原因
（握手用的 TCP 47984/47989 在协商完成后就关了，抓的时候只剩 `Listen`）。

**结论与启发：**

1. 这是**局域网串流**，不消耗外网带宽，但它确实是物理网卡上的真实字节 —— 本工具按网卡计数，
   自然把它算进"上传"。
2. 排查"只发不收"的大流量时，**优先想到视频推流/串流**（Sunshine、DLNA、投屏、直播），
   再看云备份、BT 做种。它们的共同特征都是"上传远大于下载"且速率**恒定**（CBR 编码）。
3. 按网卡计数只能得到总量，**无法区分局域网和外网**。要精确区分得用 WFP/ETW 按连接统计，
   这一版没做。
4. 排查顺序上，"按进程看连接数"会误导：当时连接数最多的是 `verge-mihomo`（17 条），
   但它的流量只有 39.6 MB —— **连接数多 ≠ 流量大**，必须用字节数说话。

---

## 九、实测验证记录

**① 内置自检**（`-Action selftest`，22 项全通过）

```
 1) 增量算法 Get-TrafficDelta           6 项：正常增长/无变化/归零/新网卡/超 4GB/负值
 2) 跨重启累计（含虚拟网卡过滤）        13 项：基线不计流量、虚拟网卡过滤、重启补计、按天分桶
 3) 序列化往返                          3 项：大数值(>4GB)/按天数据/中文网卡名
 全部自检通过 √
```

**② 重启模拟（真实网卡）**

把账本里的计数器改成"重启前的大值"（107 GB，远大于当前原始值）后再采样：

| 项目 | 数值 |
| --- | --- |
| 补计增量 | `146,611,057` 字节 |
| 当时网卡原始值 | `146,611,779` 字节 |
| 误差 | **722 字节**（仅两次读取之间约百毫秒的正常流量） |

说明"重启后按本次开机计数器补计"这条路径精确正确，既不丢也不重复。

**③ 一致性**

`total == 各天之和 == 计入范围各网卡累计之和`；账本键为网卡 GUID；账本增量与网卡原始计数器增量一致，差异仅来自两次读取之间约 130 ms 的时间差。

**④ 单实例锁**

第二个 `run` 实例退出码为 2，不重复计数。

**⑤ 自愈能力**

用 `-WatchdogMinutes 1` 安装后 `Stop-Process -Force` 强杀监测进程（模拟被外部终止，无正常停止日志），
**50 秒后被重复触发器自动拉起**：

```
13:41:17 [INFO] 监测启动 PID=28376     ← 强杀发生在 13:41:23
13:42:17 [INFO] 监测启动 PID=32700     ← 自愈，账本随即恢复每 5 秒更新
```

杀进程期间丢失的时间段，在重启后由网卡计数器差值一次性补回，**实测无数据丢失**。

**⑥ 真实事故复盘**

部署当天 13:33:50 监测进程曾被外部终止（无正常停止日志，任务状态回到 `Ready`），
持续约 6 分钟无人察觉。事后做的两件事：关掉 `StopOnIdleEnd`、加上每 5 分钟的重复触发器。
计划任务的操作日志默认关闭，且开启需要管理员权限，所以没能取到终止原因 ——
这也是"给长期驻留的服务加自愈"比"事后追因"更实际的原因。

---

## 十、相关笔记

- [[计算机网络知识/WiFi篇|WiFi篇]] —— 无线侧的信道、带宽、协议标准
- [[计算机网络知识/内网穿透|内网穿透]] —— SSH 反向隧道、frp 等，流量来源之一
- [[计算机网络知识/自建代理节点|自建代理节点]] —— 代理/TUN 网卡为何要排除在统计范围外
- [[服务器运维/旧笔记本改内网服务器|旧笔记本改内网服务器]] —— 常驻服务机器的流量监控场景

---

## 附：一句话总结

> 网卡计数器是"本次开机以来"的读数，**会归零但不会回绕**。
> 只要把每次读到的原始值存下来做差分，遇到"变小"就按"归零重来"处理，
> 就能得到一份跨重启不丢不重的累计账本。
