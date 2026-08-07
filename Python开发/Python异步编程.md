# Python异步编程

## 一、async/await 基础

### 1.1 同步 vs 异步：厨房做饭的比喻

**同步（Synchronous）** -- 按部就班：
烧一壶水（10分钟），然后一直盯着它直到水烧开，再去切蔬菜（5分钟）。

总耗时：10 + 5 = 15分钟。盯水壶的时间被**阻塞（Blocked）**了。

**异步（Asynchronous）** -- 聪明利用等待时间：
打开烧水壶后立刻离开，在烧水的10分钟里去切蔬菜（5分钟）。

总耗时：约10分钟。切菜的时间被包含在了烧水的时间里，没有被阻塞。

^async-vs-sync

### 1.2 async def：声明异步任务

```python
async def save_url_to_pdf(url, output_path):
    # 这个函数包含需要"等待"的步骤
    # 它会被暂停和恢复，不会阻塞其他异步任务
    pass
```

`async def` 定义一个**协程（Coroutine）**。协程就是一个可以被暂停和恢复的特殊函数。

### 1.3 await：标记等待点

```python
await page.goto(url, wait_until='networkidle')
```

`await` 只能用在 `async def` 定义的函数内部。当执行到这一行时：
1. 程序设置一个暂停点
2. 立即交出控制权，去执行其他异步任务
3. 等网络请求返回后，从暂停点继续执行

常见的需要`await`的耗时I/O操作：
- `await browser.chromium.launch()` -- 启动浏览器
- `await page.goto(url, ...)` -- 访问网页，等待网络和页面加载
- `await page.pdf(...)` -- 生成PDF，涉及文件写入
- `await browser.close()` -- 关闭浏览器

^await-examples

### 1.4 asyncio.run：启动异步总指挥

```python
import asyncio

async def main():
    await do_something()

# asyncio.run是启动并管理整个异步流程的总指挥
asyncio.run(main())
```

### 1.5 async/await 的关系总结

| 关键字 | 作用 | 类比 |
|--------|------|------|
| `async def` | 声明一个可暂停的异步函数 | "我要开始一个可以处理等待的特殊任务" |
| `await` | 在耗时操作处挂起，交出控制权 | "就是这里需要等，你先去干别的，好了叫我" |
| `asyncio.run()` | 启动并管理整个异步流程 | 总指挥，协调所有任务的执行、暂停和恢复 |

### 1.6 常见错误：对同步函数使用await

```python
# 错误：download_bilibili_vedios是用def定义的同步函数，返回None
await download_bilibili_vedios(video, output_path)
# TypeError: object NoneType can't be used in 'await' expression

# 正确：同步函数直接调用，不需要await
download_bilibili_vedios(video, output_path)
```

^await-none-error

`await` 关键字只能用在 **async def定义的异步函数（协程）** 上。对一个普通`def`函数使用`await`，因为普通函数返回`None`，等价于`await None`，会抛出`TypeError`。

## 二、yield 与生成器

### 2.1 yield 的工作原理：取票机的比喻

把使用`yield`的函数想象成一台**自动取票机**：

```python
def _stream_chat_response(self, prompt):
    # ... 向AI服务器发送请求 ...
    for chunk in server_response:
        yield chunk.choices[0].delta.content  # 每次只"吐"出一小块文本
```

**过程分解**：

```python
# 第一步：获取"取票机"本身（还没有开始取票）
response_generator = self._stream_chat_response(prompt)

# 第二步：开始取票 -- 逐个消费yield产出的数据
all_chunks = []
for chunk in response_generator:    # for循环就是"取票的人"
    all_chunks.append(chunk)         # 每次拿到一块文本，装进口袋
response_content = "".join(all_chunks)

# 等价于一行代码（list()触发了完整的迭代）
response_content = "".join(list(response_generator))
```

^yield-consumer

### 2.2 yield提交给了谁

**yield把值"提交"给了正在对生成器进行迭代的调用方。**

具体来说：
- `_stream_chat_response` 是**生产者（Producer）**，使用`yield`生产数据
- `for chunk in response_generator:` 或 `list(response_generator)` 是**消费者（Consumer）**
- `yield`是连接两者的桥梁，实现**按需生产**而非一次性全产出

### 2.3 Generator类型提示详解

```python
from typing import Generator

def _stream_chat_response(self, full_prompt: str) -> Generator[str, None, None]:
    # ...
    yield chunk_text
```

`Generator[YieldType, SendType, ReturnType]`三个参数：

| 参数 | 值 | 含义 |
|------|-----|------|
| `YieldType` | `str` | 生成器通过`yield`产出的数据类型（每次产出一个字符串） |
| `SendType` | `None` | 通过`.send()`向生成器内部发送的数据类型（未使用此高级功能） |
| `ReturnType` | `None` | 生成器完全运行结束后最终返回值的类型（函数无`return`语句） |

