# SSH配置与远程连接

## 一、SSH基础概念

SSH（Secure Shell）是一种加密的网络传输协议，用于在不安全的网络中安全地访问远程服务器。几乎所有 Linux 服务器都默认安装了 SSH 服务端（sshd）。

### 1. 基本连接命令

```bash
# 默认使用当前用户名连接
ssh user@your_server_ip

# 指定端口连接（非默认22端口时）
ssh -p 端口号 user@your_server_ip

# 示例
ssh root@124.221.199.14
```

### 2. 连接失败常见原因

成功连接到服务器22端口但被拒绝，典型表现为 `Permission denied, please try again.`，这说明网络是通的，但身份验证失败。^permission-denied

排查顺序：
- 确认密码大小写、特殊字符是否正确
- 尝试先用普通用户（如 `ubuntu`）登录，再用 `sudo -i` 切换到 root
- 检查 `/etc/ssh/sshd_config` 中的 `PasswordAuthentication` 是否为 `yes`

## 二、SSH密钥认证

### 1. 为什么用密钥而非密码

- 密钥对认证远比密码安全，难以被暴力破解
- 自动化更方便，脚本和工具可以直接使用密钥连接
- 结合 autossh 等工具实现免密自动化重连

### 2. 生成密钥对

```bash
# 在本地机器上生成RSA密钥对（如果还没有）
ssh-keygen -t rsa
# 一路回车即可，密钥默认保存在 ~/.ssh/id_rsa 和 ~/.ssh/id_rsa.pub
```

### 3. 将公钥复制到服务器

```bash
# 将公钥复制到远程服务器
ssh-copy-id user@your_server_ip
# 输入一次密码后，之后就不需要密码了
```

完成后，`~/.ssh/id_rsa.pub` 中的公钥会被添加到服务器的 `~/.ssh/authorized_keys` 文件中。

### 4. 禁用密码登录（安全加固）

编辑服务器上的 `/etc/ssh/sshd_config`：

```ini
# 禁用密码认证
PasswordAuthentication no
# 只允许密钥认证
PubkeyAuthentication yes
```

修改后重启 SSH 服务：

```bash
sudo systemctl restart sshd
```

## 三、端口配置与防火墙

### 1. SSH 默认端口

SSH 默认使用 **22 端口**。如果连接失败且报错为 `Connection timed out` 或 `Connection refused`，说明端口未开放。

### 2. 云服务商安全组配置

在中国大陆使用云服务器（阿里云、腾讯云等）时，除了服务器内部的防火墙（如 ufw），还需要在云服务商后台的**安全组**中开放端口：

1. 登录云服务商控制台
2. 找到服务器实例的"安全组"配置
3. 添加入站规则，允许 TCP 协议的 22 端口从 `0.0.0.0/0` 访问

### 3. 服务器本地防火墙

```bash
# Ubuntu (ufw)
sudo ufw allow 22/tcp
sudo ufw reload

# Alinux/CentOS (firewalld)
sudo firewall-cmd --zone=public --add-port=22/tcp --permanent
sudo firewall-cmd --reload
```

## 四、SSH SOCKS代理与隧道转发

### 1. 动态端口转发（SOCKS代理）

通过 SSH 建立本地 SOCKS5 代理，让本地流量走服务器出口：

```bash
ssh -D 1080 -N -f user@your_server_ip
```

参数解释： ^ssh-d-params
- `-D 1080`：在本地机器上建立 SOCKS 代理，监听端口 1080
- `-N`：不执行远程命令，仅用于端口转发
- `-f`：SSH 连接在后台运行

执行后，本地 `127.0.0.1:1080` 就是一个 SOCKS5 代理，流量出口为远-程服务器。

### 2. Windows 上配置系统代理

**方式一：Windows 设置（推荐）**

1. 打开"设置" > "网络和 Internet" > "代理"
2. 打开"使用代理服务器"开关
3. 地址填 `127.0.0.1`，端口填 `1080`
4. 保存

**方式二：Internet 选项**

1. `Win + R`，输入 `inetcpl.cpl` 打开 Internet 属性
2. "连接" > "局域网设置"
3. 勾选"为 LAN 使用代理服务器"，点击"高级"
4. 在 Socks 字段中填写 `127.0.0.1`，端口 `1080`

