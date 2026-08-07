# Ollama 本地大模型

## 一、概述

Ollama 是一个本地大模型运行框架，支持在个人电脑上运行 LLaMA、Qwen、Mistral 等开源大模型。它提供命令行交互和 HTTP API 两种使用方式，是搭建本地 AI 服务的首选工具。

> 相关阅读：[[SillyTavern酒馆部署]] 可用 Ollama 作为本地模型后端；[[ComfyUI搭建与使用]] 可结合文本生成。

---

## 二、端口与运行状态

### 2.1 默认端口

Ollama 默认监听：`127.0.0.1:11434`（本机回环）

即：`http://localhost:11434`

这不是每次 `ollama run` 都会在终端里提示，但服务一般是常驻的（Windows 下通常作为后台服务/进程运行）。

### 2.2 查看 Ollama 是否在运行

**方法 A：使用 Ollama 自带命令**

```powershell
ollama list
```

如果能正常列出模型，说明后台服务是通的。

**方法 B：用 curl 直接探测端口**

```powershell
curl http://localhost:11434/api/tags
```

如果返回一段 JSON（列出已下载模型信息），那就确定是 11434。

Windows PowerShell 中 curl 可能是别名，用：

```powershell
Invoke-RestMethod http://localhost:11434/api/tags
```

**方法 C：查系统端口占用**

```powershell
netstat -ano | findstr 11434
```

你会看到类似：

```
TCP    127.0.0.1:11434    ...    LISTENING    <PID>
```

然后把 PID 对应到进程：

```powershell
tasklist | findstr <PID>
```

一般会看到是 `ollama.exe` 或相关服务进程。

### 2.3 修改端口

Ollama 通过环境变量 `OLLAMA_HOST` 控制监听地址/端口。

例如改成 11500：

```powershell
[Environment]::SetEnvironmentVariable("OLLAMA_HOST","127.0.0.1:11500","User")
```

然后重启 Ollama 服务/重开终端再测：

```powershell
Invoke-RestMethod http://localhost:11500/api/tags
```

> **注意**：改端口后，任何调用 Ollama 的工具（如 openclaw、webui、SillyTavern）也要跟着改 URL。

### 2.4 确认端口的最短路径

````powershell
Invoke-RestMethod http://localhost:11434/api/tags
````

- 能返回 JSON：就是 11434 没问题
- 报错连接失败：说明服务没起来/端口被改/被防火墙拦了（但 localhost 一般不会）

---

## 三、模型下载与运行

### 3.1 下载模型

```bash
ollama pull qwen2.5:7b          # 7B 参数模型
ollama pull llama3.1:8b         # LLaMA 3.1
ollama pull deepseek-r1:7b      # DeepSeek R1
```

### 3.2 命令行交互

```bash
ollama run qwen2.5:7b
```

进入交互模式后直接输入问题即可。

### 3.3 通过 API 调用

Ollama 提供兼容 OpenAI 格式的 API：

```python
import requests

response = requests.post(
    "http://localhost:11434/api/generate",
    json={
        "model": "qwen2.5:7b",
        "prompt": "你好，请介绍一下自己",
        "stream": False
    }
)
print(response.json()["response"])
```

---

## 四、大模型微调示例（QLoRA SFT）

以下是一个完整的 QLoRA SFT（监督微调）流程，使用 Google Colab 进行训练。

### 4.1 Colab Notebook 整体结构

1. 挂载 Google Drive
2. 创建工程目录：`data/`、`scripts/`、`outputs/`
3. 安装依赖（transformers, datasets, peft, trl, bitsandbytes 等）
4. 检查 GPU
5. 将训练脚本写入 Drive
6. 运行训练

### 4.2 Cell 0：挂载 Google Drive

```python
from google.colab import drive
drive.mount('/content/drive')
```

### 4.3 Cell 1：创建工程目录

```python
from pathlib import Path

PROJ = Path("/content/drive/MyDrive/llm_ft")
(PROJ / "data").mkdir(parents=True, exist_ok=True)
(PROJ / "scripts").mkdir(parents=True, exist_ok=True)
(PROJ / "outputs").mkdir(parents=True, exist_ok=True)

print("Project root:", PROJ)
```

语法要点：
- `Path` 的 `/` 是拼路径运算符，不是除法
- `mkdir(parents=True)` 等价于 `mkdir -p`
- `exist_ok=True` 表示目录已存在也不报错

### 4.4 Cell 2：安装依赖

```python
!pip -q install -U "transformers>=4.41.0" "datasets>=2.19.0" "accelerate>=0.30.0" "peft>=0.11.0" "trl>=0.9.6" bitsandbytes sentencepiece
```

- `!` 在 Jupyter/Colab 里表示用系统命令执行
- `-q`：quiet，少输出
- `-U`：upgrade
- `>=4.41.0`：版本约束

### 4.5 Cell 3：检查 GPU

```python
import torch
print("CUDA:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
    print("VRAM(GB):", round(torch.cuda.get_device_properties(0).total_memory/1024**3, 2))
```

### 4.6 Cell 4：训练脚本核心代码

