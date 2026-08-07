## 一、Scrapy 项目完整架构

Scrapy 框架的核心职责分离：

- **Spider**：总指挥，负责调用 API/解析页面、组装 Item
- **Item**：数据蓝图，定义字段结构，让数据流动清晰
- **Pipeline**：数据处理站，接收 Item 执行下载、存储等操作
- **Middleware**：请求/响应的中间处理层

安装与创建项目：

```bash
pip install scrapy
scrapy startproject my_project
cd my_project
scrapy genspider myspider example.com
```

---

## 二、B站大规模评论爬取实例

### 配置 settings.py

大规模爬取的核心配置：

```python
# settings.py
USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ...'

ROBOTSTXT_OBEY = False

# 开启异步支持（关键）
TWISTED_REACTOR = 'twisted.internet.asyncioreactor.AsyncioSelectorReactor'

# 请求频率控制
AUTOTHROTTLE_ENABLED = True
DOWNLOAD_DELAY = 1
CONCURRENT_REQUESTS = 16
CONCURRENT_REQUESTS_PER_DOMAIN = 8

LOG_LEVEL = 'INFO'

# JsonLines 导出，适合大数据量
FEEDS = {
    'results.jl': {
        'format': 'jsonlines',
        'encoding': 'utf8',
    }
}
```

^settings-bili

### 定义 Item

```python
# items.py
import scrapy

class BiliCommentItem(scrapy.Item):
    video_bvid = scrapy.Field()
    video_aid = scrapy.Field()
    video_title = scrapy.Field()
    video_author = scrapy.Field()
    comment_rpid = scrapy.Field()
    comment_user_name = scrapy.Field()
    comment_user_level = scrapy.Field()
    comment_content = scrapy.Field()
    comment_like_count = scrapy.Field()
    comment_time_str = scrapy.Field()
```

^item-bili

### 核心 Spider（使用 bilibili-api-python）

```python
# spiders/comment_spider.py
import scrapy
from bilibili_api import search, video
import time
from ..items import BiliCommentItem

class CommentSpiderSpider(scrapy.Spider):
    name = 'comment_spider'
    allowed_domains = ['bilibili.com']

    KEYWORD = "Scrapy教程"
    MAX_SEARCH_PAGES = 5

    async def start_requests(self):
        for page_num in range(1, self.MAX_SEARCH_PAGES + 1):
            try:
                search_result = await search.search_by_type(
                    keyword=self.KEYWORD,
                    search_type=search.SearchObjectType.VIDEO,
                    page=page_num
                )

                videos = search_result.get("result", [])
                if not videos:
                    break

                for v_info in videos:
                    bvid = v_info.get("bvid")
                    meta_data = {
                        "video_bvid": bvid,
                        "video_aid": v_info.get("aid"),
                        "video_title": v_info.get("title").replace(
                            '<em class="keyword">', ''
                        ).replace('</em>', ''),
                        "video_author": v_info.get("author")
                    }
                    yield scrapy.Request(
                        url=f"https://www.bilibili.com/video/{bvid}",
                        callback=self.parse_video_comments,
                        meta=meta_data,
                        dont_filter=True
                    )

            except Exception as e:
                self.logger.error(f"处理搜索第 {page_num} 页时出错: {e}")

    async def parse_video_comments(self, response):
        video_meta = response.meta
        try:
            v = video.Video(bvid=video_meta["video_bvid"])
            comment_count = 0

            async for comment in v.get_comments():
                item = BiliCommentItem()
                item['video_bvid'] = video_meta['video_bvid']
                item['video_aid'] = video_meta['video_aid']
                item['video_title'] = video_meta['video_title']
                item['video_author'] = video_meta['video_author']
                item['comment_rpid'] = comment.rpid
                item['comment_user_name'] = comment.member['uname']
                item['comment_user_level'] = comment.member['level_info']['current_level']
                item['comment_content'] = comment.content['message']
                item['comment_like_count'] = comment.like
                item['comment_time_str'] = time.strftime(
                    "%Y-%m-%d %H:%M:%S", time.localtime(comment.ctime)
                )
                comment_count += 1
                yield item

            self.logger.info(f"视频评论获取完毕，共 {comment_count} 条。")

        except Exception as e:
            self.logger.error(f"获取评论出错: {e}")
```

