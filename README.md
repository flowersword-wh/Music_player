# Music Player

一个基于 HarmonyOS ArkTS 的音乐播放器示例项目，包含 HarmonyOS 客户端和 FastAPI 后端两部分。

客户端用于导入、管理和播放本地音频，也可以通过后端搜索 Bilibili 视频、在线播放或下载音频；后端负责匿名请求 Bilibili、缓存接口数据、代理音频流，以及保存搜索历史、播放历史和下载记录。

> 项目当前面向开发和演示场景。Bilibili 接口、风控和资源权限可能随时变化。

## 功能

- 导入并播放本地音频文件
- 播放、暂停、上一首、下一首和音量控制
- 播放列表循环、单曲循环和随机播放
- 播放列表滚动与当前歌曲高亮
- Bilibili 视频搜索，无需用户扫码登录
- Bilibili 音频在线播放和下载
- 下载记录及 `pending`、`downloading`、`paused`、`completed`、`failed` 状态管理
- 搜索历史、播放历史和 SQLite 缓存
- 统计页：本地歌曲数量、总时长、当前歌曲和最近导入内容
- 后端代理临时音频 URL，客户端不直接保存 Bilibili 签名地址

## 技术栈

| 部分 | 技术 |
| --- | --- |
| 客户端 | HarmonyOS、ArkTS、ArkUI、AVPlayer、NetworkKit |
| 后端 | Python 3.10+、FastAPI、Uvicorn、SQLite |
| 外部服务 | Bilibili 公开接口 |
| 构建工具 | DevEco Studio、Hvigor |

## 项目结构

```text
Music_player/
├─ AppScope/                              # 应用级配置和资源
├─ entry/                                 # HarmonyOS 客户端模块
│  └─ src/main/
│     ├─ ets/
│     │  ├─ common/AudioService.ets       # AVPlayer 播放服务
│     │  ├─ common/BilibiliApiService.ets # 后端 API 客户端
│     │  ├─ model/Track.ets               # 歌曲模型
│     │  ├─ pages/MusicPlayerPage.ets     # 播放、搜索和统计页面
│     │  └─ view/                         # 播放列表和视觉组件
│     └─ module.json5                     # 模块、设备和网络权限
├─ backend/                               # FastAPI 后端
│  ├─ app.py                              # API、Bilibili 代理和 SQLite
│  ├─ requirements.txt                    # Python 依赖
│  ├─ tests/test_backend.py               # 离线单元测试
│  └─ anonymous_search_download_test.py   # 在线联调测试
├─ scripts/start-backend.ps1              # Windows 后端启动脚本
├─ build-profile.json5                   # HarmonyOS 构建配置
└─ README.md
```

## 环境要求

- DevEco Studio，以及与 `build-profile.json5` 匹配的 HarmonyOS SDK
- Python 3.10 或更高版本
- Windows PowerShell（用于运行项目提供的启动脚本）
- 能访问 Bilibili 的网络环境；如使用本机 Clash，脚本默认代理为 `http://127.0.0.1:7890`

## 启动后端

在项目根目录执行：

```powershell
.\scripts\start-backend.ps1
```

脚本会自动创建 `backend/.venv`、安装 `backend/requirements.txt` 中的依赖，并在 `0.0.0.0:8000` 启动服务。数据库默认使用项目根目录的 `cache.db`。

常用参数：

```powershell
# 强制重新安装依赖
.\scripts\start-backend.ps1 -Install

# 指定代理；不需要代理时传空字符串
.\scripts\start-backend.ps1 -Proxy "http://127.0.0.1:7890"
.\scripts\start-backend.ps1 -Proxy ""

# 修改监听端口
.\scripts\start-backend.ps1 -Port 9000
```

启动后可以检查：

```text
健康检查：http://127.0.0.1:8000/api/health
Swagger：http://127.0.0.1:8000/docs
```

手动启动方式和后端接口说明见 [`backend/README.md`](backend/README.md)。

## 运行客户端

1. 使用 DevEco Studio 打开项目根目录。
2. 等待依赖、索引和 HarmonyOS SDK 加载完成。
3. 启动上面的 Python 后端。
4. 选择 HarmonyOS 模拟器或真机运行 `entry` 模块。

客户端默认连接 `http://10.0.2.2:8000`，这是模拟器访问宿主机的常用地址。使用真机时，需要将 [`BilibiliApiService.ets`](entry/src/main/ets/common/BilibiliApiService.ets) 构造函数中的地址改为电脑的局域网 IP，例如 `http://192.168.1.10:8000`，并确保电脑防火墙放行对应端口。

客户端需要的网络权限已在 [`module.json5`](entry/src/main/module.json5) 中声明：`ohos.permission.INTERNET`。

## API 概览

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查 |
| GET | `/api/search?keyword=music&page=1` | 搜索 Bilibili 视频 |
| GET | `/api/videos/{bvid}/audio/metadata?quality=30280` | 获取音频元数据和项目内流地址 |
| GET | `/api/videos/{bvid}/audio?quality=30280` | 代理视频音频流，支持 Range |
| GET | `/api/audio/{sid}/download?quality=2` | 获取 Bilibili 音频资源 |
| GET/DELETE | `/api/history/search` | 搜索历史 |
| POST/GET/DELETE | `/api/history/play` | 播放历史 |
| POST/GET/PATCH/DELETE | `/api/downloads`、`/api/downloads/{id}` | 下载记录 |
| GET/DELETE | `/api/cache`、`/api/cache/stats` | 缓存查看和清理 |

音频接口会优先选择 DASH 独立音轨；如果视频没有可用的独立音轨，则回退到包含音频的 MP4 混合流。客户端只需要请求项目后端地址，不需要解析或保存 Bilibili 临时签名 URL。

## 配置

后端支持以下环境变量：

```powershell
$env:MUSIC_PLAYER_DB = "D:\code\chore\Music_player\cache.db"
$env:BILIBILI_PROXY = "http://127.0.0.1:7890"
$env:BILIBILI_CACHE_TTL = "900"
$env:BILIBILI_USER_AGENT = "Mozilla/5.0 ..."
$env:CORS_ORIGINS = "*"
```

其中 `BILIBILI_PROXY` 为空字符串时禁用代理。`MUSIC_PLAYER_DB` 未设置时，直接从 `backend` 目录启动会使用 `backend/cache.db`；使用项目提供的脚本启动时，脚本会显式将其设置为根目录的 `cache.db`。

## 测试

离线单元测试不会访问网络、登录 Bilibili 或下载文件：

```powershell
cd .\backend
.\.venv\Scripts\python.exe -m unittest discover -s tests -p "test_*.py" -v
```

如果尚未创建虚拟环境，也可以使用当前 Python：

```powershell
cd .\backend
python -m unittest discover -s tests -p "test_*.py" -v
```

在线联调测试会真实访问 Bilibili，并默认只下载少量数据：

```powershell
cd .\backend
.\.venv\Scripts\python.exe anonymous_search_download_test.py --keyword "music"
```

完整下载联调数据时可增加 `--full --output test.m4a`。联调测试需要网络连接，不需要扫码登录。

## 数据、生成文件与 Git

后端首次运行时会自动创建 SQLite 表，用于保存缓存、搜索历史、播放历史和下载记录。`cache.db`、`backend/.venv`、构建输出和测试生成的音频文件均属于运行产物，不应提交到 Git。

## 合规说明

请仅下载自己拥有使用权或已获得授权的内容，并遵守 Bilibili 服务条款、版权要求和适用法律。本项目不绕过会员、付费、地区或其他访问控制；匿名接口能否使用取决于 Bilibili 当前的风控、版权和资源权限。
