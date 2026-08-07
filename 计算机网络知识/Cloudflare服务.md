## 一、Cloudflare 能做什么

Cloudflare 是全球最大的网络基础设施和安全公司之一（AS13335），数据中心遍布全球数百个城市。它在不同层次上提供差异化的服务：

| 角色 | 产品 / 服务 | 目标用户 | 效果 |
|------|------------|----------|------|
| 基础角色 | Cloudflare WARP | 普通个人用户 | 像 VPN 一样将 IP 换成 Cloudflare 的普通 IP，加密保护隐私 |
| 高级角色 | Cloudflare Tunnel + Zero Trust | 开发者 / 小型团队 | 无需公网 IP，安全暴露内网服务，支持身份验证 |
| 平台角色 | Workers / KV / D1 / R2 | 开发者 | 边缘计算，Serverless 跑代码，KV 存储，短链、一次性链接 |
| 企业角色 | BYOIP / Magic Transit | 企业 / 专业人士 | 将自己拥有的 IP 段交给 Cloudflare 做全球 BGP 广播，实现 "物理位置" 和 "注册位置" 分离 |

---

## 二、Cloudflare Tunnel (cloudflared)

Cloudflare Tunnel 让你无需公网 IP、无需在路由器上开端口，就能将内网服务安全地暴露到公网。底层原理是内网设备主动向 Cloudflare 边缘节点建立持久连接。

### 2.1 准备工作

- 域名已在 Cloudflare 托管（NS 已切换）
- 内网服务器上已运行目标服务（可用 `curl -I http://127.0.0.1:PORT` 验证）
- 确认内网服务的端口（以 Cloudreve 监听 5212 为例）

### 2.2 在树莓派 / 内网服务器上安装 cloudflared

**方式 A：apt 安装（优先）：**

```bash
sudo apt update
sudo apt install -y cloudflared
```

**方式 B：手动下载 .deb（适用于树莓派 arm64）：**

```bash
curl -L -o cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
sudo dpkg -i cloudflared.deb
cloudflared --version
```

（32 位系统把 `arm64` 换成 `arm`）

### 2.3 登录并创建 Tunnel

```bash
# 绑定到 Cloudflare 账号
cloudflared tunnel login
```

执行后输出一个 URL，用浏览器打开并选择要授权的域名（如 `zhaoconglei.com`）。

```bash
# 创建 Tunnel
cloudflared tunnel create cloudreve-tunnel
```

成功后会输出 Tunnel UUID，形如 `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`。

### 2.4 配置 ingress 路由

```bash
sudo mkdir -p /etc/cloudflared
sudo nano /etc/cloudflared/config.yml
```

写入配置：

```yaml
tunnel: <你的Tunnel-UUID>
credentials-file: /root/.cloudflared/<你的Tunnel-UUID>.json

ingress:
  - hostname: cloudreve.zhaoconglei.com
    service: http://127.0.0.1:5212

  # 兜底规则（永远放在最后）
  - service: http_status:404
```

^tunnel-config

说明：
- `hostname`：对外域名
- `service`：内网服务的实际监听地址
- `service: http_status:404`：未匹配请求直接 404，避免误转发
- 注意 YAML 缩进严格使用空格

### 2.5 创建 DNS 路由并启动服务

```bash
# 在 Cloudflare DNS 里创建 CNAME 记录，指向 tunnel
cloudflared tunnel route dns cloudreve-tunnel cloudreve.zhaoconglei.com

# 前台测试
cloudflared tunnel run cloudreve-tunnel

# 确认无误后 Ctrl+C 停止，安装为系统服务并开机自启
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared
sudo systemctl status cloudflared --no-pager

# 查看日志排错
journalctl -u cloudflared -f
```

### 2.6 添加新域名到已有 Tunnel

**核心原理：** Tunnel 最初是用某个域名授权的，CLI 会自动把后续绑定的名字当子域名处理。如果要绑定一个**完全不同的新域名**，必须用 "改本地配置 + 网页端手动加 DNS" 的组合。

**步骤一：修改 config.yml**

在 `ingress` 列表中插入新域名（注意新规则必须在 `- service: http_status:404` 之前）：

```yaml
tunnel: <你的Tunnel-UUID>
credentials-file: /home/raspberrypi/.cloudflared/<你的Tunnel-UUID>.json

ingress:
  # 已有的老域名
  - hostname: old-domain.com
    service: http://127.0.0.1:5212

  # === 新增 ===
  - hostname: new-domain.com
    service: http://127.0.0.1:5000

  # 兜底规则
  - service: http_status:404
```