^spider-bili-full

运行：

```bash
scrapy crawl comment_spider
```

结果输出到 `results.jl`，每行一条 JSON 格式的评论数据。

---

## 三、B站 API 集成到 Scrapy 的两种方法

### 方法一：使用 bilibili-api-python（推荐）

Spider 方法加 `async`，内部用 `await` 调用异步 API。Scrapy 2.0+ 原生支持 asyncio。

```python
# spiders/up_videos.py
import scrapy
from bilibili_api import user, video
from ..items import BiliVideoItem

class UpVideosSpider(scrapy.Spider):
    name = 'up_videos'
    UP_UID = 27534330  # 如老番茄

    async def start_requests(self):
        u = user.User(uid=self.UP_UID)
        videos_info = await u.get_videos()
        video_list = videos_info.get('list', {}).get('vlist', [])

        for v_info in video_list:
            bvid = v_info.get('bvid')
            author = v_info.get('author')
            if bvid:
                yield scrapy.Request(
                    url=f"https://www.bilibili.com/video/{bvid}",
                    callback=self.parse_video,
                    meta={'bvid': bvid, 'author': author}
                )

    async def parse_video(self, response):
        bvid = response.meta['bvid']
        author = response.meta['author']

        item = BiliVideoItem()
        item['bvid'] = bvid
        item['author'] = author

        try:
            v = video.Video(bvid=bvid)
            details = await v.get_info()
            item['title'] = details['title']
            item['play_count'] = details['stat']['view']
            item['danmaku_count'] = details['stat']['danmaku']
            item['cover_url'] = details['pic']

            tags_info = await v.get_tags()
            item['tags'] = [tag['tag_name'] for tag in tags_info]

            yield item
        except Exception as e:
            self.logger.error(f"处理视频 {bvid} 时出错: {e}")
```

^api-library-approach

### 方法二：直接构造 Web API 请求

不依赖第三方库，直接向 B站 API 发请求。需要从 `bilibili-API-collect` 文档找接口信息。

**关键信息（评论区 API）**：
- URL：`https://api.bilibili.com/x/v2/reply/main`
- 方法：GET
- 参数：`oid`(视频aid)、`type`(1)、`next`(翻页游标)

```python
import scrapy
import json
from urllib.parse import urlencode

class BiliWebApiSpider(scrapy.Spider):
    name = 'bili_web_api'
    allowed_domains = ['api.bilibili.com']

    TARGET_VIDEO_AID = 850819123
    TARGET_VIDEO_TITLE = "示例视频标题"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # 加载 Cookies
        try:
            with open('cookies.json', 'r', encoding='utf-8') as f:
                cookies_list = json.load(f)
                self.cookies = {c['name']: c['value'] for c in cookies_list}
        except FileNotFoundError:
            self.logger.error("cookies.json 未找到！")
            self.cookies = {}

    def start_requests(self):
        next_cursor = 0
        api_base_url = "https://api.bilibili.com/x/v2/reply/main"
        params = {'oid': self.TARGET_VIDEO_AID, 'type': 1, 'next': next_cursor}
        request_url = f"{api_base_url}?{urlencode(params)}"

        yield scrapy.Request(
            url=request_url,
            callback=self.parse_comment_api,
            cookies=self.cookies,
            meta={'video_aid': self.TARGET_VIDEO_AID,
                  'video_title': self.TARGET_VIDEO_TITLE,
                  'next_cursor': next_cursor}
        )

    def parse_comment_api(self, response):
        data = json.loads(response.text)

        if data.get('code') != 0:
            self.logger.error(f"API返回错误: {data.get('message')}")
            return

        # 提取评论
        comments = data.get('data', {}).get('replies', [])
        for c in comments:
            yield {
                'user': c.get('member', {}).get('uname'),
                'content': c.get('content', {}).get('message'),
                'like': c.get('like'),
            }

        # 翻页逻辑
        cursor = data.get('data', {}).get('cursor', {})
        if not cursor.get('is_end'):
            next_cursor = cursor.get('next', 0)
            params = {'oid': self.TARGET_VIDEO_AID, 'type': 1, 'next': next_cursor}
            request_url = f"{api_base_url}?{urlencode(params)}"
            meta_data = response.meta.copy()
            meta_data['next_cursor'] = next_cursor

            yield scrapy.Request(
                url=request_url,
                callback=self.parse_comment_api,  # 回调自身，递归式翻页
                cookies=self.cookies,
                meta=meta_data
            )
        else:
            self.logger.info("所有评论已获取完毕。")
```

