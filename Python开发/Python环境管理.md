# Python环境管理

## 一、Conda环境创建与管理

### 1.1 创建conda环境

```bash
conda create -n 环境名 python=版本号
```

示例：
```bash
conda create -n myproject python=3.10
```

### 1.2 激活与退出环境

```bash
# 激活环境（需要重开终端或在当前终端执行）
conda activate 环境名

# 退出当前环境
conda deactivate
```

^conda-create

## 二、虚拟环境与requirements.txt

### 2.1 使用venv创建虚拟环境

在项目文件夹根目录执行：

```bash
# 创建名为venv的虚拟环境文件夹
python -m venv venv
```

激活虚拟环境：
- **Windows**：`.\venv\Scripts\activate`
- **macOS/Linux**：`source venv/bin/activate`

激活成功后命令行提示符前会出现`(venv)`字样。之后安装的所有库都只属于该项目，不会污染全局环境。

### 2.2 生成requirements.txt

确保虚拟环境已激活后：

```bash
pip freeze > requirements.txt
```

^pip-freeze

命令解释：
- `pip freeze` -- 列出当前环境中所有已安装的第三方库及其精确版本号
- `>` -- 重定向符号，将输出写入文件
- `requirements.txt` -- 目标文件名

生成的文件内容示例：
```
beautifulsoup4==4.12.3
certifi==2024.6.2
charset-normalizer==3.3.2
idna==3.7
lxml==5.2.2
requests==2.32.3
soupsieve==2.5
urllib3==2.2.1
```

### 2.3 从requirements.txt安装依赖

```bash
pip install -r requirements.txt
```

### 2.4 项目部署流程

在一台新服务器上部署Python项目的完整流程：

```
阶段一：本地准备
  1. 在虚拟环境中开发
  2. pip freeze > requirements.txt
  3. 打包项目为 .zip

阶段二：服务器部署
  1. 创建Python项目容器（如宝塔面板）
  2. 上传并解压 .zip
  3. 在项目依赖管理中点击安装依赖包

阶段三：设置自动化
  1. 创建Shell脚本定时任务
  2. 使用虚拟环境的绝对路径执行
```

^deploy-flow

宝塔面板定时任务Shell脚本模板：
```bash
#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# 使用项目虚拟环境中的python执行脚本
# >> 将输出追加到日志文件，2>&1 同时捕获错误输出
/www/wwwroot/bili-scraper/pyenv/bin/python \
  /www/wwwroot/bili-scraper/main.py \
  >> /www/wwwroot/bili-scraper/run.log 2>&1
```

_注意：必须使用绝对路径，否则cron环境中可能找不到程序。_

## 三、查找系统中的Python安装位置

### 3.1 Windows上查找Python

**招式一：使用 where 命令**
```cmd
where python
```

输出示例：
```
C:\Users\用户名\AppData\Local\Programs\Python\Python313\python.exe
C:\Python39\python.exe
C:\Users\用户名\AppData\Local\Microsoft\WindowsApps\python.exe
```

**招式二：检查环境变量Path**
在Windows搜索栏输入"环境变量" --> "编辑系统环境变量" --> "环境变量..." --> 找到`Path`变量编辑，找出所有包含`Python`或`Scripts`的路径。

**招式三：地毯式搜索常见藏身点**
- `C:\Users\用户名\AppData\Local\Programs\`
- `C:\Python39`、`C:\Python310`等
- `C:\Program Files`和`C:\Program Files (x86)`中可能存在的Python文件夹

^find-python-windows

### 3.2 彻底清理旧Python环境

完整步骤：
1. 对照名单在"添加或删除程序"中卸载所有Python版本
2. 手动删除所有找到的Python文件夹
3. 在环境变量Path中删除所有Python相关路径
4. 重启电脑确保生效
5. 从官网下载新版Python，勾选"Add to PATH"进行干净安装

## 四、IDE安装：PyCharm

### 4.1 Snap安装（官方推荐，最简单）

```bash
# 社区版（免费）
sudo snap install pycharm-community --classic

# 专业版（付费）
sudo snap install pycharm-professional --classic
```

优点：一条命令搞定安装、自动更新和桌面图标。

### 4.2 JetBrains Toolbox安装（图形化管理）

适合需要同时管理多个JetBrains产品的用户。从官方页面下载`.tar.gz`，解压后运行`jetbrains-toolbox`程序，在图形界面中安装PyCharm。

### 4.3 手动安装 .tar.gz 文件

PyCharm的`.tar.gz`包是已编译好的程序文件，不是源代码，不需要`./configure`和`make`步骤。

**步骤1：解压到 `/opt` 目录**
```bash
cd ~/下载
sudo tar -zxvf pycharm-community-*.tar.gz -C /opt/
```

**步骤2：运行启动脚本**
```bash
/opt/pycharm-community-*/bin/pycharm.sh
```

**步骤3：创建桌面快捷方式**
在PyCharm主界面菜单中：`Tools -> Create Desktop Entry...`，勾选"Create a desktop entry for all users"。

**步骤4（可选）：创建命令行启动命令**
```bash
sudo ln -s /opt/pycharm-community-*/bin/pycharm.sh /usr/local/bin/pycharm
```
之后在任何终端输入`pycharm`即可启动。

^pycharm-install

| 安装方式 | 优点 | 缺点 |
|----------|------|------|
| Snap | 一条命令搞定；自动更新 | 占用磁盘空间稍大；首次启动可能稍慢 |
| Toolbox | 图形化界面；管理多个工具 | 需要后台管理程序常驻 |
| .tar.gz | 完全手动控制；绿色免安装 | 不会自动更新；过程繁琐 |

## 五、Ubuntu系统管理

### 5.1 apt更新慢的解决方案：更换国内镜像源

```bash
# 备份原有源文件
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

