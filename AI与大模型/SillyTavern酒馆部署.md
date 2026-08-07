# SillyTavern 酒馆部署

## 一、概述

SillyTavern（酒馆）是一个自托管的 AI 角色扮演前端，支持连接多种大模型后端（OpenRouter、DeepSeek、Ollama 本地模型等），提供角色卡（Character Card）、世界书（World Book）、正则脚本等丰富的角色扮演功能。

> 相关阅读：[[Ollama本地大模型]] 可配合酒馆使用本地大模型；[[计算机网络知识/自建代理节点]] 解决 API 网络连通问题。

---

## 二、Linux 服务器安装

### 2.1 准备工作

在 Linux 服务器（VPS）上通过 SSH 登录后执行以下步骤。

首先安装 Git：

```bash
sudo apt update && sudo apt install -y git
```

### 2.2 下载 SillyTavern-Launcher

使用官方提供的 Launcher 脚本来管理安装：

```bash
git clone https://github.com/SillyTavern/SillyTavern-Launcher.git
cd SillyTavern-Launcher
```

### 2.3 运行安装脚本

```bash
chmod +x install.sh && ./install.sh
```

安装过程中会提示选择要安装的组件，按需选择即可。

### 2.4 启动酒馆

安装完成后，通过 Launcher 启动：

```bash
chmod +x launcher.sh && ./launcher.sh
```

启动后默认监听 `http://localhost:8000`，如需从外部访问，可通过 Nginx 反向代理或直接修改监听地址。

### 2.5 开放端口（如使用云防火墙）

确保服务器防火墙放行 8000 端口：

```bash
sudo ufw allow 8000/tcp
```

如使用云服务商的安全组，也需要在控制台添加对应规则。

---

## 三、连接 AI API

### 3.1 OpenRouter（推荐方式）

OpenRouter 是一个 API 聚合平台，一个 API Key 可用多个模型。

**配置格式**（参考 [[Jupyter环境搭建#^api-config-format|API 配置文件格式]]）：

```yaml
name: My Config
version: 0.0.1
schema: v1
models:
  - name: deepseek-v3.2
    provider: openrouter
    model: deepseek/deepseek-v3.2
    apiBase: https://openrouter.ai/api/v1
    apiKey: sk-or-v1-xxxxxxxx
  - name: claude-opus-4.5
    provider: openrouter
    model: anthropic/claude-opus-4.5
    apiBase: https://openrouter.ai/api/v1
    apiKey: sk-or-v1-xxxxxxxx
    capabilities:
      - tool_use
```

^api-config-format

### 3.2 DeepSeek 官方 API

DeepSeek 提供高性价比的中文模型：

```yaml
models:
  - name: DeepSeek Coder
    provider: deepseek
    model: deepseek-coder
    apiKey: sk-xxxxxxxx
    capabilities:
      - tool_use
  - name: DeepSeek Reasoner
    provider: deepseek
    model: deepseek-reasoner
    apiKey: sk-xxxxxxxx
    capabilities:
      - tool_use
```

DeepSeek 官方 API 地址为 `https://api.deepseek.com`，在酒馆中配置 Text Completion 或 Chat Completion 时填入即可。

### 3.3 在酒馆中配置

1. 打开酒馆 Web 界面
2. 进入顶部菜单栏，点击 API 连接设置（插头图标）
3. 选择 API 类型（Chat Completion / Text Completion）
4. 填入 API Base URL 和 API Key
5. 选择想要使用的模型名称
6. 点击 "Connect" 测试连接

---

## 四、预设（Preset）配置

预设决定了模型的生成行为参数，包括 temperature、top_p、top_k、repetition_penalty 等。

### 4.1 常用预设参数

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| Temperature | 0.7 - 1.0 | 越高越有创意，越低越确定 |
| Top P | 0.9 - 1.0 | 核采样概率 |
| Top K | 40 - 100 | 限制候选 token 数量 |
| Repetition Penalty | 1.05 - 1.15 | 避免重复 |
| Max Response Length | 300 - 600 | 单次回复最大 token 数 |
| Context Size | 4096 - 32768 | 上下文窗口大小 |

### 4.2 导入预设

在酒馆的 Presets 面板中，可以：
- 从社区导入现成的预设 JSON
- 手动调整参数后保存为自定义预设
- 为不同模型分别配置不同预设

---

## 五、正则脚本（Regex Scripts）

### 5.1 用途

正则脚本用于在消息发送前/后自动修改文本，常用于：

- 格式化输出（去掉多余换行、修正标点）
- 添加/移除角色名
- 动态注入提示词
- 过滤敏感内容

### 5.2 配置位置

酒馆设置 → Extensions → Regex

### 5.3 常见脚本示例

**去掉发言者前缀**：

```
Find: /^【[^】]+】/gm
Replace: (空)
```

**统一角色称呼**：

```
Find: /\b(你|您)\b/g
Replace: 主人
```

脚本支持 JavaScript 正则语法，可设置作用范围（用户输入/AI 输出/全部）。

---

## 六、世界书（World Book）概述

### 6.1 概念

世界书是 SillyTavern 的核心高级功能之一，相当于一个动态的"知识库"或"背景设定集"。它包含多条条目（Entry），每个条目由：

- **Key（触发词）**：当 AI 对话中出现这些词时自动触发
- **Content（内容）**：注入到上下文中的补充信息
- **可选设置**：优先级、仅当角色在场、递归触发等

### 6.2 使用场景

- 为特定场景提供详细的背景设定
- 定义角色的关系网和社会背景
- 管理长篇故事中的剧情线
- 添加特定世界观的规则和设定

### 6.3 基本操作

1. 点击工具栏的"书本"图标进入世界书管理
2. 创建新的条目（Entry），填写 Key 和 Content
3. 设置触发条件（始终激活 / 关键词触发）
4. 关联到特定角色卡

---

## 七、常见问题

### 7.1 API 连接失败

- 检查服务器能否访问外网：`curl -I https://api.openai.com`
- 确认 API Key 未过期且有余额
- 如在大陆服务器，可能需要通过 [[计算机网络知识/自建代理节点|代理节点]] 连接

### 7.2 端口无法访问

- `netstat -tlnp | grep 8000` 确认服务是否监听
- 检查服务器防火墙和云安全组规则

### 7.3 内存不足

酒馆本身不是大模型，不消耗 GPU，但较大的角色卡和世界书会占用内存。建议 VPS 至少 1GB 内存。
