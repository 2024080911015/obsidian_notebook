# 种子下载与BT

## 一、概述

在服务器上配置种子（BT）下载器，利用服务器 7x24 小时在线的网络连接下载大文件，然后再将文件传输到本地。本文使用 **qBittorrent-nox**（无图形界面版）作为下载客户端，通过 Web UI 远程管理。

## 二、Debian/Ubuntu 系统配置 qBittorrent

### 第一步：安装 qBittorrent-nox

```bash
# 连接到服务器
ssh your_username@your_server_ip

# 更新并安装
sudo apt update
sudo apt install qbittorrent-nox
```

安装过程中，系统会提示接受服务条款，按 `q` 键退出阅读，输入 `y` 同意。

### 第二步：创建专用运行用户

```bash
sudo adduser --system --group qbuser
```

### 第三步：配置 systemd 服务

```bash
sudo nano /etc/systemd/system/qbittorrent.service
```

粘贴以下内容：

```ini
[Unit]
Description=qBittorrent Command Line Client
After=network.target

[Service]
Type=forking
User=qbuser
Group=qbuser
UMask=007
ExecStart=/usr/bin/qbittorrent-nox -d --webui-port=8081
ExecStop=/usr/bin/killall -w -s 9 /usr/bin/qbittorrent-nox

[Install]
WantedBy=multi-user.target
```

> `--webui-port=8081` 是 Web UI 访问端口，可按需修改。^qb-service-config

### 第四步：启动并开机自启

```bash
sudo systemctl daemon-reload
sudo systemctl start qbittorrent
sudo systemctl enable qbittorrent
sudo systemctl status qbittorrent
```

### 第五步：防火墙配置

```bash
# Web UI 端口
sudo ufw allow 8081/tcp

# P2P 监听端口（TCP + UDP）
sudo ufw allow 6881/tcp
sudo ufw allow 6881/udp
```

### 第六步：访问 Web UI

浏览器访问：`http://your_server_ip:8081`

- **默认用户名**：`admin`
- **默认密码**：`adminadmin`

> 登录后务必立即修改默认用户名和密码：工具 > 选项 > Web UI。

## 三、Alinux/CentOS 系统配置

Alinux（以及 CentOS/RHEL）的配置过程核心步骤相同，主要差异在于包管理器和防火墙。^alinux-qb

### 安装 EPEL 扩展源

```bash
sudo yum install -y epel-release
# 或在较新系统上
sudo dnf install -y epel-release
```

### 安装 qBittorrent

```bash
sudo yum install -y qbittorrent-nox
# 或
sudo dnf install -y qbittorrent-nox
```

### 创建用户和服务

用户创建和 systemd 服务配置与 Ubuntu 完全相同（见上文步骤 2-4）。

### 配置 firewalld 防火墙

Alinux 使用 `firewalld` 而非 `ufw`：

```bash
# Web UI 端口
sudo firewall-cmd --zone=public --add-port=8081/tcp --permanent

# P2P 监听端口（TCP 和 UDP 都要开放）
sudo firewall-cmd --zone=public --add-port=60978/tcp --permanent
sudo firewall-cmd --zone=public --add-port=60978/udp --permanent

# 重新加载
sudo firewall-cmd --reload
```

参数说明：
- `--zone=public`：作用于公共区域
- `--permanent`：永久规则，重启后依然有效

## 四、文件传输到本地

### 方法一：SCP（命令行）

```bash
# 复制单个文件
scp your_username@your_server_ip:/home/qbuser/Downloads/movie.mp4 ~/Downloads/

# 复制整个文件夹（-r 递归）
scp -r your_username@your_server_ip:/home/qbuser/Downloads/my_files ~/Downloads/
```

### 方法二：SFTP（图形化客户端推荐）

使用 FileZilla、WinSCP 或 Cyberduck 等图形化客户端：

1. 新建连接，协议选择 **SFTP**
2. 主机填服务器 IP，端口填 22
3. 用户名和密码为 SSH 凭据
4. 连接后在分栏界面中，从服务器下载目录直接拖拽文件到本地

### 方法三：Samba 网络驱动器映射

将服务器下载文件夹映射为 Windows 网络驱动器，像访问本地磁盘一样管理文件。

#### 服务器端配置

```bash
# 安装 Samba
sudo apt update
sudo apt install samba

# 创建 Samba 用户密码
sudo smbpasswd -a your_username

# 备份并编辑配置
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
sudo nano /etc/samba/smb.conf
```

在文件末尾添加：

```ini
[Downloads]
comment = qBittorrent Downloads
path = /home/qbuser/Downloads
browseable = yes
writable = yes
guest ok = no
read only = no
valid users = your_username
```