^add-domain-yaml

**步骤二：在 Cloudflare 网页端添加 CNAME 记录**

1. 登录 Cloudflare 网页控制台，进入新域名管理面板
2. 左侧点击 DNS -> Records -> Add record
3. 按以下格式填写：

| 字段 | 值 |
|------|-----|
| Type | `CNAME` |
| Name | `@` 或子前缀如 `www` |
| Target | `<Tunnel-UUID>.cfargotunnel.com` |
| Proxy status | 必须开启（橙色云朵） |

**步骤三：重启 Tunnel 服务**

```bash
sudo systemctl restart cloudflared
```

---

## 三、Cloudflare Zero Trust Access

Zero Trust Access 是在 Cloudflare Tunnel 之上的身份验证层，用于给内网服务加一道 "门禁"。访问者必须先通过身份验证才能到达后端服务。

### 3.1 开通 Zero Trust

1. 登录 Cloudflare Dashboard，左侧点击 **Zero Trust**
2. 首次使用会引导创建 Zero Trust 账户 / 团队名（如 `yourname.cloudflareaccess.com`），选免费计划即可
3. 设置 Team Name（生成专属登录域名）

### 3.2 配置身份验证方式

路径：Zero Trust -> Settings -> Authentication -> Login methods

**默认提供**邮箱一次性验证码（One-Time PIN），已足够安全。也可添加 Google、GitHub 等第三方登录。

### 3.3 创建 Access Application

路径：Zero Trust -> Access -> Applications -> Add an application -> 选 **Self-hosted**

| 配置项 | 值示例 |
|--------|--------|
| Application name | `Cloudreve` |
| Subdomain | `cloudreve` |
| Domain | `zhaoconglei.com` |

### 3.4 设置访问策略

进入应用 -> Policies -> Add a policy：

**方案 A：只允许特定邮箱（个人用推荐）**

| 配置项 | 值 |
|--------|-----|
| Action | `Allow` |
| Include -> Selector | `Emails` |
| Include -> Value | `your-email@gmail.com` |
| Session duration | `12h` 或 `24h` |

**方案 B：允许某个邮箱域（团队用）**

| 配置项 | 值 |
|--------|-----|
| Include -> Selector | `Email Domains` |
| Include -> Value | `@yourcompany.com` |

### 3.5 验证流程

用手机流量（不在家里 Wi-Fi）打开 `https://cloudreve.zhaoconglei.com`：

1. 先出现 Cloudflare Access 验证页
2. 输入允许的邮箱，收验证码
3. 通过后，才能看到 Cloudreve 页面

**安全提示：** Access 是 "门禁"，后端服务自身的登录是在此之上的第二层保护。双层更安全。

### 3.6 附加安全项（可选）

在应用或策略里可加：
- Require MFA
- Block countries（按国家 / 地区限制）
- Device posture（要求 WARP / 设备合规）

---

## 四、Cloudflare Workers + KV：一次性链接

使用 Cloudflare Workers + KV 存储实现 "访问一次就失效" 的一次性分享链接。

### 4.1 整体架构

```
DNS：share.zhaoconglei.com --> Cloudflare（橙云）
Worker：处理 /new 生成 token，处理 /t/<token> 消费并删除
KV：存 token -> 目标 URL，自动 TTL 过期
```

### 4.2 准备子域名

Cloudflare Dashboard -> DNS -> Add record：

| 字段 | 值 |
|------|-----|
| Type | `CNAME` |
| Name | `share` |
| Target | 随意（如 `zhaoconglei.com`） |
| Proxy | Proxied（橙云开启） |

关键是让 `share` 走 Cloudflare 代理，Worker 才能接管流量。

### 4.3 创建 KV 命名空间

Cloudflare Dashboard -> Workers & Pages -> KV -> Create a namespace

命名：`ONE_TIME_LINKS`

### 4.4 创建 Worker 并绑定路由

1. Workers & Pages -> Workers -> Create Worker
2. Settings -> Bindings -> KV Namespace Bindings：
   - Variable name：`TOKENS`
   - KV namespace：选择 `ONE_TIME_LINKS`
3. Settings -> Triggers / Routes -> Add route：`share.zhaoconglei.com/*`

### 4.5 设置 ADMIN_KEY 环境变量