对于大多数使用场景，只需要关注第一个参数（YieldType）。

### 2.4 生成器 vs 普通函数的区别

| 对比维度 | 普通函数 | 生成器函数 |
|----------|----------|------------|
| 返回值 | 一次性返回所有结果 | 逐次yield小块数据 |
| 内存 | 所有结果一次性加载 | 按需生产，节省内存 |
| 响应速度 | 需要等待全部计算完成 | 即时产出第一个结果 |
| 关键标志 | `return` | `yield` |
| 比喻 | 一次性买整箱可乐 | 自动续杯的可乐机 |

^generator-vs-function

任何函数只要内部包含`yield`关键字，就自动成为生成器函数。

### 2.5 高级用法：.send() 与 generator return

```python
def advanced_generator():
    received_value = yield "Give me a value"   # yield在这里同时接收和产出
    print(f"I received: {received_value}")

gen = advanced_generator()
print(next(gen))     # 启动生成器，打印 "Give me a value"
gen.send(123)        # 发送值123回去，打印 "I received: 123"
```

带返回值的生成器（不常见）：
```python
def generator_with_return() -> Generator[int, None, str]:
    yield 1
    yield 2
    return "Finished!"

gen = generator_with_return()
print(next(gen))  # 1
print(next(gen))  # 2
try:
    next(gen)
except StopIteration as e:
    print(e.value)  # "Finished!"
```

## 三、实战：流式聊天的异步处理模式

### 3.1 _process_single_task 任务执行引擎

这是一个完整的异步任务处理流程，用于处理长文本分析任务：

```python
def _process_single_task(self, task_config: Dict[str, Any], full_text: str) -> str:
    task_name = task_config["name"]
    instruction = task_config["instruction"]
    not_found_indicator = task_config.get("not_found_indicator", "TASK_CONTENT_NOT_FOUND")

    print(f"任务 '{task_name}' 正在分析全文...")

    # 第一步：文本分块
    text_splitter = RecursiveCharacterTextSplitter(
        chunk_size=10000,
        chunk_overlap=500
    )
    chunks = text_splitter.split_text(full_text)
    print(f"全文被切分为 {len(chunks)} 块进行处理。")

    # 第二步：逐块处理
    task_responses = []
    for i, chunk in enumerate(chunks):
        print(f"  -> 正在处理 '{task_name}' 的第 {i + 1}/{len(chunks)} 块...")

        # 第三步：调用AI
        prompt = f"{instruction}\n\n--- 待分析文本块 ---\n{chunk}\n--- 文本块结束 ---"
        response_generator = self._stream_chat_response(prompt)
        response_content = "".join(list(response_generator))

        # 第四步：筛选有用结果
        if not_found_indicator not in response_content:
            task_responses.append(response_content)

    # 第五步：汇总结果
    if not task_responses:
        return "在全文的所有文本块中均未找到或生成相关内容。"

    return "\n\n".join(task_responses).strip()
```

^process-single-task

### 3.2 工作流五个阶段

| 阶段 | 代码实现 | 比喻 |
|------|----------|------|
| 准备 | 读取`task_config`和`full_text` | 拿到作业要求和一本厚厚的书 |
| 分块 | `text_splitter.split_text(...)` | 把书拆成易于阅读的章节 |
| 循环处理 | `for chunk in chunks:` | 逐章阅读 |
| AI调用 | `_stream_chat_response(prompt)` | 对每一章进行思考和分析 |
| 结果过滤 | `if not_found_indicator not in ...` | 判断这一章是否与作业相关，做笔记 |
| 最终汇总 | `"\n\n".join(task_responses)` | 整理所有笔记，写出最终答案 |

### 3.3 流式响应：为什么用生成器

流式响应（streaming）的核心优势：
- **即时显示**：AI生成的文本逐块返回，实现"打字机效果"
- **节省内存**：不需要在内存中一次性加载完整回复
- **用户感知快**：用户立刻看到第一段文字，不需要等待全部生成完成

```python
def _stream_chat_response(self, full_prompt: str) -> Generator[str, None, None]:
    """
    这是一个流式函数。调用它会得到一个生成器对象，
    这个生成器会像流水一样，一次一小部分地产出字符串。
    你必须用循环或类似方式逐一接收这些数据。
    """
    # ... 连接AI API，监听流式响应 ...
    for event in stream:
        chunk_content = get_chunk_text(event)
        yield chunk_content   # 产出一小段文本
```

## 四、事件循环概念

Python的异步编程基于**事件循环（Event Loop）**：

1. 事件循环维护一个任务队列
2. 当`await`遇到I/O等待时，当前任务被挂起
3. 事件循环切换到其他就绪任务
4. 当I/O操作完成，被挂起的任务恢复执行

`asyncio.run()` 就是创建并运行事件循环的入口。

---

## 相关笔记

- [[爬虫与自动化/Playwright爬虫实战]] -- Playwright中async/await的实际应用场景