```python
from pathlib import Path

PROJ = Path("/content/drive/MyDrive/llm_ft")
script_path = PROJ / "scripts" / "train_qlora_sft.py"

script_path.write_text(r'''
import os
import argparse
import torch
from datasets import load_dataset
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from trl import SFTTrainer, SFTConfig

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--model_name_or_path", type=str, required=True)
    p.add_argument("--train_file", type=str, required=True)
    p.add_argument("--output_dir", type=str, required=True)
    p.add_argument("--max_seq_length", type=int, default=2048)
    p.add_argument("--per_device_train_batch_size", type=int, default=1)
    p.add_argument("--gradient_accumulation_steps", type=int, default=8)
    p.add_argument("--num_train_epochs", type=int, default=1)
    p.add_argument("--learning_rate", type=float, default=2e-4)
    p.add_argument("--lora_r", type=int, default=16)
    p.add_argument("--lora_alpha", type=int, default=32)
    p.add_argument("--lora_dropout", type=float, default=0.05)
    p.add_argument("--warmup_ratio", type=float, default=0.05)
    p.add_argument("--logging_steps", type=int, default=10)
    p.add_argument("--save_steps", type=int, default=200)
    p.add_argument("--seed", type=int, default=42)
    return p.parse_args()

def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    # GPU 检查
    if not torch.cuda.is_available():
        raise RuntimeError("需要 GPU 才建议跑 QLoRA（Colab 里：运行时→更改运行时类型→GPU）")

    # 4bit 量化配置
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
        bnb_4bit_use_double_quant=True,
    )

    # tokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.model_name_or_path, use_fast=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"

    # 模型加载
    model = AutoModelForCausalLM.from_pretrained(
        args.model_name_or_path,
        device_map="auto",
        quantization_config=bnb_config,
        torch_dtype=torch.bfloat16,
    )
    model.config.use_cache = False
    model = prepare_model_for_kbit_training(model)

    # LoRA 配置
    target_modules = ["q_proj","k_proj","v_proj","o_proj","gate_proj","up_proj","down_proj"]
    lora_config = LoraConfig(
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=target_modules,
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # 读取数据并格式化
    ds = load_dataset("json", data_files={"train": args.train_file})["train"]

    def format_example(example):
        msgs = example["messages"]
        text = tokenizer.apply_chat_template(msgs, tokenize=False, add_generation_prompt=False)
        return {"text": text}

    ds = ds.map(format_example, remove_columns=ds.column_names)

    # 训练配置
    sft_config = SFTConfig(
        output_dir=args.output_dir,
        max_length=args.max_seq_length,
        num_train_epochs=args.num_train_epochs,
        per_device_train_batch_size=args.per_device_train_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        warmup_ratio=args.warmup_ratio,
        logging_steps=args.logging_steps,
        save_steps=args.save_steps,
        save_total_limit=2,
        bf16=True,
        optim="paged_adamw_8bit",
        lr_scheduler_type="cosine",
        report_to="none",
        seed=args.seed,
        dataset_text_field="text",
    )

    # 训练
    trainer = SFTTrainer(
        model=model,
        train_dataset=ds,
        args=sft_config,
    )
    trainer.train()
    trainer.model.save_pretrained(args.output_dir)
    tokenizer.save_pretrained(args.output_dir)
    print(f"LoRA adapter saved to: {args.output_dir}")

if __name__ == "__main__":
    main()
''', encoding="utf-8")

print("Wrote:", script_path)
```

### 4.7 Cell 5：运行训练

```python
from pathlib import Path
PROJ = Path("/content/drive/MyDrive/llm_ft")

MODEL = "Qwen/Qwen2.5-7B-Instruct"
TRAIN = str(PROJ / "data" / "train.jsonl")
OUT   = str(PROJ / "outputs" / "qlora_sft")

!python {PROJ / "scripts" / "train_qlora_sft.py"} \
  --model_name_or_path "{MODEL}" \
  --train_file "{TRAIN}" \
  --output_dir "{OUT}" \
  --max_seq_length 1024 \
  --per_device_train_batch_size 1 \
  --gradient_accumulation_steps 8 \
  --num_train_epochs 1 \
  --learning_rate 2e-4
```

### 4.8 关键语法点

| 语法 | 说明 |
|------|------|
| `from X import Y` | 从模块导入类/函数 |
| `def func():` | 定义函数，缩进是语法 |
| `if __name__ == "__main__":` | 脚本入口控制，避免 import 时自动执行 |
| `f"...{var}..."` | f-string，允许在字符串里用 `{}` 插入变量值 |
| `None` | Python 的空值 |
| `Path / "subdir"` | 拼路径，不是除法 |
| `r'''...'''` | 原始多行字符串 |
| `!pip install` | Notebook 特有语法，跑 shell 命令 |

### 4.9 数据格式（train.jsonl）

训练数据使用 JSONL 格式，每行一个 JSON 对象，包含 `messages` 字段：

```json
{"messages": [{"role": "system", "content": "你是一个有用的助手"}, {"role": "user", "content": "你好"}, {"role": "assistant", "content": "你好！有什么可以帮助你的？"}]}
```

---

## 五、API 使用

### 5.1 基础 API 端点

| 端点 | 方法 | 用途 |
|------|------|------|
| `/api/tags` | GET | 列出已下载的模型 |
| `/api/generate` | POST | 文本生成 |
| `/api/chat` | POST | 对话（Chat 格式） |

### 5.2 Python 调用示例

```python
import requests
import json

# 对话格式
response = requests.post(
    "http://localhost:11434/api/chat",
    json={
        "model": "qwen2.5:7b",
        "messages": [
            {"role": "user", "content": "用 Python 写一个快速排序"}
        ],
        "stream": False
    }
)
print(response.json()["message"]["content"])

# 流式输出
response = requests.post(
    "http://localhost:11434/api/generate",
    json={
        "model": "qwen2.5:7b",
        "prompt": "讲一个笑话",
        "stream": True
    },
    stream=True
)
for line in response.iter_lines():
    if line:
        data = json.loads(line)
        print(data["response"], end="", flush=True)
```