Worker -> Settings -> Variables -> Add Environment Variable：
- Name：`ADMIN_KEY`
- Value：随机长字符串（至少 32 位，如 `Yw9mF3sQk7Vn2Pz6Lr8Tx1Aa5Hd0Jc4B`）

### 4.6 Worker 完整代码（含 UI 管理页面）

```javascript
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // UI 页面：/ui
    if (url.pathname === "/ui") {
      return new Response(`<!doctype html>
<html>
<head><meta charset="utf-8"><title>One-time link</title></head>
<body style="font-family: sans-serif; max-width: 720px; margin: 40px auto;">
  <h2>生成一次性链接</h2>
  <p>目标URL：</p>
  <input id="to" style="width:100%" placeholder="https://example.com" />
  <p>TTL（秒）：</p>
  <input id="ttl" type="number" value="600" min="30" max="86400" />
  <p>ADMIN_KEY（不保存）：</p>
  <input id="k" style="width:100%" placeholder="粘贴你的 ADMIN_KEY" />
  <p><button id="btn">生成</button></p>
  <pre id="out" style="background:#f6f6f6; padding:12px; border-radius:8px;"></pre>

<script>
document.getElementById('btn').onclick = async () => {
  const to = document.getElementById('to').value.trim();
  const ttl = document.getElementById('ttl').value.trim();
  const k = document.getElementById('k').value.trim();
  const out = document.getElementById('out');
  out.textContent = '生成中...';
  const resp = await fetch('/new?to=' + encodeURIComponent(to) + '&ttl=' + encodeURIComponent(ttl), {
    headers: { 'x-admin-key': k }
  });
  out.textContent = await resp.text();
};
</script>
</body></html>`, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    // 创建一次性链接：GET /new?to=<url>&ttl=<seconds>
    if (url.pathname === "/new") {
      const ADMIN_KEY = env.ADMIN_KEY || "";
      const key = request.headers.get("x-admin-key") || url.searchParams.get("k") || "";
      if (!ADMIN_KEY || key !== ADMIN_KEY) return new Response("Unauthorized", { status: 401 });

      const to = url.searchParams.get("to");
      if (!to) return new Response("Missing ?to=", { status: 400 });

      let target;
      try { target = new URL(to); } catch { return new Response("Invalid URL", { status: 400 }); }
      if (!["http:", "https:"].includes(target.protocol)) return new Response("Only http/https allowed", { status: 400 });

      const ttl = Math.min(Math.max(parseInt(url.searchParams.get("ttl") || "600", 10), 30), 86400);
      const token = crypto.randomUUID().replace(/-/g, "");
      await env.TOKENS.put(token, target.toString(), { expirationTtl: ttl });

      return Response.json({ oneTimeLink: `${url.origin}/t/${token}`, ttlSeconds: ttl });
    }

    // 消费一次性链接：GET /t/<token>
    if (url.pathname.startsWith("/t/")) {
      const token = url.pathname.slice(3);
      const target = await env.TOKENS.get(token);
      if (!target) return new Response("Link expired or already used", { status: 404 });
      await env.TOKENS.delete(token);
      return Response.redirect(target, 302);
    }

    return new Response("Try /ui", { status: 200 });
  },
};
```

^kv-worker-code

### 4.7 使用方法

**生成一次性链接（你自己用）：**

```bash
curl -s "https://share.zhaoconglei.com/new?to=https://baidu.com&ttl=600" \
  -H "x-admin-key: Yw9mF3sQk7Vn2Pz6Lr8Tx1Aa5Hd0Jc4B"
```

返回：

```json
{"oneTimeLink":"https://share.zhaoconglei.com/t/xxxx","ttlSeconds":600}
```

把 `oneTimeLink` 发给别人即可。

**别人打开：**
- 第一次：302 跳转到目标 URL
- 第二次：显示 `Link expired or already used`
- 超时 TTL 后自动过期

**也可通过 UI 页面操作：** 访问 `https://share.zhaoconglei.com/ui`

### 4.8 可选增强

| 类型 | 说明 |
|------|------|
| 展示文本而非跳转 | KV value 存正文，访问 `/t/<token>` 返回文本然后 delete |
| 一次性文件下载 | KV 存 R2 的 key，Worker 去 R2 取文件流式返回，然后删 token |
| 防并发双击 | KV 无强事务锁，严格 "一次且仅一次" 需升级到 Durable Objects 或 D1 |

---

## 五、Cloudflare Workers 自建短链

用 Workers 实现自定义短域名，例如 `go.zhaoconglei.com/gh` -> `https://github.com/`。

