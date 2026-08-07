# ComfyUI 搭建与使用

## 一、概述

ComfyUI 是一个基于节点的 Stable Diffusion 图像生成工作流工具。相比 WebUI（Automatic1111），ComfyUI 使用节点（Node）连线的方式来组织生图流程，更加灵活和可视化。它支持本地 GPU 推理、云端 API 调用、图生图等高级功能。

> 相关阅读：[[Ollama本地大模型]] 可与 ComfyUI 结合使用文本生成；[[Jupyter环境搭建]] 用于数据分析与模型训练。

---

## 二、搭建步骤（Windows + Conda）

### 2.1 方案一：CPU / API 版（不使用本地 GPU）

这套方案解决"不使用 ComfyUI 官方的 API Nodes（那些会要求 Login，甚至走 ComfyUI 自己的 credits）"的问题，用自己的 API Key 直连 Stability API。

**0. 前置条件**

- Windows 10/11
- 已安装 Anaconda / Miniconda
- 有 Stability 的 API Key，且账号有可用 credits
- 网络可访问 `api.stability.ai`
- **强烈建议**：资源管理器开启"文件扩展名显示"，避免把 `__init__.py` 误建成 `__init__.py.txt`

**1. 创建 Conda 环境**

```powershell
conda create -n comfyui python=3.10 -y
conda activate comfyui
```

**2. 安装 ComfyUI**

```powershell
cd /d E:\image_process
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
pip install -r requirements.txt
```

如果只用云端 API，不跑本地模型，CPU 版 Torch 即可。若遇到 torch 缺失，可补装 CPU 版：

```powershell
pip install torch --index-url https://download.pytorch.org/whl/cpu
```

**3. 设置 Stability API Key**

永久写入环境变量（需要新开终端才能生效）：

```powershell
setx STABILITY_API_KEY "你的key粘贴在这里"
```

验证：

```powershell
cmd /c echo %STABILITY_API_KEY%
```

**4. 放入自定义节点**

目录结构：

```
ComfyUI
└─ custom_nodes
   └─ my_stability_api
      ├─ __init__.py
      └─ nodes.py
```

`__init__.py` 内容：

```python
from .nodes import NODE_CLASS_MAPPINGS, NODE_DISPLAY_NAME_MAPPINGS
```

`nodes.py` 完整内容（核心是文生图 txt2img 和图生图 img2img 两个节点）：

