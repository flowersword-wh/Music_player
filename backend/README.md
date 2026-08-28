# Music Player Bilibili 后端

这是 Music Player 的 FastAPI 后端，提供 Bilibili 匿名搜索、视频音频元数据、音频流代理，以及搜索历史、播放历史、下载记录和接口缓存管理。

后端会使用匿名 Cookie、统一的 User-Agent 和 Referer 请求 Bilibili，并在需要时完成 WBI 相关处理。Bilibili 的短时效签名 URL 不会直接返回给客户端，而是由后端代理音频请求。

## 安装与启动

推荐从项目根目录启动：

```powershell
.\scripts\start-backend.ps1
```

手动启动：

```powershell
cd D:\code\chore\Music_player\backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8000
```

本机通过 Clash 访问 Bilibili 时：

```powershell
$env:BILIBILI_PROXY = "http://127.0.0.1:7890"
```

启动后访问 `http://127.0.0.1:8000/docs` 查看 Swagger 文档，访问 `/api/health` 可做健康检查。

## 接口

- `GET /api/health`：健康检查。
- `GET /api/search?keyword=周杰伦&page=1`：匿名搜索 Bilibili 视频。
- `GET /api/videos/{bvid}/audio/metadata?quality=30280`：返回标题、时长、扩展名和项目内流地址。
- `GET /api/videos/{bvid}/audio?quality=30280`：代理视频音频，支持客户端 Range 请求。
- `GET /api/audio/{sid}/download?quality=2`：代理 Bilibili 音频资源。
- `GET/DELETE /api/history/search`：查询或清空搜索历史。
- `POST/GET/DELETE /api/history/play`：记录、查询或清空播放历史。
- `POST/GET/PATCH/DELETE /api/downloads` 和 `/api/downloads/{id}`：管理下载记录。
- `GET/DELETE /api/cache/stats` 和 `/api/cache`：查看或清理接口缓存。

视频音频解析优先返回 DASH 独立音轨（`.m4a`）；部分视频只有包含音频的 MP4 混合流，此时会回退为 `.mp4`。请求参数支持的音频质量为 `30216`、`30232`、`30280`，后端会选择最接近的可用音轨。

## 下载流程

前端不需要解析 Bilibili 播放地址：

1. 调用 `GET /api/videos/{bvid}/audio/metadata?quality=30280` 获取元数据。
2. 调用 `POST /api/downloads` 创建 `pending` 记录，并保存返回的 `id`。
3. 请求 `GET /api/videos/{bvid}/audio?quality=30280`，将响应写入客户端文件目录。
4. 下载过程中调用 `PATCH /api/downloads/{id}` 更新 `status` 和 `progress`。
5. 成功时更新为 `completed`，写入 `local_path` 和 `file_size`；失败时更新为 `failed` 和 `error_message`。
6. 应用启动时调用 `GET /api/downloads` 恢复记录。

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

当 `stream_kind` 为 `mp4_fallback` 时，保存文件应使用 `.mp4` 扩展名。

## 配置与数据库

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MUSIC_PLAYER_DB` | `backend/cache.db` | SQLite 数据库路径 |
| `BILIBILI_PROXY` | `http://127.0.0.1:7890` | Bilibili HTTP/HTTPS 代理，空字符串表示禁用 |
| `BILIBILI_CACHE_TTL` | `900` | 普通缓存有效期，单位为秒 |
| `BILIBILI_USER_AGENT` | 内置浏览器 UA | 对 Bilibili 请求使用的 User-Agent |
| `CORS_ORIGINS` | `*` | 允许的 CORS 来源，多个来源用逗号分隔 |

项目根目录的 `scripts/start-backend.ps1` 会将 `MUSIC_PLAYER_DB` 设置为根目录的 `cache.db`，因此推荐统一从根目录启动。

SQLite 表会在首次访问接口时自动创建：`cache`、`search_history`、`play_history` 和 `downloads`。

## 测试

离线单元测试：

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
```

测试覆盖查询编码、WBI 签名、SQLite 缓存、搜索结果清洗、DASH 音轨选择、MP4 回退、参数校验、播放历史、下载记录和缓存管理。

在线联调测试：

```powershell
python anonymous_search_download_test.py --keyword "音乐"
```

默认只下载前 64 KiB；验证完整文件时：

```powershell
python anonymous_search_download_test.py --keyword "音乐" --full --output test.m4a
```

在线测试需要能访问 Bilibili，但不需要二维码、账号 Cookie 或 `SESSDATA`。接口是否可用仍取决于 Bilibili 当前风控、版权、地区和资源权限。

## 合规说明

请仅下载自己拥有使用权或已获得授权的内容，并遵守 Bilibili 服务条款、版权要求和适用法律。本项目不绕过会员、付费、地区或其他访问控制。
