# Bilibili 音频后端

该服务为 Music Player 提供匿名的 Bilibili 视频搜索、视频音频播放/下载和 Bilibili 音频资源下载。接口按照项目附带的 `bilibili-API-collect` 文档实现 WBI 签名、视频详情、播放地址和音频流代理。

## 启动

推荐从项目根目录使用一键脚本：

```powershell
.\scripts\start-backend.ps1
```

脚本会自动创建虚拟环境、安装依赖、设置数据库路径和启动服务。

也可以手动启动：

```powershell
cd D:\code\chore\Music_player\backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

如果本机通过 Clash 访问 Bilibili，可以设置代理：

```powershell
$env:BILIBILI_PROXY = "http://127.0.0.1:7890"
```

## 接口

- `GET /api/health`：健康检查。
- `GET /api/search?keyword=周杰伦&page=1`：匿名搜索 B 站视频，不需要登录。
- `GET /api/videos/{bvid}/audio`：解析并代理视频音频，支持 `quality=30216|30232|30280`。
- `GET /api/videos/{bvid}/audio/metadata`：返回前端所需的标题、时长、格式和项目内下载地址，不暴露 Bilibili 临时 URL。
- `GET /api/audio/{sid}/download`：下载 B 站音频资源，支持 `quality=0|1|2|3`。
- `GET /api/history/search`、`DELETE /api/history/search`：查询/清空搜索历史。
- `GET /api/history/play`、`POST /api/history/play`、`DELETE /api/history/play`：查询、记录和清空播放历史。
- `GET /api/downloads`、`GET /api/downloads/{id}`、`POST /api/downloads`、`PATCH /api/downloads/{id}`、`DELETE /api/downloads/{id}`：管理下载记录和状态。
- `GET /api/cache/stats`、`DELETE /api/cache`：查看/清理 Bilibili 接口缓存。

不再需要二维码登录、Cookie 或 `SESSDATA`。客户端可直接把视频音频接口作为播放器 URL 或下载 URL。后端会转发 Range 请求，避免把短时效的 B 站签名地址暴露给客户端。

接口优先返回 DASH 独立音轨；部分视频只有 MP4 混合流，此时会回退下载 MP4 文件，文件中包含可播放音频。

## 匿名联调测试

先运行离线系统测试，测试不会访问网络、不会登录，也不会下载文件：

```powershell
cd D:\code\chore\Music_player\backend
python -m unittest discover -s tests -p "test_*.py" -v
```

该测试覆盖 WBI 签名编码、SQLite 缓存、搜索结果清洗、搜索缓存命中、DASH 音轨选择、MP4 回退以及参数校验。

测试脚本会真实调用 Bilibili 的导航、WBI 搜索、视频详情、播放地址和音频流接口，不需要扫码：

```powershell
cd D:\code\chore\Music_player\backend
python anonymous_search_download_test.py --keyword "音乐"
```

默认只下载前 64 KiB。测试完整下载：

```powershell
python anonymous_search_download_test.py --keyword "音乐" --full --output test.m4a
```

如果结果只有 MP4 混合流，脚本会自动使用 `.mp4` 扩展名。

## 缓存和说明

SQLite 默认文件为 `backend/cache.db`，缓存搜索结果、视频详情和 WBI key，不缓存具有短时效的音频 URL。可通过 `MUSIC_PLAYER_DB`、`BILIBILI_CACHE_TTL` 和 `CORS_ORIGINS` 环境变量调整。

搜索接口每次成功请求都会记录搜索历史；客户端开始播放时应调用 `/api/history/play` 记录歌曲和当前播放位置；下载器创建任务后使用 `/api/downloads/{id}` 更新 `pending`、`downloading`、`completed` 或 `failed` 状态。

## 给前端的下载流程

前端只需要使用后端地址，不需要解析 Bilibili 播放地址：

1. 调用 `GET /api/videos/{bvid}/audio/metadata?quality=30280`，拿到标题、时长、扩展名和 `stream_url`。
2. 调用 `POST /api/downloads` 创建一条 `pending` 下载记录，保存返回的 `id`。
3. 使用 `GET /api/videos/{bvid}/audio?quality=30280` 请求下载流。该接口支持 Range，客户端可以将响应写入应用文件目录。
4. 下载开始后调用 `PATCH /api/downloads/{id}`，将状态改为 `downloading` 并更新 `progress`。
5. 文件写入成功后更新为 `completed`，同时写入 `local_path` 和 `file_size`；失败则更新为 `failed` 和 `error_message`。
6. 应用启动时调用 `GET /api/downloads` 恢复下载记录和已完成文件列表。

元数据响应示例：

```json
{
  "bvid": "BVxxxxxxxxxx",
  "title": "示例视频",
  "duration_ms": 180000,
  "content_type": "audio/mp4",
  "extension": ".m4a",
  "stream_url": "/api/videos/BVxxxxxxxxxx/audio?quality=30280",
  "stream_kind": "dash_audio"
}
```

注意：`stream_url` 是本项目相对地址，前端需要拼接后端基础地址。若 `stream_kind` 为 `mp4_fallback`，下载文件应使用 `.mp4` 扩展名，因为源视频没有独立 DASH 音轨。

本版本已移除所有二维码登录、Cookie 保存、登录状态和搜索登录限制。匿名接口是否可用取决于 Bilibili 当前的风控、视频版权、地区和资源权限；如果未来接口重新要求登录，再单独恢复最小必要的认证能力。

请仅下载自己拥有使用权或得到授权的内容，并遵守 Bilibili 服务条款及版权要求。