```python
import os
import io
import base64
import requests
import numpy as np
import torch
from PIL import Image

API_URL_SD3 = "https://api.stability.ai/v2beta/stable-image/generate/sd3"
PLUGIN_VERSION = "v4 (Fix: denoise -> strength)"

def _to_comfy_image(pil_img: Image.Image):
    """PIL -> ComfyUI IMAGE tensor"""
    pil_img = pil_img.convert("RGB")
    arr = np.asarray(pil_img).astype(np.float32) / 255.0
    return torch.from_numpy(arr)[None, ...]

def _comfy_image_to_png_bytes(image_tensor: torch.Tensor) -> bytes:
    """ComfyUI IMAGE tensor -> PNG bytes"""
    if not isinstance(image_tensor, torch.Tensor):
        image_tensor = torch.tensor(image_tensor)
    if image_tensor.ndim == 4:
        img = image_tensor[0]
    elif image_tensor.ndim == 3:
        img = image_tensor
    else:
        raise RuntimeError(f"IMAGE 维度异常: {tuple(image_tensor.shape)}")
    img = img.detach().cpu().float()
    img = torch.clamp(img, 0.0, 1.0)
    img_u8 = (img * 255.0).round().to(torch.uint8).numpy()
    pil = Image.fromarray(img_u8, mode="RGB")
    buf = io.BytesIO()
    pil.save(buf, format="PNG")
    return buf.getvalue()

def _get_key():
    key = os.getenv("STABILITY_API_KEY", "")
    if not key:
        raise RuntimeError("环境变量 STABILITY_API_KEY 未设置！")
    return key

def _post_stability(url: str, headers: dict, data: dict, files: dict):
    try:
        r = requests.post(url, headers=headers, data=data, files=files, timeout=120)
        return r
    except requests.exceptions.RequestException as e:
        raise RuntimeError(f"网络连接错误: {e}")

def _handle_response(r: requests.Response):
    if r.status_code != 200:
        try:
            j = r.json()
            msg = j.get("errors", j)
            if "insufficient_balance" in str(msg):
                raise RuntimeError(f"余额不足: {msg}")
            raise RuntimeError(f"API 拒绝请求 ({r.status_code}): {msg}")
        except ValueError:
            raise RuntimeError(f"API 报错 ({r.status_code}): {r.text}")
    try:
        data = r.json()
        if "image" not in data:
            raise RuntimeError(f"API 返回异常 (无 image 字段): {data}")
        img_b64 = data["image"]
        img = Image.open(io.BytesIO(base64.b64decode(img_b64)))
        return img
    except Exception as e:
        raise RuntimeError(f"图片处理失败: {e}")

class MyStabilitySD3Txt2Img:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "prompt": ("STRING", {"multiline": True, "default": "A beautiful landscape"}),
                "aspect_ratio": (["1:1", "16:9", "21:9", "2:3", "3:2", "4:5", "5:4", "9:16", "9:21"], {"default": "1:1"}),
                "seed": ("INT", {"default": 0, "min": 0, "max": 4294967294}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"
    CATEGORY = "my_api"

    def run(self, prompt, aspect_ratio, seed):
        print(f"[{PLUGIN_VERSION}] txt2img running...")
        key = _get_key()
        headers = {
            "Authorization": f"Bearer {key}",
            "Accept": "application/json"
        }
        payload = {
            "mode": "text-to-image",
            "prompt": prompt,
            "aspect_ratio": aspect_ratio,
            "seed": str(seed),
            "output_format": "png",
            "model": "sd3"
        }
        files = {"none": ""}
        r = _post_stability(API_URL_SD3, headers, payload, files)
        img = _handle_response(r)
        return (_to_comfy_image(img),)

class MyStabilitySD3Img2Img:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image": ("IMAGE",),
                "prompt": ("STRING", {"multiline": True, "default": "make it anime style"}),
                "image_denoise": ("FLOAT", {"default": 0.35, "min": 0.0, "max": 1.0, "step": 0.01}),
                "seed": ("INT", {"default": 0, "min": 0, "max": 4294967294}),
            },
            "optional": {
                 "aspect_ratio": (["keep", "1:1", "16:9"], {"default": "keep"}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "run"
    CATEGORY = "my_api"

    def run(self, image, prompt, image_denoise, seed, aspect_ratio="keep"):
        print(f"[{PLUGIN_VERSION}] img2img running...")
        key = _get_key()
        headers = {
            "Authorization": f"Bearer {key}",
            "Accept": "application/json"
        }
        png_bytes = _comfy_image_to_png_bytes(image)
        payload = {
            "mode": "image-to-image",
            "prompt": prompt,
            "seed": str(seed),
            "output_format": "png",
            "model": "sd3",
            "strength": str(float(image_denoise))
        }
        if aspect_ratio and aspect_ratio != "keep":
            payload["aspect_ratio"] = aspect_ratio
        files = {
            "image": ("input.png", png_bytes, "image/png"),
        }
        r = _post_stability(API_URL_SD3, headers, payload, files)
        img = _handle_response(r)
        return (_to_comfy_image(img),)

NODE_CLASS_MAPPINGS = {
    "MyStabilitySD3Txt2Img": MyStabilitySD3Txt2Img,
    "MyStabilitySD3Img2Img": MyStabilitySD3Img2Img,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "MyStabilitySD3Txt2Img": "My Stability SD3 (Direct)",
    "MyStabilitySD3Img2Img": "My Stability SD3 Img2Img (Direct)",
}
```

> **关键点**：`requests.post(..., data=payload, files={"none": ""})` 用来强制 `multipart/form-data`，否则用 JSON 发送会被 API 返回 400。

**5. 启动 ComfyUI（CPU 模式）**

```powershell
conda activate comfyui
cd /d E:\image_process\ComfyUI
python main.py --cpu
```

启动成功后访问 `http://127.0.0.1:8188`。

**6. 在 UI 中使用自定义节点**

- 左侧 Node Library 搜索 `My Stability` 或 `my_api`
- 拖出 `My Stability SD3 (Direct)` 节点
- 再拖一个 `Save Image` 节点
- 连线：`My Stability SD3 (Direct)` 的 IMAGE 输出 -> `Save Image` 的 images 输入
- 填写 prompt，点击 Run

图片默认保存到 `ComfyUI\output\`。

### 2.2 方案二：本地 GPU 版（RTX 4060 8GB）

**目标**：新建 conda 环境 `comfyui_gpu`，安装 GPU 版 PyTorch（CUDA），下载模型并在 ComfyUI 里搭建最小工作流出图。

**0. 前置要求**

- NVIDIA 显卡驱动正常（RTX 4060 推荐新驱动）
- 检查显卡驱动：

```powershell
nvidia-smi
```

能看到 GPU 信息即 OK。

**1. 创建 conda 环境**

```powershell
conda create -n comfyui_gpu python=3.10 -y
conda activate comfyui_gpu
```

**2. 进入 ComfyUI 目录**

```powershell
cd /d E:\image_process\ComfyUI
```

**3. 安装 ComfyUI 依赖**

```powershell
pip install -U pip setuptools wheel
pip install -r requirements.txt
```

如果遇到临时目录缺失问题，解决方法：

```powershell
mkdir E:\pip_tmp -Force | Out-Null
$env:TEMP="E:\pip_tmp"
$env:TMP ="E:\pip_tmp"
pip install -r requirements.txt --no-cache-dir --timeout 120
```

**4. 安装 GPU 版 PyTorch（关键步骤）**

```powershell
# 先卸载可能存在的 CPU 版
pip uninstall -y torch torchvision torchaudio

