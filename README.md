# Music Player

一个基于 HarmonyOS ArkTS 的本地音乐播放器，配套 FastAPI Python 后端。客户端负责本地音频导入、播放列表、播放控制、搜索页和统计页；后端负责 Bilibili 匿名搜索、视频音频流代理、下载记录和历史记录。

## 功能概览

- 本地音频选择、播放、暂停、上一首、下一首
- 播放列表循环、顺序播放、单曲循环和随机播放
- 可上下滑动的播放列表，当前歌曲居中高亮
- Bilibili 匿名视频搜索
- 统计页：本地音频数量、已知总时长、当前歌曲和最近导入列表
- Python 后端缓存、搜索历史、播放历史和下载记录
- 通过项目自己的音频代理地址播放，避免把 Bilibili 临时签名地址直接交给客户端

## 项目结构

```text
Music_player/
├─ AppScope/                         # 应用级配置
├─ entry/                            # HarmonyOS 客户端
│  └─ src/main/ets/
│     ├─ pages/MusicPlayerPage.ets  # 首页、搜索页、统计页
│     ├─ common/AudioService.ets    # AVPlayer 播放服务
│     ├─ common/BilibiliApiService.ets
│     ├─ model/Track.ets
│     └─ view/                       # 播放列表和视觉组件
├─ backend/                          # FastAPI Python 后端
│  ├─ app.py
│  ├─ requirements.txt
│  ├─ anonymous_search_download_test.py
│  └─ tests/
├─ scripts/start-backend.ps1        # Windows 一键启动后端
└─ README.md
```

## 环境要求

- DevEco Studio 和 HarmonyOS SDK
- Python 3.10 或更高版本
- Windows PowerShell
- 如需访问 Bilibili，网络环境需要能够访问 Bilibili；本机使用 Clash 时，脚本默认使用 `127.0.0.1:7890`

## 一键启动 Python 后端

在项目根目录执行：

```powershell
.\scripts\start-backend.ps1
```

脚本会自动创建 `backend/.venv`、安装依赖、使用项目根目录的 `cache.db`，然后启动 `http://0.0.0.0:8000`。

常用参数：

```powershell
# 强制重新安装依赖
.\scripts\start-backend.ps1 -Install

# 指定代理；不需要代理时传空字符串
.\scripts\start-backend.ps1 -Proxy "http://127.0.0.1:7890"
.\scripts\start-backend.ps1 -Proxy ""

# 使用其他端口
.\scripts\start-backend.ps1 -Port 9000
```

启动后可访问：

```text
http://127.0.0.1:8000/docs
http://127.0.0.1:8000/api/health
```

HarmonyOS 模拟器默认访问 `http://10.0.2.2:8000`。真机需要把 `entry/src/main/ets/common/BilibiliApiService.ets` 中的地址改为电脑局域网 IP，并确保防火墙允许端口访问。

## 客户端运行

1. 使用 DevEco Studio 打开项目根目录。
2. 等待依赖和 SDK 索引完成。
3. 先启动 Python 后端。
4. 选择 HarmonyOS 模拟器或真机。
5. 运行 `entry` 模块。

客户端底部有三个页面：

- 首页：导入并播放本地音频
- 搜索：搜索 Bilibili 视频
- 统计：查看本地播放列表概览

## API 概览

```text
GET    /api/health
GET    /api/search?keyword=music&page=1
GET    /api/videos/{bvid}/audio/metadata?quality=30280
GET    /api/videos/{bvid}/audio?quality=30280
GET    /api/audio/{sid}/download?quality=2
POST   /api/history/play
GET    /api/history/play
GET    /api/history/search
POST   /api/downloads
GET    /api/downloads
PATCH  /api/downloads/{id}
DELETE /api/downloads/{id}
```

搜索接口使用当前可用的匿名公开搜索入口，并由后端统一设置 User-Agent、Referer 和匿名 Cookie。视频音频地址由后端解析和代理，客户端不保存 Bilibili 临时签名 URL。

## 配置项

```powershell
$env:MUSIC_PLAYER_DB="D:\code\chore\Music_player\cache.db"
$env:BILIBILI_PROXY="http://127.0.0.1:7890"
$env:BILIBILI_CACHE_TTL="900"
$env:CORS_ORIGINS="*"
```

## 测试

运行 Python 后端离线单元测试：

```powershell
cd .\backend
.\.venv\Scripts\python.exe -m unittest discover -s tests -p "test_*.py" -v
```

运行 Bilibili 匿名搜索/下载联调测试：

```powershell
cd .\backend
.\.venv\Scripts\python.exe anonymous_search_download_test.py --keyword "music"
```

联调测试需要网络连接，默认只下载少量数据用于验证，不需要登录。

## 数据和缓存

后端默认将 SQLite 数据库写入项目根目录 `cache.db`，用于保存搜索缓存、搜索历史、播放历史和下载记录。数据库、构建目录、虚拟环境和测试生成文件均不应提交到 Git。

## 合规说明

请仅下载自己拥有使用权或得到授权的内容，并遵守 Bilibili 服务条款、版权要求和适用法律。本项目不绕过会员、付费、地区或其他访问控制。
