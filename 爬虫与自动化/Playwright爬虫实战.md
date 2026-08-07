## 一、API 拦截与后台数据捕获

Playwright 无法直接"爬取后台数据库"，但可以拦截浏览器与服务器之间的网络通信。核心方法是监听 API 响应，直接从中提取 JSON 数据。

### 手动分析网络请求

在写代码之前，必须先用 F12 开发者工具确定目标 API：

1. 打开 **Network** 面板，筛选 **Fetch/XHR**
2. 触发数据加载操作
3. 逐个点击请求，查看 **Response** 标签页
4. 找到包含目标数据的 JSON 响应，记录下 URL 特征

^api-response-structure

典型的 JSON 响应结构：

```json
{
  "code": 200,
  "message": "Success",
  "data": {
    "course_id": "CS101",
    "weights": [
      { "student_id": "PB20010001", "weight": 95 },
      { "student_id": "PB20010002", "weight": 88 }
    ]
  }
}
```

### Playwright 拦截代码

使用 `page.on('response', ...)` 在请求发生前注册监听器，时机至关重要。

^api-intercept-code

```python
import asyncio
from playwright.async_api import async_playwright

TARGET_API_URL_FRAGMENT = "api/course/weights"
course_weights_data = []

async def handle_response(response):
    if TARGET_API_URL_FRAGMENT in response.url:
        print(f"捕获到目标API响应: {response.url}")
        try:
            data = await response.json()
            if data and data.get('data') and isinstance(data['data'].get('weights'), list):
                global course_weights_data
                course_weights_data = data['data']['weights']
        except Exception as e:
            print(f"解析JSON失败: {e}")

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        page = await browser.new_page()

        # 关键：在导航之前设置监听器
        page.on("response", handle_response)

        await page.goto("https://your-school-system.com/login")
        await page.fill('input[name="username"]', "你的学号")
        await page.fill('input[name="password"]', "你的密码")
        await page.click('button[type="submit"]')
        await page.wait_for_navigation()

        await page.goto("https://your-school-system.com/course-selection/CS101")
        await page.wait_for_timeout(5000)

        await browser.close()

        if course_weights_data:
            for item in course_weights_data[:5]:
                print(item)

if __name__ == "__main__":
    asyncio.run(main())
```

### 核心要点

- **先手动，后自动**：永远先用 Network 面板找到正确的 API 地址和数据格式
- **时机很重要**：在触发请求的动作之前设置好 `page.on(...)`
- **稳健做法**：使用 `page.wait_for_response` 等待特定响应完成
- 核心是 **拦截**，而非抓取

---

## 二、模拟登录与 Cookie 持久化

当网站反爬系统识别到自动化脚本时（如知乎返回 40362 错误码），最有效的方式是携带登录 Cookies。

### 诊断步骤

先用 `headless=False` 观察浏览器实际行为：

```python
browser = await p.chromium.launch(
    headless=False,  # 改为 False 观察验证码/登录弹窗
    proxy=None
)
```

^diagnose-headful

### 两步走方案

**步骤 1：保存登录状态**

运行一次 `save_cookies.py`，手动登录后将状态保存到文件：

```python
# save_cookies.py
import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        context = await browser.new_context()
        page = await context.new_page()

        await page.goto("https://www.zhihu.com/signin")

        print("\n请在弹出的浏览器窗口中手动登录...")
        print("登录成功后，不要关闭浏览器，回到这里按 Enter 键继续...")
        input()

        await context.storage_state(path="auth_state.json")
        print("\n登录状态已成功保存到 auth_state.json 文件！")
        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
```

^save-cookies

**步骤 2：加载登录状态**

主脚本加载 `auth_state.json`，以登录用户身份访问：

```python
# 主脚本
async def save_page_to_pdf_with_auth(url: str, output_path: str, auth_file: str):
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,  # 登录后可以用 headless
            proxy=None
        )

        # 从文件加载登录状态
        context = await browser.new_context(storage_state=auth_file)
        page = await context.new_page()

        try:
            await page.goto(url, wait_until="networkidle", timeout=60000)
            await page.wait_for_timeout(2000)
            await page.pdf(path=output_path, format="A4")
        except Exception as e:
            print(f"发生错误: {e}")
        finally:
            await browser.close()
```

^load-cookies