# 安装 CUDA 版（推荐 cu121）
pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio
```

验证 GPU 是否可用：

```powershell
python -c "import torch; print(torch.__version__); print('cuda:', torch.cuda.is_available()); print('gpu:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else None)"
```

预期输出：版本含 `+cu121`，`cuda: True`，`gpu: NVIDIA GeForce RTX 4060`。

**5. 启动 ComfyUI（GPU）**

```powershell
python main.py
```

浏览器打开 `http://127.0.0.1:8188`。

**6. 下载模型**

推荐先用 SDXL Turbo（快速、显存友好）：

- 模型文件：`sd_xl_turbo_1.0_fp16.safetensors`
- 下载地址：[HuggingFace](https://huggingface.co/stabilityai/sdxl-turbo/blob/main/sd_xl_turbo_1.0_fp16.safetensors)

放入目录：`ComfyUI\models\checkpoints\`，然后**重启 ComfyUI**。

### 2.3 快速复现清单

```powershell
# CPU/API 版
conda create -n comfyui python=3.10 -y && conda activate comfyui
git clone https://github.com/comfyanonymous/ComfyUI.git && cd ComfyUI
pip install -r requirements.txt
setx STABILITY_API_KEY "xxx"  # 后重开终端
# 放入 custom_nodes\my_stability_api\ 的 __init__.py 和 nodes.py
python main.py --cpu

# GPU 版
conda create -n comfyui_gpu python=3.10 -y && conda activate comfyui_gpu
cd ComfyUI目录
pip install -r requirements.txt
pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio
python main.py
```

---

## 三、工作流节点与连线

### 3.1 文生图（txt2img）最小工作流

**必需节点清单（6 类）**：

1. `Load Checkpoint`（加载模型）
2. `CLIP Text Encode (Prompt)` x2（正向/负向）
3. `Empty Latent Image`（设定画布尺寸）
4. `KSampler`（采样器）
5. `VAE Decode`（把 latent 解码成图）
6. `Save Image`（保存输出）

**连线规则**：

A. 文本编码：
- `Load Checkpoint` 的 CLIP -> 正向 `CLIP Text Encode` 的 clip
- `Load Checkpoint` 的 CLIP -> 负向 `CLIP Text Encode` 的 clip

B. 采样输入：
- `Load Checkpoint` 的 MODEL -> `KSampler` 的 model
- 正向 `CLIP Text Encode` 的 conditioning -> `KSampler` 的 positive
- 负向 `CLIP Text Encode` 的 conditioning -> `KSampler` 的 negative
- `Empty Latent Image` 的 LATENT -> `KSampler` 的 latent_image

C. 解码与保存：
- `KSampler` 的 LATENT（紫色输出） -> `VAE Decode` 的 samples（紫色输入）
- `Load Checkpoint` 的 VAE（红色） -> `VAE Decode` 的 vae（红色）
- `VAE Decode` 的 IMAGE（蓝色） -> `Save Image` 的 images（蓝色）

### 3.2 图生图（img2img）工作流

相比文生图只多两件事：加载图片 + 把图片编码成 latent。

**额外需要的节点**：

- `Load Image`（加载你要改的那张图）
- `VAE Encode`（把图片编码为 latent）

**新增连线**：

- `Load Image` 的 IMAGE -> `VAE Encode` 的 pixels
- `Load Checkpoint` 的 VAE -> `VAE Encode` 的 vae
- `VAE Encode` 的 LATENT -> `KSampler` 的 latent_image（注意：不再连 `Empty Latent Image`！）

**denoise（去噪强度）参数指南**：

| denoise 值 | 效果 |
|------------|------|
| 0.2 - 0.4 | 基本保留原图构图/姿势，只做轻微改风格/修脸/换质感 |
| 0.5 - 0.7 | 改动明显，但还能看出原图结构 |
| 0.8 - 1.0 | 接近重画，更像文生图（原图只提供一点引导） |

### 3.3 SDXL Turbo 推荐参数

| 参数 | 推荐值 |
|------|--------|
| Steps | 6 |
| CFG | 2.0 |
| Sampler | euler |
| Scheduler | normal / simple |
| Denoise（文生图） | 1.0 |
| 分辨率 | 512x512（先跑通），再 768x768 或 832x1216 |

### 3.4 常见图生图连接坑

- KSampler 的 `latent_image` 还连着 `Empty Latent Image`：图生图要改为连 `VAE Encode` 的 LATENT
- `VAE Encode` 没接 VAE：必须 `Load Checkpoint` 的 VAE -> `VAE Encode` 的 vae
- denoise 设成 0 或太小：几乎不会变；想看到变化就上到 0.4+

---

## 四、提示词（Prompt）工程

### 4.1 Pony V6 / SDXL 高质量提示词模板

**正向 Prompt（萌系二次元，樱花树下示例）**：

```
score_9, score_8_up, rating_safe,
masterpiece, best quality, ultra detailed, anime style,
cute, moe, wholesome,
1girl, young adult woman, human girl,
(cat ear hairband:1.3), (kemonomimi accessory:1.2),
(no tail:1.5), (no fur:1.5), normal human face,
petite, slender, delicate build,
(long flowing purple hair:1.35), silky glossy hair, hair flowing in wind,
(amethyst eyes:1.25), big sparkling eyes,
soft blush, gentle smile, shy expression,
standing under a large cherry blossom tree,
visible sakura tree trunk behind her,
sakura branches arching overhead,
pink sakura canopy filling upper frame,
(sakura blizzard:1.3), cherry blossom petals swirling in wind,
petals flying across foreground and background,
petals resting on hair and shoulders,
dynamic wind movement, flowing fabric,
warm golden afternoon sunlight,
sunlight filtering through blossoms,
soft rim light, warm glow, bloom lighting,
spring atmosphere, soft pink sky,
dappled light on ground covered with petals,
white elegant lightweight robe, modest, flowing fabric,
holding a traditional japanese umbrella, wagasa,
slight body turn, looking slightly upward,
clean lineart, soft shading, vibrant colors,
beautiful composition, depth of field, no text
```

**负向 Prompt**：

```
furry, anthro, beast girl, catgirl, neko girl,
animal face, cat face, muzzle, whiskers,
full body fur, paws, claws, tail, cat tail,
male, masculine face, beard, strong jaw,
realistic, photorealistic, 3d render, oil painting, western comic,
dark fantasy, gothic, demon, horns, wings,
worst quality, low quality, blurry, jpeg artifacts,
bad anatomy, extra fingers, missing fingers,
nsfw, nude, nipples, explicit,
text, watermark, logo, signature, frame
```

### 4.2 Prompt 组件说明

| 组件 | 说明 | 示例 |
|------|------|------|
| `score_9, score_8_up` | Pony 模型专用的质量标签 | 必须放最前 |
| `(keyword:1.3)` | 权重语法，数字越大越强调 | `(cat ears:1.3)` |
| `rating_safe` | 安全评级控制 | 防止 NSFW |
| 场景描述 | 可见树干、花枝、光影 | `standing under a large cherry blossom tree` |
| 构图提示 | 镜头角度和画面布局 | `sakura canopy filling upper frame` |

### 4.3 Pony V6 推荐参数

| 参数 | 推荐值 |
|------|--------|
| 分辨率 | 832 x 1216 |
| Sampler | DPM++ 2M Karras |
| Steps | 28 |
| CFG | 5.5 |
| Hires.fix | 开，放大 1.5x，Denoise 0.35 |
| Upscaler | R-ESRGAN 4x+ Anime6B |

### 4.4 提示词权重技巧

- `(keyword)` = 权重 1.1
- `(keyword:1.3)` = 权重 1.3（精确控制）
- `((keyword))` = 权重 1.21（嵌套加倍）
- `[keyword]` = 权重 0.9（降低权重）
- 想让画面元素更突出就加权重，想让元素弱化就降权重

---

## 五、常见问题排查

### 5.1 UI 里搜不到自定义节点

- 看启动日志有没有 `IMPORT FAILED ... my_stability_api`
- 检查 `__init__.py` 文件名是否正确（不是 `__init__.py.txt`）
- 文件夹层级必须是 `custom_nodes\my_stability_api\__init__.py`

### 5.2 API 报 401 / 403

- 401：Key 不对或环境变量没生效（setx 后没重开终端）
- 403 / insufficient_balance：Stability 账户 credits 不足

### 5.3 CUDA OOM（显存溢出）

按顺序降低：
1. 分辨率降到 512 或 640
2. batch=1
3. steps 降到 4-6
4. ComfyUI 启动加 `--lowvram`

### 5.4 模型下拉框里没有模型

- 检查模型是否在 `models\checkpoints\`
- 放好后重启 ComfyUI

### 5.5 Torch 显示 CUDA: False

- `python -c "import torch; print(torch.__version__)"` 查看是否显示 `+cpu`
- 如果是 CPU 版：卸载后重新按第 4 步装 cu121 版