^web-api-approach

### 两种方法对比

| 特性 | API库 | 直接调用Web API |
|------|-------|-----------------|
| 依赖 | 需要第三方库 | 仅需Scrapy |
| 复杂度 | 低 | 高（手动拼接URL、处理参数）|
| 灵活性 | 受限于库功能 | 极高，可调用任何API端点 |
| 可维护性 | 库作者维护 | 需自行维护API变动 |

**建议**：初学者优先使用 API 库；调用冷门 API 或最大化性能时使用直接构造请求。

---

## 四、Scrapy 图片下载

### 传统静态页面：ImagesPipeline

对于 `<img>` 标签的 `src` 直接指向图片 URL 的情况：

```python
# items.py
import scrapy

class ImageItem(scrapy.Item):
    image_urls = scrapy.Field()  # 固定字段名
    images = scrapy.Field()      # 固定字段名
```

```python
# settings.py
ITEM_PIPELINES = {
   'scrapy.pipelines.images.ImagesPipeline': 1,
}
IMAGES_STORE = 'downloaded_images'
```

^images-pipeline-basic

### 现代动态页面的挑战

现代网站常见阻碍：

- **懒加载**：真实 URL 存于 `data-src`、`data-original` 属性，`src` 只是占位符
- **JS 动态生成**：图片列表通过 API 获取后 JS 渲染，Scrapy 默认无法执行 JS
- **CSS 背景图**：通过 `background-image` 设置，不在 `<img>` 标签中
- **响应式图片**：`<picture>` 标签或 `srcset` 属性提供多种分辨率

### 解决方案一：Scrapy-Playwright（推荐）

将 Scrapy 与浏览器渲染引擎结合：

```bash
pip install scrapy scrapy-playwright
playwright install
```

```python
# settings.py
DOWNLOAD_HANDLERS = {
    "http": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
    "https": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
}
TWISTED_REACTOR = "twisted.internet.asyncioreactor.AsyncioSelectorReactor"
```

```python
# spiders/zhihu_spider.py
import scrapy
from scrapy_playwright.page import PageMethod
from ..items import ZhihuImageItem

class ZhihuSpider(scrapy.Spider):
    name = 'zhihu'
    start_urls = ['https://www.zhihu.com/question/29262608']

    def start_requests(self):
        for url in self.start_urls:
            yield scrapy.Request(
                url,
                meta={
                    'playwright': True,
                    'playwright_page_methods': [
                        # 模拟滚动 10 次，每次间隔 1 秒
                        PageMethod('evaluate', """
                            async () => {
                                for(let i = 0; i < 10; i++) {
                                    window.scrollTo(0, document.body.scrollHeight);
                                    await new Promise(r => setTimeout(r, 1000));
                                }
                            }
                        """),
                    ],
                }
            )

    def parse(self, response):
        image_urls = response.xpath(
            '//div[@class="RichContent-inner"]//img/@src'
        ).getall()

        if image_urls:
            item = ZhihuImageItem()
            item['image_urls'] = image_urls
            yield item
```

^scrapy-playwright-zhihu

### 解决方案二：分析 API 请求

- 打开 F12 -> Network -> Fetch/XHR
- 找到返回图片 URL 列表的 API
- 在 Scrapy 中直接模拟该 API 请求，获取 JSON 后提取 URL
- 交给 ImagesPipeline 下载

---

## 五、自定义 ImagesPipeline 下载封面

继承 `ImagesPipeline` 来自定义文件存储路径：

