# Flask框架入门

## 一、Flask基础架构

### 1.1 最小Flask应用骨架

Flask是一个轻量级的Python Web框架。一个最小的Flask应用由导入、创建app对象、注册路由和启动服务四步组成。

```python
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/")
def home():
    return "Flask is running. Try /tuijian?id=1"

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
```

### 1.2 关键组件解释

**导入**：
- `Flask` -- Web应用的主类，用于创建服务对象
- `request` -- 代表本次HTTP请求，可从中读取URL参数、表单、JSON等
- `jsonify` -- 将Python字典/列表转换为JSON响应，并自动设置响应头

**创建app对象**：
```python
app = Flask(__name__)
```
`__name__`是Python内置变量，表示当前模块名。Flask用它定位资源、做调试配置。后续的`@app.route(...)`都是在给app注册访问路径。

**启动服务**：
```python
app.run(host="127.0.0.1", port=5000, debug=True)
```
- `host="127.0.0.1"` -- 只允许本机访问
- `port=5000` -- 端口号，完整地址为 `http://127.0.0.1:5000`
- `debug=True` -- 开启调试模式，代码改动自动重启，出错时浏览器显示详细错误页面（仅限开发环境）

**`if __name__ == "__main__"` 的作用**：
- 直接运行 `python app.py` 时条件成立，启动服务
- 被 `import app` 导入时不成立，不会自动启动
- 这是一种规范写法，方便代码复用

## 二、路由与请求处理

### 2.1 路由装饰器

```python
@app.route("/tuijian")
def tuijian():
    # 这个函数会在访问 http://127.0.0.1:5000/tuijian 时被触发
    pass
```

`@app.route("/path")` 是一个装饰器（decorator），将URL路径与处理函数绑定。

### 2.2 读取URL查询参数

```python
@app.route("/tuijian")
def tuijian():
    sid = request.args.get("id", default=None, type=int)
    # request.args -- URL查询参数集合（query string）
    # .get("id", ...) -- 取名为"id"的参数
    # default=None -- 如果没写id，返回None
    # type=int -- 尝试转为整数
```

访问示例：
- `/tuijian?id=1` --> `sid = 1`
- `/tuijian` --> `sid = None`
- `/tuijian?id=abc` --> `sid = None`（转int失败）

### 2.3 参数校验与错误响应

```python
if sid is None:
    return jsonify({"error": "missing id, example: /tuijian?id=1"}), 400
```

`jsonify({...}), 400` 返回JSON的同时设置HTTP状态码为400（Bad Request）。

## 三、模拟数据库与JSON响应

### 3.1 写死在代码中的模拟数据

```python
RECOMMEND_DB = {
    1: ["小明", "小红", "小刚"],
    2: ["Alice", "Bob"],
    3: ["张三", "李四", "王五"],
}
```

开发初期用字典模拟数据库，后续可替换为CSV、SQLite、模型推理等。

### 3.2 查字典并返回JSON

```python
rec = RECOMMEND_DB.get(sid, [])
# 如果sid存在则返回对应列表，不存在返回空列表[]

return jsonify({
    "student_id": sid,
    "recommend_friends": rec,
    "count": len(rec)
})
```

访问 `/tuijian?id=1` 的返回示例：
```json
{
  "student_id": 1,
  "recommend_friends": ["小明", "小红", "小刚"],
  "count": 3
}
```

## 四、中文JSON乱码解决

### 4.1 问题现象

JSON中的中文被转义为Unicode形式，例如 `"\u5c0f\u660e"` 而不是 `"小明"`。

### 4.2 解决方案

**方案一（推荐，Flask 2.2+）**：
```python
app = Flask(__name__)
app.json.ensure_ascii = False   # 让JSON不进行ASCII转义
```

**方案二（旧版Flask兼容）**：
```python
app = Flask(__name__)
app.config["JSON_AS_ASCII"] = False
```

**方案三（手动dumps，最稳）**：
```python
import json
from flask import Response

data = {"count": 3, "recommend_friends": ["小明","小红"], "student_id": 1}
return Response(
    json.dumps(data, ensure_ascii=False, indent=2),
    mimetype="application/json; charset=utf-8"
)
```

_注意：修改后需要重启服务才能生效（`Ctrl+C`停止，再`python app.py`运行）。_

## 五、从静态数据到GCN模型对接

### 5.1 对接原则

当模型团队（如GCN模块）产出`.pth`文件时，不能将其直接当成推荐结果使用。`.pth`是PyTorch保存的模型权重文件，需要加载到同样结构的模型对象中才能推理。

### 5.2 最小改动版Flask对接骨架

