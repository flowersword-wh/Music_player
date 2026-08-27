# Music Player

这是一个基于 HarmonyOS ArkTS 的本地音乐播放器项目，并配套一个 Python 后端，用于从 Bilibili 搜索视频、解析视频音频流，以及下载 Bilibili 音频资源。

## 项目结构

```text
Music_player/
├─ entry/                         # HarmonyOS 播放器客户端
│  └─ src/main/ets/               # ArkTS 页面、播放服务和曲目模型
└─ backend/                       # Python Bilibili 音频后端
   ├─ app.py                      # FastAPI 应用
   ├─ requirements.txt            # Python 依赖
   └─ README.md                   # 后端详细说明
```

## 后端快速启动

Windows PowerShell：

```powershell
cd D:\code\chore\Music_player\backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

启动后可以访问：

```text
http://127.0.0.1:8000/docs
http://127.0.0.1:8000/api/health
```

## API 示例

搜索视频：

```text
GET http://127.0.0.1:8000/api/search?keyword=周杰伦&page=1
```

播放或下载视频音频：

```text
GET http://127.0.0.1:8000/api/videos/BVxxxxxxxxxx/audio?quality=30280
```

前端准备下载时，可以先获取元数据：

```text
GET http://127.0.0.1:8000/api/videos/BVxxxxxxxxxx/audio/metadata?quality=30280
```

随后创建下载记录：

```text
POST http://127.0.0.1:8000/api/downloads
```

下载完成后使用 `PATCH /api/downloads/{id}` 更新状态、进度、本地路径和文件大小。后端不会把 Bilibili 的临时地址暴露给前端，前端始终请求项目自己的 `/api/videos/{bvid}/audio` 地址。

下载 Bilibili 音频资源：

```text
GET http://127.0.0.1:8000/api/audio/777180/download?quality=2
```

视频音频接口会代理 Bilibili 的临时地址，并转发 HTTP Range 请求，因此客户端可以直接把接口地址交给播放器，也可以通过浏览器下载。临时签名 URL 不会写入 SQLite。

## 实现流程

1. `/api/search` 调用 Bilibili WBI 搜索接口，后端自动从导航接口获取每日变化的 `img_key` 和 `sub_key`，生成 `w_rid` 签名。
2. 搜索结果和视频详情写入 SQLite，默认缓存 15 分钟。
3. `/api/videos/{bvid}/audio` 先获取视频详情和 `cid`，再调用播放地址接口读取 DASH 音频轨道。
4. 后端带上 Bilibili 所需的 User-Agent 和 Referer 代理音频流。

## 登录说明

当前版本不需要登录，不提供二维码登录、Cookie 保存或账号密码登录。搜索和公开视频音频下载直接使用匿名接口；如果 Bilibili 后续重新要求认证，再根据实际接口逐项增加最小必要的登录功能。

## 缓存和配置

```powershell
$env:MUSIC_PLAYER_DB="D:\code\chore\Music_player\backend\cache.db"
$env:BILIBILI_CACHE_TTL="900"
$env:CORS_ORIGINS="*"
```

## 系统性测试

离线单元测试：

```powershell
cd D:\code\chore\Music_player\backend
python -m unittest discover -s tests -p "test_*.py" -v
```

离线测试覆盖 WBI 签名、SQLite 缓存、搜索结果处理、DASH 音轨、MP4 回退和参数校验。需要访问 Bilibili 的完整搜索/下载联调测试：

```powershell
python anonymous_search_download_test.py --keyword "音乐"
```

该联调测试默认只下载前 64 KiB，并且不需要登录。

SQLite 还保存搜索历史、播放历史和下载记录。离线系统测试共覆盖缓存读写、历史记录增删改查、搜索结果处理、WBI 签名、DASH 音轨和 MP4 回退：

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
```

生产环境应将 `CORS_ORIGINS` 改为客户端实际地址。

## 合规说明

请仅下载自己拥有使用权或得到授权的内容，并遵守 Bilibili 服务条款、版权要求和适用法律。该项目仅提供技术接口，不绕过会员、付费、地区或其他访问控制。
