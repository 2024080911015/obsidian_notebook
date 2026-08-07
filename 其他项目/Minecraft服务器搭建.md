# Minecraft 服务器搭建

## 一、基岩版服务器（BDS）搭建

^bedrock-server

Minecraft 基岩版（手机、平板、Xbox、Windows 10/11 商店版）与 Java 版在底层架构和网络协议上完全不同：

| 特性 | Java 版 | 基岩版 |
|------|---------|--------|
| 协议 | TCP | UDP |
| 默认端口 | 25565 | 19132 |
| Docker 镜像 | itzg/minecraft-server | itzg/minecraft-bedrock-server |

### Docker Compose 搭建基岩版

```bash
# 准备目录
mkdir -p ~/bds-server/data
cd ~/bds-server
```

**docker-compose.yml：**

```yaml
services:
  bds:
    image: itzg/minecraft-bedrock-server
    container_name: mc-bedrock-server
    environment:
      EULA: "TRUE"
      GAMEMODE: "survival"
      DIFFICULTY: "normal"
      SERVER_NAME: "My Bedrock Server"
    ports:
      - "19132:19132/udp"  # 极其重要：必须是 UDP 协议！
    volumes:
      - ./data:/data
    restart: unless-stopped
```

启动：

```bash
docker compose up -d
```

### 网络配置注意事项

在云服务商（如 AWS）安全组中，放行 **UDP 协议**的 19132 端口（可同时放行 TCP 和 UDP）。

## 二、Java 版与基岩版互通（Geyser）

^geyser

如果已有 Java 版 Paper 服务器，不需要重新搭建基岩版服务器，只需安装 **Geyser** 插件即可实现协议转换，让手机/电脑跨平台同服游玩。

### 安装 Geyser 和 Floodgate

```bash
cd ~/mc-server/data/plugins

# 下载 Geyser-Spigot 插件
wget https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot -O Geyser-Spigot.jar

# 下载 Floodgate 插件（允许基岩版玩家不需要 Java 正版账号登录）
wget https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot -O floodgate-spigot.jar
```

### 修改 docker-compose.yml 暴露基岩版端口

```yaml
    ports:
      - "25565:25565"     # Java 版端口 (TCP)
      - "19132:19132/udp" # 基岩版端口 (UDP) 供 Geyser 使用
```

重启容器：

```bash
cd ~/mc-server
docker compose up -d --force-recreate
```

连接方式：
- Java 版玩家：`你的IP:25565`
- 基岩版玩家：`你的IP:19132`

## 三、基岩版管理员配置

^bedrock-admin

### 常见问题

配置 OP 时的典型问题：
- 没开 `allow-cheats`
- OPS 写的是玩家名但镜像实际要 XUID
- 权限文件没生效
- 改了配置但没重启容器

### 完整流程

**步骤一：开启允许作弊**

```bash
cd ~/bds-server/data
nano server.properties
```

确保以下配置：

```ini
allow-cheats=true
online-mode=true
default-player-permission-level=member
```

重启：

```bash
cd ~/bds-server
docker compose restart
```

退出游戏，重新进入服务器。

**步骤二：获取 XUID**

`itzg/minecraft-bedrock-server` 的 `OPS` 环境变量是 **XUID 列表**，不是普通玩家名。

查看日志获取 XUID：

```bash
docker logs mc-bedrock-server | grep -i xuid
```

或者实时查看：

```bash
docker logs -f mc-bedrock-server
```

进入服务器后，日志中会出现类似：

```
Player connected: 你的名字, xuid: 25354xxxxxxxx
```

把这串数字复制下来。

**步骤三：修改 permissions.json**

```bash
cd ~/bds-server/data
nano permissions.json
```

内容格式：

```json
[
  {
    "permission": "operator",
    "xuid": "你的XUID数字"
  }
]
```

注意点：
- `xuid` 必须加英文双引号
- `permission` 必须是 `"operator"`
- 不要写 `ops.json`
- 不要多一个逗号
- 不要用中文引号

保存后重启并重新进入游戏。

**步骤四：测试管理员命令**

进服后在聊天框输入：

```
/gamemode creative @s
/give @s diamond 1
```

能执行就说明 OP 成功。

### 直接在 compose 中配置 OPS

也可以直接在 `docker-compose.yml` 中配置：

```yaml
services:
  bds:
    image: itzg/minecraft-bedrock-server
    container_name: mc-bedrock-server
    environment:
      EULA: "TRUE"
      SERVER_NAME: "My Bedrock Server"
      GAMEMODE: "survival"
      DIFFICULTY: "normal"
      ALLOW_CHEATS: "true"
      ONLINE_MODE: "true"
      OPS: "你的XUID数字"
    ports:
      - "19132:19132/udp"
    volumes:
      - ./data:/data
    restart: unless-stopped
```

然后重建容器：

```bash
docker compose down
docker compose up -d
```

## 四、服务器常用管理命令

```bash
# 查看容器运行状态
docker ps

# 查看服务器日志
docker logs -f mc-bedrock-server

# 重启服务器
docker compose restart

# 停止服务器
docker compose down

# 进入容器终端
docker exec -it mc-bedrock-server /bin/bash
```

## 五、相关笔记

- [[../服务器运维/SSH配置与远程连接|SSH配置与远程连接]]
- [[../嵌入式与硬件/树莓派入门|树莓派入门]]（树莓派可运行轻量Minecraft服务端）