### 3. 验证代理生效

访问 IP 地址查询网站（如 `ip.sb` 或 `whatismyip.com`），如果能显示海外服务器的 IP，说明代理配置成功。

### 4. 注意事项

- SSH 连接稳定性直接影响上网体验，网络不稳时代理可能断开
- 服务器带宽和延迟决定上网速度
- 推荐使用 SSH 密钥认证以提高安全性和自动化程度
- 每次重启或连接断开后，需要重新执行 `ssh -D` 命令

^ssh-proxy-notes

## 五、Root 登录配置

### 1. 安全警告

直接通过 SSH 允许 root 用户登录是**严重的安全风险**：

- root 是所有 Linux 系统都存在的用户名，攻击者会持续暴力破解
- 使用 root 登录后任何命令都有最高权限，误操作（如 `rm -rf`）可能立即永久损坏系统
- **最佳实践**：始终使用普通用户登录，然后 `sudo` 执行管理操作

^root-login-warning

### 2. 如果确需开启 root 登录

**第1步：为 root 设置密码**

```bash
# 先用普通用户登录
ssh ubuntu@your_server_ip
# 设置 root 密码
sudo passwd root
```

**第2步：修改 SSH 配置**

```bash
sudo nano /etc/ssh/sshd_config
```

找到并修改：

```ini
# 修改前（注释掉或禁止密码登录）
#PermitRootLogin prohibit-password
# 修改为
PermitRootLogin yes
```

**第3步：重启 SSH 服务**

```bash
sudo systemctl restart sshd
# 或者
sudo service ssh restart
```

### 3. 恢复到安全状态

```bash
# 编辑 sshd_config，将 PermitRootLogin yes 改回 prohibit-password
sudo nano /etc/ssh/sshd_config
# 重启服务
sudo systemctl restart sshd
# 可选：锁定 root 账户
sudo passwd -l root
```

## 六、SSH 反向隧道

通过反向隧道（Reverse SSH Tunnel），可以让内网服务器主动向外网服务器建立通道，从而从公网访问内网设备。详见 [[旧笔记本改内网服务器#^reverse-tunnel|SSH反向隧道配置]]。

核心命令：

```bash
# 在内网机器上执行，将公网服务器的2222端口映射到内网机器的22端口
ssh -fN -R 2222:localhost:22 user_public@PUBLIC_IP
```

之后在任何地方连接：

```bash
ssh user_private@PUBLIC_IP -p 2222
```

## 七、SSH 连接故障排查

### 1. 常见错误类型

| 错误信息 | 含义 | 解决方法 |
|---------|------|---------|
| `Connection timed out` | 端口不通或无响应 | 检查安全组、防火墙是否开放22端口 |
| `Connection refused` | 端口被拒绝 | 确认 sshd 服务是否运行 |
| `Permission denied` | 身份验证失败 | 检查密码、用户名的正确性 |
| `Permission denied (publickey)` | 密钥认证失败 | 检查公钥是否已添加到服务器 |

### 2. 排查流程

^troubleshoot-flow

1. 确认 sshd 服务在运行：`sudo systemctl status sshd`
2. 确认端口监听：`sudo ss -tlpn | grep 22`
3. 检查服务器防火墙：`sudo ufw status`
4. 检查云服务商安全组
5. 查看 SSH 日志：`sudo journalctl -u sshd -f`
6. 使用 `-v`（verbose）参数调试：`ssh -v user@server_ip`

## 八、相关笔记

- [[VNC远程桌面]] -- VNC 远程桌面环境配置
- [[旧笔记本改内网服务器]] -- 旧笔记本改造 + SSH 反向隧道穿透
- [[计算机网络知识/WiFi篇]] -- WiFi 网络基础知识
- [[宝塔面板部署]] -- 宝塔面板安装（需 SSH 连接服务器）
- [[Docker入门]] -- Docker 安装与 SOCKS5 代理方案
- [[域名配置]] -- 域名绑定与 HTTPS 配置
- [[种子下载与BT]] -- qBittorrent 下载器（通过 SSH 管理服务器）