### 5.1 创建 DNS 记录

Cloudflare Dashboard -> DNS -> Add record：

| 字段 | 值 |
|------|-----|
| Type | `A` |
| Name | `go` |
| IPv4 | `192.0.2.1`（占位 IP，不需要真实可达） |
| Proxy | Proxied（橙云） |

### 5.2 方案 A：写死映射表 Worker

```javascript
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 短链映射表
    const routes = {
      "gh": "https://github.com/",
      "cf": "https://dash.cloudflare.com/",
      "chat": "https://chat.openai.com/",
    };

    const key = url.pathname.replace(/^\/+/, "").trim();

    if (!key) {
      return new Response(
        "Shortlink service is running.\nTry: /gh /cf /chat\n",
        { headers: { "content-type": "text/plain; charset=utf-8" } }
      );
    }

    const target = routes[key];
    if (!target) return new Response("Not found", { status: 404 });

    // 短链一般用 302（可随时改指向），长期固定可用 301
    return Response.redirect(target, 302);
  },
};
```

^shortlink-static

### 5.3 方案 B：KV 版短链（不改代码就能增删）

**创建 KV namespace：** `SHORTLINKS`

**Worker 绑定 KV：** Variable name: `KV`, Namespace: `SHORTLINKS`

```javascript
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const key = url.pathname.replace(/^\/+/, "").trim();

    if (!key) {
      return new Response("KV shortlink is running.\n", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    const target = await env.KV.get(key);
    if (!target) return new Response("Not found", { status: 404 });
    return Response.redirect(target, 302);
  },
};
```

^shortlink-kv

在 Dashboard KV 中写：
- key: `gh` -> value: `https://github.com/`

### 5.4 绑定自定义域名路由

Worker -> Settings -> Triggers -> Routes -> Add route：`go.zhaoconglei.com/*`

### 5.5 测试验证

```bash
# 先用 workers.dev 域名测试（排除域名问题）
curl -I https://<worker-name>.<account-id>.workers.dev/gh

# 再用自定义域名测试
curl -I https://go.zhaoconglei.com/gh
```

期望返回 `HTTP/2 302` 且 `Location: https://github.com/`

### 5.6 故障排查

| 现象 | 可能原因 |
|------|---------|
| workers.dev 能跳，自定义域名不跳 | DNS 里 go 是否 Proxied（橙云）？是否有 Redirect Rules 抢占？ |
| 访问 go 返回 404 | key 不存在，检查大小写敏感 |
| 访问 go 出现 521/522/530 | 没走橙云解析或规则配置异常 |

---

## 六、Cloudflare Magic Transit 与 BYOIP

### 6.1 概念

- **Magic Transit**：企业级网络服务，客户可以将自己合法拥有的 IP 地址段（BYOIP）交由 Cloudflare 管理，Cloudflare 通过其全球网络为客户宣告这些 IP 地址，并提供 DDoS 防护
- **BYOIP（Bring Your Own IP）**：将自己的 IP 地址段 "带到" Cloudflare 平台上，由 Cloudflare 做全球 BGP 广播

### 6.2 应用场景

以获取 "冷门 IP" 为例：

```
1. 通过合法途径获得注册在 "马绍尔群岛" 的 IP 段
2. 使用 Cloudflare BYOIP 服务，授权 Cloudflare 在全球宣告这个 IP 段
3. Cloudflare 通过 AS13335 向全球进行 BGP 宣告
4. 最终效果：
   - 物理性能：流量被路由到最近的 Cloudflare 数据中心（如洛杉矶），速度快
   - 地理位置显示：查询 IP 归属地时，显示的是 RIR 注册的 "马绍尔群岛"
```

### 6.3 WARP：面向个人的简化版

Cloudflare WARP 是面向个人用户的免费（有 WARP+ 付费版）应用程序。开启后所有流量导向 Cloudflare 网络，对外显示的 IP 变为 Cloudflare 节点的 IP。

但 WARP 不能获得特定国家 / 地区的 IP -- Cloudflare 自动将用户连接到最近的或延迟最低的数据中心。

---

## 七、相关笔记

- [[自建代理节点]] -- 搭建代理节点的完整指南
- [[服务器运维/域名配置]] -- Cloudflare 域名托管 DNS 配置
- [[内网穿透]] -- 内网穿透方案对比和 SSH 反向隧道
- [[BGP与IP广播]] -- BGP 广播原理详解
