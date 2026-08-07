# VNC远程桌面

## 一、概述

VNC（Virtual Network Computing）允许从 Windows 等客户端远程访问 Ubuntu 服务器的图形化桌面环境，适合不习惯纯命令行操作的用户。

整个过程分为三部分：
1. 在 Ubuntu 上安装和配置 VNC 服务器及桌面环境
2. 在 Windows 上安装 VNC 客户端
3. 连接并进行安全设置

推荐组合：**TigerVNC**（服务端）+ **LXDE** 或 **XFCE** 桌面环境。

## 二、最终可行方案（经过完整调试验证）

以下是经过多次调试后最终验证可行的完整步骤。

### 前提条件

- 已经通过 SSH 连接到服务器
- 拥有 root 或 sudo 权限

### 第一步：基础环境准备与安装

更新软件列表并安装桌面环境和 VNC 服务器。推荐安装 LXDE 轻量级桌面和 TigerVNC：

```bash
sudo apt-get update
sudo apt-get install lxde tigervnc-standalone-server -y
```

> 其他桌面选择：XFCE 也是一个很好的选择，命令为：
> ```bash
> sudo apt install xfce4 xfce4-goodies tigervnc-standalone-server tigervnc-common -y
> ```

### 第二步：为普通用户配置 VNC

建议用普通用户（如 `ubuntu`）运行 VNC 服务，这是最安全、最稳定的方式。

```bash
# 切换到普通用户（如果当前是 root）
su - ubuntu
```

#### 设置 VNC 密码

```bash
vncserver
```
输入并确认一个 VNC 专用密码（8位以上，与 Linux 用户密码无关），询问 view-only 密码时选 `n`。

#### 杀掉测试会话

```bash
vncserver -kill :1
```

`:1` 对应 TCP 端口 5901，`:2` 对应 5902，依此类推。

#### 创建 VNC 启动脚本

```bash
nano ~/.vnc/xstartup
```

将内容替换为（启动 LXDE 桌面）：

```bash
#!/bin/bash
/usr/bin/startlxde
```

或使用 XFCE：

```bash
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
startxfce4 &
```

为脚本添加可执行权限：

```bash
chmod +x ~/.vnc/xstartup
```

回到 root 用户进行系统级配置：

```bash
exit
```

^vnc-startup-setup

### 第三步：将 VNC 配置为系统服务

创建 systemd 服务文件：

```bash
sudo nano /etc/systemd/system/vncserver@.service
```

粘贴以下经过验证的最终配置：

```ini
[Unit]
Description=Start TigerVNC server at startup
After=syslog.target network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu

ExecStart=/usr/bin/vncserver -fg :1 -geometry 1920x1080 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
```

关键配置说明： ^vnc-service-config-key
- `Type=simple` 和 `-fg` 参数：使用更稳定的服务模式
- `-localhost no`：**强制 VNC 在所有公网 IP 上监听**，允许外部连接（这一点非常重要）
- `-geometry 1920x1080`：远程桌面分辨率，可按需修改
- `-depth 24`：颜色深度
- 请将 `User` 和 `Group` 改为你实际的用户名

### 第四步：启动并验证 VNC 服务

```bash
# 重载 systemd 配置
sudo systemctl daemon-reload

# 开机自启
sudo systemctl enable vncserver@1.service

# 启动服务
sudo systemctl start vncserver@1.service

# 检查服务状态
sudo systemctl status vncserver@1.service

# 检查端口 5901 是否在 0.0.0.0 上监听
sudo ss -tlpn | grep 5901
```

服务状态应为 `active (running)`，端口 5901 应在 `0.0.0.0` 上监听。

^vnc-service-management

### 第五步：配置防火墙与安全组

**服务器内部防火墙（ufw）：**

```bash
sudo ufw allow 5901/tcp
sudo ufw reload
```

**云服务商安全组（至关重要）：**

1. 登录云服务商控制台（阿里云、腾讯云等）
2. 找到服务器实例的"安全组"配置
3. 添加入站规则，允许 TCP 协议 5901 端口从 `0.0.0.0/0` 访问

## 三、安装 VNC 桌面环境（XFCE 方案备选）

如果希望使用 XFCE 桌面环境（功能更丰富），安装步骤：

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install xfce4 xfce4-goodies tigervnc-standalone-server tigervnc-common -y
```

其余步骤（设置密码、配置 xstartup、创建服务）与上述 LXDE 方案相同，只需将 xstartup 内容改为 XFCE 启动命令即可。

## 四、Windows 客户端连接

### 1. 下载 VNC Viewer

推荐使用 TigerVNC Viewer（完全免费，与服务端匹配）：
- 下载地址：https://tigervnc.org/
- 或者 RealVNC Viewer（界面更友好，个人使用免费）

### 2. 连接到 Ubuntu 桌面

**方式一：直连（公网环境）**

1. 在 Ubuntu 终端获取 IP：`ip a` 或 `hostname -I`
2. 打开 VNC Viewer
3. 输入 `服务器公网IP:1`（例如 `192.168.1.10:1` 或 `203.0.113.5:1`）
4. 忽略加密警告，点"Continue"
5. 输入 VNC 专用密码

**方式二：通过 SSH 隧道连接（推荐，更安全）**

VNC 协议本身不加密，使用 SSH 隧道可以保护数据安全：

```powershell
# 在 Windows PowerShell/CMD 中建立 SSH 隧道
ssh -L 5901:localhost:5901 ubuntu@你的UbuntuIP地址
```

保持该终端窗口不关闭。然后：

1. 打开 VNC Viewer
2. 连接地址填写 `localhost:1` 或 `127.0.0.1:1`
3. 输入 VNC 密码

这样 VNC 连接就会被包裹在 SSH 加密隧道中传输。

^vnc-client-connect

## 五、常见问题与排查

### 1. 连接后只看到灰色或黑色屏幕

检查 xstartup 文件内容是否正确，并确认有可执行权限：
```bash
ls -la ~/.vnc/xstartup
```

### 2. 连接被拒绝

- 确认服务状态：`sudo systemctl status vncserver@1.service`
- 确认安全组已开放 5901 端口
- 确认使用了 `-localhost no` 参数

### 3. 端口 5901 未监听在 0.0.0.0

使用 `sudo ss -tlpn | grep 5901` 检查。如果显示 `127.0.0.1:5901`，说明 `-localhost no` 未生效。

### 4. 画面卡顿或不流畅

- 考虑更换更轻量的桌面环境（LXDE 比 XFCE 更轻）
- 降低分辨率（如 `-geometry 1280x720`）
- 减少颜色深度（如 `-depth 16`）

### 5. 用户名密码错误

VNC 密码是独立于 Linux 用户密码的，使用 `vncserver` 命令设置。如需修改，以当前用户身份重新运行 `vncserver` 会提示设置新密码。

## 六、相关笔记

- [[SSH配置与远程连接]] -- SSH 连接服务器是操作 VNC 的前置步骤
- [[旧笔记本改内网服务器]] -- 内网服务器配合 VNC 实现远程桌面管理
- [[宝塔面板部署]] -- 宝塔面板与 VNC 同为服务器管理工具
- [[域名配置]] -- 反向代理与域名绑定
- [[Docker入门]] -- Docker 化的服务部署