Cookies 方案通常能解决 95% 以上的反爬问题。如果登录后的请求仍被封锁，可结合 [[Playwright爬虫实战#^stealth-patch|playwright-stealth 库]]进一步隐藏自动化特征。

---

## 三、录制视频功能

Playwright 的视频录制与 `BrowserContext` 关联，通过 `record_video_dir` 参数启用。

### 基础视频录制

```python
import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)

        context = await browser.new_context(
            record_video_dir="videos/",          # 视频保存目录
            record_video_size={"width": 1280, "height": 720}  # 可选：分辨率
        )

        page = await context.new_page()

        await page.goto("https://www.google.com")
        await page.get_by_label("Search", exact=True).fill("Playwright")
        await page.get_by_label("Google Search").first.click()
        await page.wait_for_timeout(2000)

        # 关闭上下文时视频自动保存为 .webm 格式
        await context.close()
        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
```

^record-video

### 获取录制的视频路径

`page.video.path()` 必须在 `context.close()` 之后 await：

```python
context = await browser.new_context(record_video_dir="videos/")
page = await context.new_page()
await page.goto("https://example.com")

video_path_future = page.video.path()

await context.close()
saved_path = await video_path_future  # 必须在 close() 之后
print(f"视频已保存到: {saved_path}")
```

### Pytest 中使用

```bash
pytest --video on --headless
# 或只保留失败用例的视频：
pytest --video retain-on-failure --headless
```

视频默认保存为 `.webm` 格式，可在现代浏览器中直接播放。

---

## 四、浏览器扩展集成

当外部工具无法工作时，将逻辑注入浏览器内部。核心思路：创建一个 Chrome 扩展，通过 Playwright 加载该扩展。

### 第一部分：编写扩展

在项目目录创建 `my_extension` 文件夹，包含以下文件：

**1. manifest.json**

```json
{
  "manifest_version": 3,
  "name": "TS Link Catcher",
  "version": "1.0",
  "description": "A simple extension to catch .ts video segment URLs.",
  "permissions": ["webRequest", "storage"],
  "host_permissions": ["*://*.rvmvms.cn/*"],
  "background": { "service_worker": "background.js" },
  "action": { "default_popup": "popup.html" }
}
```

^extension-manifest

**2. background.js** -- 核心监听逻辑

```javascript
let ts_links = [];

chrome.webRequest.onCompleted.addListener(
  (details) => {
    if (details.url.endsWith(".ts")) {
      if (!ts_links.includes(details.url)) {
        ts_links.push(details.url);
        console.log("Caught .ts link:", details.url);
        chrome.storage.local.set({ captured_ts_links: ts_links });
      }
    }
  },
  {
    urls: ["<all_urls>"],
    types: ["media", "other"]
  }
);

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.action === "clear_links") {
        ts_links = [];
        chrome.storage.local.set({ captured_ts_links: ts_links });
        sendResponse({status: "cleared"});
    }
});
```

^extension-background

**3. popup.html + popup.js** -- 简易操作面板

```html
<!DOCTYPE html>
<html>
<head>
  <title>TS Catcher</title>
  <style>
    body { width: 200px; font-family: sans-serif; text-align: center; }
    button { margin-top: 10px; padding: 8px; cursor: pointer; }
  </style>
</head>
<body>
  <h3>TS Link Catcher</h3>
  <p>正在监听 .ts 链接...</p>
  <button id="clearButton">清空已捕获链接</button>
  <script src="popup.js"></script>
</body>
</html>
```

```javascript
document.getElementById('clearButton').addEventListener('click', () => {
  chrome.runtime.sendMessage({ action: "clear_links" }, (response) => {
    if (response.status === "cleared") { window.close(); }
  });
});
```

### 第二部分：Python 加载扩展

使用 `launch_persistent_context` 加载本地未打包扩展：

```python
from playwright.sync_api import sync_playwright

EXTENSION_PATH = "D:/videos/my_extension"
user_data_dir = "D:/videos/playwright_temp_user_data"

context = sync_playwright().start().chromium.launch_persistent_context(
    user_data_dir,
    headless=False,
    args=[
        f"--disable-extensions-except={EXTENSION_PATH}",
        f"--load-extension={EXTENSION_PATH}",
    ],
)

page = context.new_page()
page.goto("https://target-site.com/videoplay/72979", timeout=90000)
page.wait_for_timeout(90 * 1000)  # 等待 90 秒

# 从扩展的 storage 中读取捕获的数据
ts_links = page.evaluate("""
    () => new Promise(resolve => {
        chrome.storage.local.get('captured_ts_links', (result) => {
            resolve(result.captured_ts_links || []);
        });
    })
""")

context.close()
```

^extension-python-load

这种方法相当于在浏览器内部安插了一个"卧底"，从可信环境内获取数据。

---

## 五、页面滚动与高度检测

### `page.evaluate("window.scrollTo(0, document.body.scrollHeight)")`

这行代码将页面猛地滚动到最底部，核心目的是触发网站的"无限滚动"动态加载机制。

参数解析：
- `0`：水平方向滚动到最左边
- `document.body.scrollHeight`：整个网页内容的总高度（像素）

^scroll-to-bottom

### 滚动前的基准测量

```python
# 记录滚动前的页面总高度
last_height = await page.evaluate("document.body.scrollHeight")
```

`document.body.scrollHeight` 测量的是从网页顶部到最底部的完整距离，包括需要滚动才能看到的隐藏内容。

```
+-------------------+  <-- 网页顶部
|                   |
|   屏幕可见区域      |  <-- clientHeight
|                   |
+-------------------+  <-- 屏幕底部
|                   |
|  需要向下滚动才能  |
|  看到的隐藏内容    |
|                   |
+-------------------+  <-- scrollHeight 测量到这里的完整距离
```

### 无限滚动循环逻辑

```python
last_height = await page.evaluate("document.body.scrollHeight")

while True:
    # 滚动到底
    await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
    await page.wait_for_timeout(2000)  # 等待新内容加载

    # 获取新高度
    new_height = await page.evaluate("document.body.scrollHeight")

    if new_height == last_height:
        break  # 高度未变化，已触底

    last_height = new_height  # 更新基准，继续循环
```

^infinite-scroll-loop

如果 `new_height > last_height`，说明成功加载了新内容，页面变长了。如果 `new_height == last_height`，说明已到达尽头，可结束循环。

---

## 六、选择器详解

### 复合选择器 `button.PaginationButton-next`

```python
page.locator("button.PaginationButton-next")
```

这是标签名 + 类名的复合 CSS 选择器，表示**同时满足**两个条件：

- `button` -- 标签必须是 `<button>`
- `.PaginationButton-next` -- class 属性必须包含 `PaginationButton-next`

对应的 HTML 结构：

```html
<button type="button" class="Button PaginationButton PaginationButton-next">
    下一页
</button>
```

^pagination-selector

只用 `button` 会匹配到上一页、页码等其他按钮；只用 `.PaginationButton-next` 可能误匹配非按钮元素。组合使用保证唯一性。

### `.nth(i)` 返回的是 Locator

```python
locator = link_locators.nth(i)
```

`.nth(i)` **不直接返回元素**，而是返回一个新的、更具体的 Locator 对象。这是 Playwright **懒加载**和**自动等待**机制的核心：

- `link_locators`：指向多个元素的定位器（指令集合）
- `.nth(i)`：返回指向第 i 个元素的新定位器
- 只有当你执行 `await locator.inner_text()` 等操作时，Playwright 才去页面上寻找元素，自动等待其出现

^locator-nth-lazy

如果 `.nth(i)` 直接返回元素对象而元素恰好未加载，程序会立即报错。返回 Locator 则可以利用 Playwright 的自动等待机制，更健壮。

---

## 七、事件监听器管理

### `page.on("request", handle_request)` 与 `page.remove_listener`

**雇佣保安的比喻**：

- `page.on("request", handle_request)` -- 雇佣保安，每当有网络请求时都调用 `handle_request`
- `page.remove_listener("request", handle_request)` -- 保安完成任务，解雇他

^listener-lifecycle

```python
m3u8_url_found = None

def handle_request(request):
    global m3u8_url_found
    if ".m3u8" in request.url and not m3u8_url_found:
        m3u8_url_found = request.url
        # 找到目标后立即移除监听器
        page.remove_listener("request", handle_request)

# 在导航之前注册
page.on("request", handle_request)
```

移除监听器的好处：
- **效率**：找到目标后不再进行无意义的检查
- **健壮性**：保证核心逻辑只执行一次，避免重复执行带来的潜在 bug

---

## 八、翻页逻辑处理

### API 游标翻页

^cursor-pagination

从 API 响应中提取 cursor（游标）来驱动翻页：

```python
cursor = data.get('data', {}).get('cursor', {})

# 防御性编程：链式 .get() 避免 KeyError
next_cursor = cursor.get('next', 0)

if not cursor.get('is_end'):
    # 构造下一页请求，回调函数指向自身
    yield scrapy.Request(
        url=f"{api_url}?next={next_cursor}",
        callback=self.parse_comment_api,  # 指向自身，形成递归式循环
        meta={'next_cursor': next_cursor}
    )
else:
    self.logger.info("所有数据已获取完毕。")
```

^cursor-chained-get

`data.get('data', {}).get('cursor', {})` 是防御性编程的优雅写法：
- 第一层 `data.get('data', {})`：找不到 `data` 键则返回空字典 `{}`
- 第二层 `.get('cursor', {})`：找不到 `cursor` 键也返回空字典 `{}`
- 结果只会是真正的 cursor 字典或空字典 `{}`，永远不会抛出 `KeyError`

### 判断结束条件

如果 `cursor.get("is_end")` 为 `True`，说明已是最后一页，函数自然结束，不再 `yield` 新请求，整个翻页链条中断。

---

## 九、playwright-stealth 与反检测

### 虚拟环境解决 ImportError

当 `playwright-stealth` 死活检测不到时，根本原因往往是 Python 环境混乱。最佳实践是创建全新的虚拟环境：

**在 PyCharm 中**：

1. File -> Settings -> Project -> Python Interpreter
2. 齿轮图标 -> Add... -> Virtualenv
3. 取消勾选 "Inherit global site-packages" 和 "Make available to all projects"
4. 在新环境中安装 `playwright` 和 `playwright-stealth`
5. 终端运行 `playwright install`

^venv-fix

### stealth 反检测示例

```python
from playwright_stealth import stealth_async

async with async_playwright() as p:
    browser = await p.chromium.launch(headless=True, args=['--headless=new'])
    context = await browser.new_context(
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        viewport={"width": 1920, "height": 1080}
    )
    page = await context.new_page()
    await stealth_async(page)
    # ... 后续操作
```

^stealth-patch

关键伪装参数：
- `--headless=new`：使用新版 headless 模式，更难被检测
- 自定义 `user_agent` 和 `viewport`：模拟真实浏览器
- `page.remove_listener` 找到目标后应及时移除

---

## 十、中国大陆下载 Chrome

### 方案一：清华大学镜像站（服务器推荐）

```bash
# 从清华镜像站下载最新 Chrome 安装包
wget https://mirrors.tuna.tsinghua.edu.cn/google-chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_current_amd64.deb

# 安装
sudo apt install ./google-chrome-stable_current_amd64.deb
```

^china-mirror-chrome

### 方案二：使用代理工具

在本地 Windows/Mac 上开网络代理工具，通过现有浏览器访问 https://www.google.com/chrome/ 正常下载。

### 方案三：Firefox 替代

```bash
# 添加 Mozilla 官方 PPA
sudo add-apt-repository ppa:mozillateam/ppa
sudo apt-get update

# 安装标准版 FireFox（非 Snap）
sudo apt-get install firefox -y
```

如果 Chrome 在 VNC 环境无法启动，标准版 Firefox 是可靠的备用选择。

---

## 十一、上下游笔记联动

- [[Scrapy框架]]：了解 Scrapy 如何与 Playwright 协作处理动态页面
- [[爬虫反爬与突破]]：深入学习 403 绕过、Referer 伪造、DevTools 检测对抗
- [[网页视频下载]]：关于 m3u8 嗅探和视频下载自动化
- [[服务器运维/宝塔面板部署]]：爬虫在服务器上的持久化运行
- [[Python开发/Python异步编程]]：async/await 异步编程基础

---

## 十二、`page.wait_for_selector` 等待核心元素

```python
# 等待页面的核心部分加载出来
await page.wait_for_selector("div.Collection-main", timeout=15000)
print(">>> 页面加载成功，开始模拟滚动以加载所有内容...")

# 记录初始高度，作为无限滚动的起点
last_height = await page.evaluate("document.body.scrollHeight")
```

这段代码是无限滚动逻辑的前置准备：
1. `wait_for_selector` 确保页面核心区域已渲染完成
2. `last_height` 记录滚动前的页面总高度作为基准
3. 后续通过滚动和高度比较来判断是否触底

^wait-for-selector

---

## 十三、Python 遍历技巧

```python
for i, item in enumerate(all_links):
    link_url = item["links"]
    link_title = item["title"]
```

`enumerate()` 是 Python 内置函数，给列表中每个元素配上从 0 开始的索引：
- `i`：当前索引（0, 1, 2, ...）
- `item`：当前元素（这里是包含 `title` 和 `links` 的字典）

假设 `all_links = [{"title": "文章A", "links": "http://example.com/a"}, {"title": "文章B", "links": "http://example.com/b"}]`，则循环两次，`i` 分别为 0 和 1。

^enumerate-usage