重启 Samba 服务：

```bash
sudo systemctl restart smbd
sudo systemctl restart nmbd

# 防火墙放行
sudo ufw allow samba
```

#### Windows 端映射

1. 打开文件资源管理器，右键点击"此电脑" > "映射网络驱动器"
2. 选择一个盘符（如 `Q:`）
3. 文件夹填写：`\\服务器IP\Downloads`
4. 勾选"使用其他凭据连接"
5. 输入 Samba 用户名和密码

^samba-mapping

## 五、常见问题与故障排查

### 问题一：下载速度始终为 0 B/s，Peer 数为 0

这是最常见的问题，通常由**云服务商安全组**导致。

**诊断线索：**
- Trackers 列表中只有 DHT、PeX、LSD 等内置协议（没有 Tracker 网址）
- 这说明 qBittorrent 未能从网络获取种子元数据
- DHT 有节点（如 125 个），但 Peer 和 Seed 始终为 0

**根本原因：**
即使服务器内部防火墙（ufw/firewalld）开放了 P2P 端口，云服务商的安全组在外部拦截了入站 P2P 连接。

**解决方案：** ^bt-security-group-fix

1. 登录云服务商后台（阿里云/腾讯云/华为云等）
2. 找到服务器实例 > "安全组"配置
3. 添加两条入站规则：
   - **规则 A**：协议 TCP，端口 `60978`（或你的实际监听端口），来源 `0.0.0.0/0`
   - **规则 B**：协议 UDP，端口 `60978`，来源 `0.0.0.0/0`
4. 保存后等待一分钟生效
5. 在 qBittorrent 中右键任务 > "强制继续"

### 问题二：Web UI 无法登录

新版 qBittorrent 的默认密码是**随机生成**的，不是传统的 `adminadmin`。^qb-random-password

**获取随机密码：**

```bash
# 停止服务
sudo systemctl stop qbittorrent

# 清理旧配置（触发首次启动逻辑）
sudo rm -rf /home/qbuser/.config/qBittorrent

# 手动在前台运行，观察日志输出
sudo -u qbuser /usr/bin/qbittorrent-nox --webui-port=8080
```

在终端输出中寻找：

```
The Web UI administrator password is: XyZ123Abc
```

用这个随机密码登录后，立即在 Web UI 中修改为自己设置的密码。然后按 `Ctrl+C` 停止前台运行，重新启动服务：

```bash
sudo systemctl start qbittorrent
```

### 问题三：Tracker 信息为空

在中国大陆地区的服务器上，通过磁力链接获取 Tracker 信息常常失败。

**建议：**
- 优先下载 `.torrent` 种子文件（而非磁力链接），`.torrent` 文件自带 Tracker 信息
- 手动添加可用的 Tracker 服务器列表
- 在"工具 > 选项 > BitTorrent"中，勾选"启用 DHT"、"启用 PeX"、"启用 LSD"

### 问题四：P2P 端口检测失败

在 qBittorrent Web UI 中：
1. 工具 > 选项 > 连接
2. 查看"监听端口"是多少
3. 确保该端口的 TCP 和 UDP 都被云安全组和内部防火墙放行
4. 可以修改为一个非默认的端口（如 `60978`），避免被 ISP 限速

## 六、制作种子文件

### 制作步骤

1. 准备好要分享的文件或文件夹
2. 打开 BitTorrent 客户端（qBittorrent、uTorrent、Transmission 等）
3. 选择制作功能：
   - **qBittorrent**：工具 > Torrent 创建器
   - **uTorrent**：文件 > 创建新 Torrent
   - **Transmission**：文件 > 创建 Torrent 文件
4. 选择要分享的文件/文件夹
5. 添加 Tracker 地址（每行一个）
6. 可选设置：
   - **文件分块大小（Piece size）**：大文件选较大的分块
   - **私有种子（Private torrent）**：禁用 DHT 和 PEX，所有连接通过 Tracker
   - **立即做种（Start seeding）**：创建后立即上传
7. 保存 `.torrent` 文件
8. 分享种子文件给他人，并保持做种

^create-torrent

## 七、相关笔记

- [[SSH配置与远程连接]] -- 通过 SSH 连接和管理下载服务器
- [[宝塔面板部署]] -- 宝塔面板也可管理服务器文件
- [[Docker入门]] -- qBittorrent 可容器化部署
- [[VNC远程桌面]] -- 服务器图形化桌面管理
- [[旧笔记本改内网服务器]] -- 内网服务器上配置下载器
- [[域名配置]] -- 可配置域名访问 Web UI
