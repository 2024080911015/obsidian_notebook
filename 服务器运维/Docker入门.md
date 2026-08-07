# Docker入门

## 一、Docker 概述

Docker 是一个容器化平台，通过将应用及其依赖打包到轻量级容器中，实现"一次构建，到处运行"。常用于服务器环境的快速部署。

### docker-compose (v1) 与 docker compose (v2)

在学习和使用 Docker 前，必须区分这两个命令： ^compose-v1-v2

- **`docker-compose` (v1)**：独立的 Python 脚本，已自 2023 年 7 月起停止维护，不再接收安全更新。
- **`docker compose` (v2)**：Docker CLI 的内置插件（Go 语言编写），是当前的推荐版本。

以下全部使用 `docker compose`（无连字符）。

## 二、Docker 安装

### Ubuntu/Debian 系统（官方推荐方式）

#### 1. 卸载旧版本

```bash
sudo apt-get remove docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc
```

#### 2. 设置 Docker 官方 APT 仓库

```bash
# 更新包索引并安装依赖
sudo apt-get update
sudo apt-get install -y ca-certificates curl

# 添加 Docker 官方 GPG 密钥
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 添加 Docker 仓库到 APT 源列表
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$UBUNTU_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

#### 3. 安装 Docker 引擎及 Compose 插件

```bash
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

#### 4. 配置用户权限

```bash
sudo usermod -aG docker ${USER}
# 执行后需注销重新登录，或执行 newgrp docker
```

#### 5. 验证安装

```bash
docker --version
docker compose version
sudo docker run hello-world
```

如果 `hello-world` 容器成功运行，安装完成。

^docker-install-ubuntu

### Alinux/CentOS/RHEL 系统

```bash
# 安装 dnf 插件
sudo dnf -y install dnf-plugins-core
# 添加 Docker 官方仓库
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
# 安装 Docker
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# 启动并开机自启
sudo systemctl enable --now docker
```

### 旧方法 vs 新方法

| 任务 | 过时命令 | 推荐命令 (Debian/Ubuntu) | 推荐命令 (RHEL/CentOS) |
|------|---------|-------------------------|----------------------|
| 安装 Docker | `apt-get install docker.io` | `apt-get install docker-ce` | `dnf install docker-ce` |
| 安装 Compose | `apt-get install docker-compose` | `apt-get install docker-compose-plugin` | `dnf install docker-compose-plugin` |
| 运行 Compose | `docker-compose up -d` | `docker compose up -d` | `docker compose up -d` |

## 三、Cloudflare WARP SOCKS5 代理方案

本方案通过 Docker 容器化 Cloudflare WARP，实现特定地理区域的 SOCKS5 代理（以澳门为例）。

### 核心原理

Cloudflare WARP 的底层技术基于 **WireGuard** 协议。WireGuard 配置中的 `Endpoint` 指令指定了客户端与哪个服务器建立加密隧道，该服务器的地理位置决定了流量的最终出口地理位置。

**核心策略**：通过锁定并配置一个位于目标区域的 Cloudflare WireGuard 端点 IP，精确控制出口地理位置。^warp-endpoint-lock

### 实施步骤

#### 步骤 1：识别目标区域端点 IP

使用社区扫描工具寻找目标区域的 WARP 端点：

```bash
# 下载扫描脚本
wget -N https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-yxip/warp-yxip.sh

# 赋予执行权限
chmod +x warp-yxip.sh

# 运行扫描（可能需要几分钟）
./warp-yxip.sh
```

扫描完成后，查看结果：

```bash
cat result.csv
```

找到 `Location` 列为目标地区（如 `MAC` / `Macau`）的条目，记录 `Endpoint` 列的 IP 地址和端口（如 `104.28.224.109:2408`）。

> 如果没有找到目标 IP，可稍后重试，因为 Cloudflare 的网络是动态变化的。

#### 步骤 2：准备项目目录

```bash
mkdir -p ~/warp-macau/config
cd ~/warp-macau
```

#### 步骤 3：编写 docker-compose.yml

```bash
nano docker-compose.yml
```

```yaml
version: '3.8'

services:
  warproxy:
    image: ghcr.io/kingcc/warproxy:latest
    container_name: warp-macau-proxy
    restart: always
    ports:
      # 将容器1080端口映射到宿主机127.0.0.1:1080
      # 绑定到127.0.0.1只允许本机访问，增强安全性
      - "127.0.0.1:1080:1080"
    volumes:
      # 配置文件持久化，这是实现自定义端点的关键
      - ./config:/config
    cap_add:
      # NET_ADMIN 权限是 WireGuard 创建网络接口所必需的
      - NET_ADMIN
    environment:
      - TZ=Asia/Macau
      # 如需设置代理认证，取消下面的注释
      # - USERNAME=your_user
      # - PASSWORD=your_password
```

