# Jupyter 环境搭建

## 一、概述

Jupyter Notebook / JupyterLab 是一个交互式计算环境，广泛用于数据科学、机器学习、Python 教学和开发。它支持在浏览器中编写和运行代码，支持 Markdown 文档，是 Python 生态中最核心的工具之一。

> 相关阅读：[[Ollama本地大模型]] 使用 Jupyter 进行模型实验；[[Python开发/Python环境管理]] 关于 conda/venv 环境管理。

---

## 二、方案 A：Miniconda 安装（推荐）

### 2.1 安装 Miniconda

- [Miniconda](https://docs.conda.io/en/latest/miniconda.html)：体积小，推荐
- [Anaconda](https://www.anaconda.com/)：自带大量包，但更大

安装时注意：
- 记得选 "Add to PATH"（如果不确定就先不勾，后面用 Anaconda Prompt）
- 安装目录尽量别带中文、空格（如 `D:\miniconda3`）

### 2.2 创建独立环境

```bash
conda create -n jupyter python=3.10 -y
conda activate jupyter
```

### 2.3 安装 Jupyter

```bash
conda install -c conda-forge notebook jupyterlab -y
```

### 2.4 启动

启动 Notebook（经典界面）：

```bash
jupyter notebook
```

启动 JupyterLab（现代界面，推荐）：

```bash
jupyter lab
```

启动后会自动打开浏览器，如果没有打开，复制终端里那条 `http://localhost:8888/?token=...` 到浏览器。

---

## 三、方案 B：Python + pip 安装

### 3.1 安装 Python

从 [python.org](https://www.python.org/) 安装 Python 3.10/3.11，安装时一定勾选：

- **Add Python to PATH**

### 3.2 创建虚拟环境

在项目目录打开终端：

```bash
python -m venv .venv
```

激活：

```powershell
# PowerShell
.\.venv\Scripts\Activate.ps1

# CMD
.\.venv\Scripts\activate.bat
```

### 3.3 安装 Jupyter

```bash
pip install -U pip
pip install notebook jupyterlab
```

### 3.4 启动

```bash
jupyter lab
# 或
jupyter notebook
```

---

## 四、让 Jupyter 识别你的环境

如果你用 conda/venv 建了环境，有时 Notebook 里选不到对应的 Python。

在该环境里执行：

```bash
pip install ipykernel
python -m ipykernel install --user --name jupyter --display-name "Python (jupyter)"
```

然后重开 Jupyter，在 Kernel / 解释器里就能看到 `Python (jupyter)`。

---

## 五、远程访问配置

### 5.1 生成配置文件

```bash
jupyter lab --generate-config
```

会在 `~/.jupyter/jupyter_lab_config.py` 生成配置。

### 5.2 修改配置

```python
c.ServerApp.ip = '0.0.0.0'          # 监听所有网卡
c.ServerApp.port = 8888              # 设置端口
c.ServerApp.open_browser = False      # 不自动打开浏览器
c.ServerApp.password = 'sha1:xxx'     # 设置密码哈希
```

生成密码哈希：

```python
from jupyter_server.auth import passwd
passwd()
```

### 5.3 通过 SSH 隧道访问

如果不想暴露端口到公网，推荐用 SSH 隧道：

```bash
ssh -L 8888:localhost:8888 user@your_server_ip
```

然后本地浏览器访问 `http://localhost:8888`。

---

## 六、API 配置文件格式

^api-config-format

在使用多种 AI API 服务时，常需要统一管理 API Key 和模型配置。以下是典型的 API 配置文件格式：

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
  - name: gemini-3-pro-preview
    provider: openrouter
    model: google/gemini-3-pro-preview
    apiBase: https://openrouter.ai/api/v1
    apiKey: sk-or-v1-xxxxxxxx
    capabilities:
      - tool_use
  - name: claude-opus-4.5
    provider: openrouter
    model: anthropic/claude-opus-4.5
    apiBase: https://openrouter.ai/api/v1
    apiKey: sk-or-v1-xxxxxxxx
    capabilities:
      - tool_use
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

### 6.1 字段说明

| 字段 | 说明 |
|------|------|
| `name` | 配置名称 |
| `version` | 配置版本 |
| `models` | 模型列表 |
| `models[].name` | 显示名称 |
| `models[].provider` | 提供商标识（openrouter / deepseek / openai 等） |
| `models[].model` | 实际模型 ID |
| `models[].apiBase` | API 端点地址（OpenRouter 不需要额外配置） |
| `models[].apiKey` | API 密钥 |
| `models[].capabilities` | 功能列表（如 tool_use） |

### 6.2 常见 Provider

| Provider | API Base | 说明 |
|----------|----------|------|
| openrouter | `https://openrouter.ai/api/v1` | 聚合多家 API |
| deepseek | `https://api.deepseek.com` | DeepSeek 官方 |
| openai | `https://api.openai.com/v1` | OpenAI 官方 |

---

## 七、常见问题排查

### 7.1 命令找不到：`jupyter` 不是内部命令

- 没有激活环境（`conda activate` / venv activate）
- 或 PATH 没配好
- 解决：先激活环境，再运行 `jupyter lab`

### 7.2 浏览器打不开 / token 进不去

终端会有类似：

```
http://localhost:8888/?token=xxxxx
```

复制这条到浏览器即可。

### 7.3 端口被占用（8888 用不了）

Jupyter 会自动换端口（8889/8890），看终端输出即可。

### 7.4 安装依赖慢

可以换清华镜像源：

```bash
pip install -i https://pypi.tuna.tsinghua.edu.cn/simple notebook jupyterlab
```
