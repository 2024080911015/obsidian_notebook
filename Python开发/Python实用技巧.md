# Python实用技巧

## 一、使用Python通过163邮箱发送邮件

### 1.1 准备工作：获取163邮箱授权码

之前：出于安全原因，163邮箱不允许在第三方客户端（如Python脚本）中使用登录密码，必须使用**授权码**。

操作步骤：
1. 登录网页版163邮箱（mail.163.com）
2. 点击"设置" -> "POP3/SMTP/IMAP"
3. 开启"IMAP/SMTP服务"或"POP3/SMTP服务"
4. 通过安全验证（短信验证码）获取16位授权码
5. 复制保存授权码（只显示一次）

### 1.2 完整发送邮件代码

```python
import smtplib
import os
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders
from email.header import Header

def send_email_with_attachment():
    # --- 邮件配置信息 ---
    smtp_server = 'smtp.163.com'        # 163邮箱SMTP服务器地址
    smtp_port = 465                     # SSL加密端口号

    sender_email = 'your_account@163.com'
    # ！！！注意：这里填写授权码，不是登录密码
    password = 'YOUR_AUTHORIZATION_CODE'

    receiver_email = 'recipient_email@example.com'

    # 邮件内容
    subject = '这是一个带附件的Python邮件'
    body_text = '您好，\n\n这是通过Python脚本发送的测试邮件，附件中是您需要的文件。\n\n祝好！'

    # 附件文件路径
    attachment_path = 'D:/path/to/your/file.zip'
    # -----------------------------------------

    # --- 构建邮件 ---
    msg = MIMEMultipart()
    # 使用Header处理中文，避免乱码
    msg['From'] = Header(f"Python邮件机器人 <{sender_email}>", 'utf-8')
    msg['To'] = Header(f"尊敬的收件人 <{receiver_email}>", 'utf-8')
    msg['Subject'] = Header(subject, 'utf-8')

    # 1. 添加邮件正文
    msg.attach(MIMEText(body_text, 'plain', 'utf-8'))

    # 2. 添加附件
    if not os.path.exists(attachment_path):
        print(f"错误：附件文件不存在于路径 {attachment_path}")
        return

    try:
        with open(attachment_path, 'rb') as f:
            mime = MIMEBase('application', 'octet-stream')
            mime.set_payload(f.read())

        # Base64编码
        encoders.encode_base64(mime)

        # 从路径中提取文件名
        filename = os.path.basename(attachment_path)
        # 设置附件头，处理中文文件名
        mime.add_header('Content-Disposition', 'attachment',
                        filename=(Header(filename, 'utf-8').encode()))

        msg.attach(mime)
        print("附件已成功添加。")
    except Exception as e:
        print(f"添加附件时出错: {e}")
        return

    # --- 发送邮件 ---
    try:
        print("正在连接到SMTP服务器...")
        with smtplib.SMTP_SSL(smtp_server, smtp_port) as server:
            print("正在登录...")
            server.login(sender_email, password)
            print("登录成功！正在发送邮件...")
            server.send_message(msg)
            print("邮件发送成功！")

    except smtplib.SMTPAuthenticationError:
        print("SMTP登录失败！请检查您的邮箱账号和授权码是否正确。")
    except Exception as e:
        print(f"邮件发送时发生错误: {e}")

if __name__ == '__main__':
    send_email_with_attachment()
```

^send-email-code

### 1.3 使用步骤

1. 保存代码为 `send_mail.py`
2. 修改顶部配置信息（邮箱、授权码、附件路径）
3. 确保附件文件真实存在于指定路径
4. 运行：`python send_mail.py`

## 二、异常处理最佳实践

### 2.1 方法一：捕获所有标准错误（最常用）

当不确定会出什么错误时，使用`except Exception as e`：

```python
import requests

try:
    print("准备执行一些可能出错的代码...")

    # 模拟网络请求
    response = requests.get("https://一个不存在的网址.com", timeout=5)

    # 模拟计算错误
    result = 10 / 0

    # 模拟类型错误
    total = "5" + 20

except Exception as e:
    print("\n" + "-" * 30)
    print("糟糕！程序发生了一个意料之外的错误！")
    print(f"错误的类型是: {type(e).__name__}")
    print(f"具体的错误信息是: {e}")
    print("-" * 30)

print("\n即使发生了错误，程序依然可以继续运行到这里。")
```

^exception-all

`Exception` 是Python中几乎所有常见程序错误的基类（`TypeError`, `ValueError`, `IOError`, `KeyError`等）。它能捕获所有程序意外，但不会捕获`KeyboardInterrupt`（Ctrl+C）等系统级信号。

### 2.2 方法二：分层捕获（最佳实践）

先捕获已知错误，再用`Exception`作为安全网：

```python
file_path = "my_data.txt"

try:
    print(f"尝试打开文件: {file_path}")
    with open(file_path, 'r') as f:
        content = f.read()
        value = int(content)
        result = 100 / value
    print(f"计算结果是: {result}")

except FileNotFoundError:
    # 已知错误1：文件不存在
    print("错误：文件未找到！请检查文件路径是否正确。")

except ValueError:
    # 已知错误2：文件内容不是数字
    print("错误：文件内容无法转换为数字！请检查文件内容。")

except ZeroDivisionError:
    # 已知错误3：除数为零
    print("错误：文件中的数字是0，无法作为除数！")

except Exception as e:
    # 安全网：所有其他未知错误
    print(f"发生未知错误！错误类型: {type(e).__name__}, 错误信息: {e}")

finally:
    # finally块无论是否发生错误都会执行
    # 适合做清理工作：关闭文件、关闭数据库连接等
    print("\n--- 清理工作已执行 ---")
```

^exception-layered

### 2.3 方法三：裸except（不推荐）