#### 步骤 4：首次启动并生成配置文件

```bash
docker compose up -d
```

等待约 30 秒后，检查配置文件是否生成：

```bash
ls -l ./config
# 应看到 wgcf-account.toml 和 wgcf-profile.conf
```

#### 步骤 5：修改 WireGuard 配置（植入目标端点）

```bash
# 先停止容器
docker compose down

# 编辑配置文件
nano ./config/wgcf-profile.conf
```

找到 `Endpoint =` 开头的行，将后面的 IP 地址和端口替换为步骤 1 中找到的目标端点：

```ini
Endpoint = 104.28.224.109:2408
```

#### 步骤 6：重启并验证

```bash
# 重新启动
docker compose up -d

# 等待初始化
sleep 15

# 验证代理出口
curl --proxy socks5h://127.0.0.1:1080 https://ipinfo.io
```

成功的返回应显示目标地区信息：

```json
{
  "ip": "104.28.XXX.XXX",
  "city": "Macau",
  "region": "Macau",
  "country": "MO",
  "org": "AS13335 Cloudflare, Inc.",
  "timezone": "Asia/Macau"
}
```

确认 `country` 为 `MO` 且 `city` 为 `Macau`，即表示成功。

^warp-setup-complete

### kingcc/warproxy 环境变量

| 环境变量 | 描述 | 默认值 |
|---------|------|--------|
| `SOCKS5_PORT` | SOCKS5 代理监听端口 | 1080 |
| `HTTP_PORT` | HTTP 代理监听端口 | None |
| `USERNAME` | SOCKS5/HTTP 认证用户名 | None |
| `PASSWORD` | SOCKS5/HTTP 认证密码 | None |
| `TZ` | 容器时区 | Asia/Shanghai |
| `WARP_PLUS` | 是否启用 WARP+ 流量刷新 | true |
| `VERBOSE` | 是否显示详细日志 | false |

## 四、客户端配置（使用代理）

### 浏览器配置

推荐使用插件而非系统全局代理：

- **Chrome/Edge**：安装 Proxy SwitchyOmega
- **Firefox**：安装 FoxyProxy Standard

配置：
- 协议：SOCKS5
- 服务器：127.0.0.1
- 端口：1080

### 命令行工具

```bash
# curl
curl --proxy socks5h://127.0.0.1:1080 <URL>

# git
git config --global http.proxy 'socks5://127.0.0.1:1080'

# 环境变量
export ALL_PROXY=socks5h://127.0.0.1:1080
export HTTP_PROXY=$ALL_PROXY
export HTTPS_PROXY=$ALL_PROXY
```

## 五、服务生命周期管理

```bash
# 启动（后台模式）
docker compose up -d

# 停止（不删除容器）
docker compose stop

# 重新启动
docker compose restart

# 查看实时日志
docker compose logs -f

# 停止并移除容器、网络（保留配置文件）
docker compose down
```

### 彻底清理

```bash
docker compose down
cd ..
rm -rf ~/warp-macau
```

## 六、故障排查与维护

### 端点失效修复流程

当代理无法连接或出口 IP 不是目标区域时，原因是端点 IP 被 Cloudflare 调整。

**修复流程（SOP）：**

```bash
cd ~/warp-macau
docker compose down                    # 停止旧容器
./warp-yxip.sh                         # 重新扫描
cat result.csv                         # 找到新的目标 IP
nano ./config/wgcf-profile.conf        # 更新 Endpoint
docker compose up -d                   # 重启服务
sleep 15
curl --proxy socks5h://127.0.0.1:1080 https://ipinfo.io   # 验证
```

### 注意事项

- 本方案依赖的非官方端点 IP 可能随时变化，不是一劳永逸的方案
- 端点 IP 的地理位置、可用性可能被 Cloudflare 随时调整
- 建议定期记录端点维护流程

## 七、相关笔记

- [[SSH配置与远程连接]] -- SSH 连接是操作 Docker 服务器的基础
- [[宝塔面板部署]] -- 宝塔面板是 Docker 的替代管理工具
- [[VNC远程桌面]] -- 服务器图形化管理方式
- [[旧笔记本改内网服务器]] -- 内网服务器也可运行 Docker
- [[种子下载与BT]] -- qBittorrent 可用 Docker 部署