```python
from flask import Flask, request, Response
import json

app = Flask(__name__)
app.json.ensure_ascii = False

# 全局变量：模型推理器（启动时加载一次）
RECOMMENDER = None

def get_recommender():
    global RECOMMENDER
    if RECOMMENDER is None:
        from gcn_infer import GCNRecommender
        RECOMMENDER = GCNRecommender(
            model_path="model.pth",
            users_csv="users.csv",
            edges_csv="edges.csv"
        )
    return RECOMMENDER

@app.route("/tuijian")
def tuijian():
    uid = request.args.get("id", default=None, type=int)
    if uid is None:
        return Response('{"error":"missing id"}',
                        mimetype="application/json; charset=utf-8",
                        status=400)

    rec = get_recommender().recommend(uid, k=3)  # -> [2, 3, 4]

    text = json.dumps({"result": rec}, ensure_ascii=False)
    return Response(text, mimetype="application/json; charset=utf-8")

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
```

^gcn-integration-skeleton

### 5.3 核心变化对比

| 原来 | 现在 |
|------|------|
| `rec = RECOMMEND_DB.get(uid, [])` | `rec = recommender.recommend(uid, k=3)` |

模型在启动时加载一次（`get_recommender()`懒加载），不要每次请求都调用 `torch.load()`，否则会极慢。

### 5.4 模块4最少交付清单

为了让Flask后端对接成功，GCN模型团队（模块4）需要提供：

- `gcn_infer.py`：推理封装文件，包含 `GCNRecommender` 类，提供 `recommend(uid: int, k: int=3) -> list[int]` 方法
- `model.pth`：训练好的权重文件
- 必要的图数据：`users.csv`, `edges.csv` 或 `graph.pt`
- 节点编号约定：uid从0开始还是从1开始（非常重要）

### 5.5 常见对接坑

1. **uid索引偏移**：URL用 `id=1`（1-based），但PyTorch内部可能用0-based索引。模块4推理封装需做好映射。
2. **每次请求都加载模型**：正确做法是启动时加载一次，保持全局单例。

## 六、SQLite数据库集成

### 6.1 Flask-SQLAlchemy配置

```python
import os
from flask import Flask
from flask_sqlalchemy import SQLAlchemy

app = Flask(__name__)

# 数据库连接配置
current_dir = os.path.dirname(os.path.abspath(__file__))
app.config['SQLALCHEMY_DATABASE_URI'] = \
    f'sqlite:///{os.path.join(current_dir, "campus_social.db")}'

# 关闭事件追踪以节省内存
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

# 实例化数据库对象
db = SQLAlchemy(app)
```

^flask-sqlalchemy-config

### 6.2 关键配置解释

- **`SQLALCHEMY_DATABASE_URI`**：数据库连接字符串。`sqlite:///`表示使用SQLite，后面跟文件路径。数据库文件会在程序运行目录下自动创建。
- **`SQLALCHEMY_TRACK_MODIFICATIONS = False`**：官方建议关闭，避免不必要的内存消耗。
- **`db = SQLAlchemy(app)`**：将Flask应用与SQLAlchemy引擎绑定。

### 6.3 ORM的优势

使用ORM（对象关系映射）而非手写SQL的好处：
- **解耦**：从SQLite切换到MySQL只需修改连接字符串（`mysql+pymysql://...`），增删改查代码不变
- **安全**：自动处理SQL注入防御
- **直观**：可以像操作Python对象一样操作数据库记录

`db`对象的三个主要用途：
- 定义模型：`class User(db.Model)` 创建表
- 执行操作：`db.session.add()`, `db.session.commit()`
- 管理表：`db.create_all()` 自动根据代码生成表结构

## 七、完整示例代码

整合以上所有知识点的最小Flask应用：

```python
from flask import Flask, request, jsonify
import json

app = Flask(__name__)
app.json.ensure_ascii = False

RECOMMEND_DB = {
    1: ["小明", "小红", "小刚"],
    2: ["Alice", "Bob"],
    3: ["张三", "李四", "王五"],
}

@app.route("/")
def home():
    return "Flask is running. Try /tuijian?id=1"

@app.route("/tuijian")
def tuijian():
    sid = request.args.get("id", default=None, type=int)
    if sid is None:
        return jsonify({"error": "missing id, example: /tuijian?id=1"}), 400

    rec = RECOMMEND_DB.get(sid, [])
    return jsonify({
        "student_id": sid,
        "recommend_friends": rec,
        "count": len(rec)
    })

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
```

---

## 相关笔记

- [[Python环境管理]] -- 管理Flask运行的Python环境
- [[服务器运维/域名配置]] -- Flask应用的域名与部署配置