```python
# pipelines.py
import scrapy
from scrapy.pipelines.images import ImagesPipeline
import os

class BiliCoverPipeline(ImagesPipeline):

    def get_media_requests(self, item, info):
        cover_url = item.get('cover_url')
        if cover_url:
            yield scrapy.Request(cover_url, meta={'bvid': item.get('bvid')})

    def file_path(self, request, response=None, info=None, *, item=None):
        bvid = request.meta['bvid']
        image_ext = os.path.splitext(request.url)[1]
        filename = f"{bvid}{image_ext}"
        return f'full/{filename}'

    def item_completed(self, results, item, info):
        image_paths = [x['path'] for ok, x in results if ok]
        if image_paths:
            item['cover_local_path'] = image_paths[0]
        return item
```

^bili-cover-pipeline

启用：

```python
# settings.py
ITEM_PIPELINES = {
   'my_project.pipelines.BiliCoverPipeline': 300,
}
IMAGES_STORE = 'downloaded_images'
```

---

## 六、YouTube API 示例

### 配额警告

YouTube 官方 API 有严格配额限制（每天 10,000 单元）：
- 一次搜索约 100 单元
- 一页评论（最多 100 条）约 1 单元

因此**不适合真正的大规模爬取**，仅适用于小规模采集。

### 完整爬虫代码

```python
# spiders/yt_comments.py
import scrapy
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from ..items import YoutubeCommentItem

class YtCommentsSpider(scrapy.Spider):
    name = 'yt_comments'
    allowed_domains = ['youtube.com', 'googleapis.com']

    API_KEY = "你的API密钥"
    KEYWORD = "Scrapy tutorial"
    MAX_VIDEO_RESULTS = 10

    def start_requests(self):
        try:
            youtube_service = build("youtube", "v3", developerKey=self.API_KEY)

            search_request = youtube_service.search().list(
                q=self.KEYWORD,
                part="snippet",
                maxResults=self.MAX_VIDEO_RESULTS,
                type="video"
            )
            search_response = search_request.execute()

            for item in search_response.get("items", []):
                video_id = item["id"]["videoId"]
                video_title = item["snippet"]["title"]

                yield scrapy.Request(
                    url=f"https://www.youtube.com/watch?v={video_id}",
                    callback=self.parse_comments,
                    meta={
                        "video_id": video_id,
                        "video_title": video_title,
                        "youtube_service": youtube_service
                    }
                )

        except HttpError as e:
            self.logger.error(f"搜索API HTTP错误: {e}")

    def parse_comments(self, response):
        video_id = response.meta["video_id"]
        video_title = response.meta["video_title"]
        youtube = response.meta["youtube_service"]

        try:
            request = youtube.commentThreads().list(
                part="snippet",
                videoId=video_id,
                textFormat="plainText",
                maxResults=100
            )

            while request:
                comment_response = request.execute()

                for item in comment_response.get("items", []):
                    comment_item = YoutubeCommentItem()
                    comment = item['snippet']['topLevelComment']['snippet']

                    comment_item['video_id'] = video_id
                    comment_item['video_title'] = video_title
                    comment_item['comment_author_name'] = comment['authorDisplayName']
                    comment_item['comment_content'] = comment['textDisplay']
                    comment_item['comment_like_count'] = comment['likeCount']
                    comment_item['comment_publish_time'] = comment['publishedAt']

                    yield comment_item

                request = youtube.commentThreads().list_next(
                    previous_request=request,
                    previous_response=comment_response
                )

        except HttpError as e:
            if "disabled comments" in str(e).lower():
                self.logger.warning(f"视频 '{video_title}' 的评论区已关闭。")
```

^youtube-example

### 真正大规模爬取 YouTube？

唯一途径是抛弃官方 API，逆向 YouTube 的内部私有 API（InnerTube API）。但这极其复杂、无文档、常变动，不适合初学者。

---

## 七、上下游笔记联动

- [[Playwright爬虫实战]]：浏览器自动化伴侣，解决动态页面 JS 渲染
- [[爬虫反爬与突破]]：下载请求伪装、403 绕过、防盗链处理
- [[网页视频下载]]：视频资源嗅探与下载思路
- [[服务器运维/宝塔面板部署]]：爬虫在服务器上持久化运行
- [[Python开发/Python异步编程]]：asyncio 与 Twisted 反应器基础