```python
try:
    # ...
except:   # <--- 裸except会捕获一切
    print("捕获了所有东西！")
```

裸`except:`会捕获包括`SystemExit`和`KeyboardInterrupt`在内的所有异常，导致程序无法被Ctrl+C正常中断。**绝对避免使用。**

### 2.4 策略总结

| 场景 | 推荐方式 |
|------|----------|
| 不确定会出什么错 | `except Exception as e:` |
| 代码逐渐成熟 | 分层捕获：特定错误 + `except Exception`安全网 |
| 需要清理资源 | 加`finally`块 |
| 如何选择 | **永远不要**使用裸`except:` |

## 三、类型提示：Generator[str, None, None]

### 3.1 三个参数的含义

```python
from typing import Generator

def _stream_chat_response(self, prompt: str) -> Generator[str, None, None]:
    """返回一个产出字符串的生成器"""
    ...
    yield chunk_text
```

`Generator[YieldType, SendType, ReturnType]` 三个参数：

- **`str`（YieldType）**：生成器通过`yield`产出的数据类型。这里每次产出一个文本片段，所以是`str`。
- **`None`（SendType）**：通过`.send()`向生成器内部发送的数据类型。大多数场景不使用此高级功能，所以是`None`。
- **`None`（ReturnType）**：生成器完全运行结束后，`return`返回值的类型。函数没有`return`语句时，默认返回`None`。

_对于大多数使用场景，只需要关注第一个参数`str`即可。_

^generator-type-hints

### 3.2 生成器类比

| 比喻 | 生成器 | 普通函数 |
|------|--------|----------|
| 获取方式 | 调用函数得到"可乐机" | 一次性拿"整箱可乐" |
| 消费方式 | 每次按按钮取一口 | 一次性全部给你 |
| 响应速度 | 即时（打字机效果） | 需要等所有结果就绪 |
| 内存占用 | 按需生产，省内存 | 所有结果一次加载 |

## 四、类命名与框架约定

### 4.1 类名可以随便写吗

**类名可以随便写，但必须在框架配置中正确引用。**

以Scrapy的Pipeline为例：

```python
# pipelines.py
import pymongo

# 类名可以自定义
class MongoPipeline(object):          # 可以
class SaveToMyDatabase(object):       # 也可以
    def process_item(self, item, spider):
        # ...
```

关键是`settings.py`中的引用必须匹配：
```python
# settings.py
ITEM_PIPELINES = {
   # 路径必须与类名严格对应
   'tutorial.pipelines.MongoPipeline': 300,
   # 如果改了类名，这里也必须同步修改
   'tutorial.pipelines.SaveToMyDatabase': 300,
}
```

^class-naming

### 4.2 框架约定：可以改 vs 不能改

| 项目 | 是否可改 | 说明 |
|------|----------|------|
| 类名 | **可以改** | 如`MongoPipeline`，但settings中要同步修改引用路径 |
| 方法名 | **不能改** | 如`open_spider`, `process_item`, `close_spider`是Scrapy的钩子 |
| 函数名带`_`前缀 | 约定俗成 | 表示内部辅助函数，框架不会直接调用 |

### 4.3 框架如何知道要调用你自定义的函数

以Scrapy中间件为例：

Scrapy框架**并不知道也不关心**`_start_driver`这个自定义函数。调用链是：

```
Scrapy框架 -> process_request（框架认识的接口）-> _start_driver（你写的内部辅助函数）
```

```python
# 框架只会调用process_request（它的公共接口）
def process_request(self, request, spider):
    # 在需要的时候，你自己主动调用内部辅助函数
    self._start_driver()                   # 经理对手下说："去把车开出来！"
    self.driver.get(request.url)           # 车备好之后，处理正事
```

^framework-call-chain

`_start_driver`的作用：
- 检查`self.driver`是否为`None`（浏览器是否已启动）
- 如果未启动则启动，已启动则直接返回
- 这是一种**懒加载+单例**的模式

_函数名前加`_`是Python约定，表示"这是内部辅助函数，不期望被外部直接调用"。_

## 五、调试与常见错误

### 5.1 TypeError: NoneType can't be used in 'await'

**错误信息**：
```
TypeError: object NoneType can't be used in 'await' expression
```

**原因**：对一个用`def`（非`async def`）定义的普通同步函数使用了`await`。普通函数没有`return`语句时默认返回`None`，所以相当于`await None`。

**修正**：
```python
# 错误
await download_bilibili_vedios(video, output_path)

# 正确：同步函数直接调用，不需要await
download_bilibili_vedios(video, output_path)
```

^await-none-type-error

### 5.2 Python的None类型传递

当类型检查或代码中出现 `str, None, None` 时，通常不是指函数参数，而是指 `Generator[str, None, None]` 的类型参数，详见[[Python异步编程#^generator-type-hints|Python异步编程中的类型提示章节]]。

## 六、常用技巧速查表

| 需求 | 方案 |
|------|------|
| 不知道会出什么错误 | `except Exception as e:` 打印 `type(e).__name__` |
| 需要精细异常处理 | 先捕获特定错误，最后`except Exception`做安全网 |
| 需要清理资源 | 使用`finally`块 |
| 发送带附件邮件 | `smtplib.SMTP_SSL` + `MIMEMultipart` + 163授权码 |
| 自定义类名 | 可随意命名，但需在框架配置中正确引用 |
| 辅助函数不被框架调用 | 在框架钩子函数内主动调用自定义函数 |
| 理解Generator类型 | `Generator[产出类型, 发送类型, 返回类型]` |

---

## 相关笔记

- [[Python异步编程]] -- async/await、yield生成器与协程
- [[爬虫与自动化/Playwright爬虫实战]] -- Playwright中的异步编程应用