# 更换为阿里云镜像（香港服务器访问极快）
sudo sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 备选：腾讯云镜像
# sudo sed -i 's/archive.ubuntu.com/mirrors.tencentyun.com/g' /etc/apt/sources.list

# 更新软件列表
sudo apt update
```

### 5.2 apt的update与upgrade区别

- `sudo apt update` -- 只更新可下载软件包的**列表**，下载量小、速度快
- `sudo apt upgrade` -- 根据列表下载并安装所有需要更新的软件包，**耗时长**
- 如果不关心安全补丁，可以只`update`后直接`install`所需软件

### 5.3 给已安装的Ubuntu扩容

核心思路：**在Windows里"割地" --> 用U盘启动Ubuntu"收复疆土"**

**第一阶段（Windows端）：**
1. 进入磁盘管理（`Win+X` -> "磁盘管理"）
2. 在C盘上右键 --> "压缩卷"
3. 输入要释放的空间量（如51200 MB = 50GB）
4. 完成后出现"未分配"空间，**不要格式化**

**第二阶段（Ubuntu启动U盘）：**
1. 插入Ubuntu安装U盘，启动时选择 "Try Ubuntu"
2. 安装并打开GParted：
   ```bash
   sudo apt update
   sudo apt install gparted
   ```
3. 在GParted中找到灰色的"未分配"空间（unallocated）
4. 确保其紧邻Ubuntu分区（ext4格式）
5. 右键Ubuntu分区 --> "更改大小/移动"，拖动边缘"吃掉"未分配空间
6. 点击绿色对勾"✓"应用更改

**第三阶段：** 重启电脑并拔掉U盘，正常进入Ubuntu验证。

_警告：分区操作有数据丢失风险，务必提前备份重要数据！_

### 5.4 安装.deb软件包的通用公式：黄金安装组合拳

当直接安装`.deb`文件遇到依赖错误时：

```bash
# 第一步：用dpkg强行安装（这一步报错是正常的）
sudo dpkg -i 软件名*.deb

# 第二步：让系统自动修复所有缺失的依赖
sudo apt --fix-broken install
```

适用于QQ、搜狗输入法等各种`.deb`格式软件。也可以直接用`apt`安装本地文件（推荐）：
```bash
sudo apt install ./文件名.deb
```
其中`./`表示当前目录，不能省略。

### 5.5 dpkg状态数据库锁定问题

**错误信息**：`dpkg: error: dpkg status database is locked by another process`

**原因**：系统后台正在自动检查更新，或者有其他软件管理器进程正在运行。

**解决方案**：

首选 -- 等待并关闭图形化软件管理器：
```bash
# 查找正在占用软件管理器的进程
ps aux | grep -i apt
ps aux | grep -i dpkg

# 结束进程（替换1234为实际PID）
sudo kill 1234
```

强制解锁（最后手段）：
```bash
sudo rm /var/lib/dpkg/lock
sudo rm /var/lib/dpkg/lock-frontend
sudo dpkg --configure -a
```

### 5.6 彻底卸载搜狗输入法

**第一步：查找并卸载软件包**
```bash
# 找到搜狗输入法的包名
dpkg -l | grep -i sogou

# 彻底卸载（purge同时删除全局配置文件）
sudo apt purge sogoupinyin

# 自动移除不再需要的依赖
sudo apt autoremove
```

**第二步：删除用户配置文件**
```bash
rm -rf ~/.config/SogouPY
rm -rf ~/.config/SogouPY.users
rm -rf ~/.config/sogou-qimpanel
```

**第三步：处理Fcitx框架**

如果只为搜狗安装了Fcitx，可一并卸载：
```bash
sudo apt purge fcitx*
```

**第四步：切换回IBus框架**
- 图形界面：设置 -> 区域与语言 -> 管理已安装的语言 -> 键盘输入法系统改为"IBus"
- 命令行：执行`im-config`，在对话框中选择"IBus"

**第五步：重启系统使更改生效。**

^uninstall-sogou

### 5.7 SSH命令不执行的常见原因

**错误命令**：
```bash
ssh -D 8080 -J root@47.117.103.134,root@88.209.243.252 -N
```

**问题**：`-J`指定了跳板机，但缺少最终目标主机（destination host）。

**正确格式**：
```bash
ssh -D 8080 -J root@47.117.103.134,root@88.209.243.252 -N user@final-destination-server
```

命令解析：
- `-D 8080` -- 本地8080端口创建SOCKS代理
- `-J host1,host2` -- 依次通过跳板机连接
- `-N` -- 不执行远程命令（端口转发专用）
- `user@final-destination-server` -- 最终目标

---

## 相关笔记

- [[Flask框架入门]] -- Flask应用的运行环境配置
- [[服务器运维/SSH配置与远程连接]] -- SSH连接与远程服务器管理
