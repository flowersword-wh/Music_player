"""Small FastAPI backend for Bilibili search and audio streaming.

The backend deliberately proxies media instead of returning Bilibili's signed
URLs. Those URLs expire and may require the Bilibili Referer header.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import time
from collections.abc import Iterator
from contextlib import closing
from http.cookiejar import CookieJar
from typing import Any
from urllib.parse import quote, urlencode
from urllib.request import HTTPCookieProcessor, ProxyHandler, Request, build_opener, urlopen

from fastapi import Body, FastAPI, HTTPException, Query, Request as FastAPIRequest
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

API = "https://api.bilibili.com"
USER_AGENT = os.getenv(
    "BILIBILI_USER_AGENT",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "Chrome/124.0 Safari/537.36",
)
DB_PATH = os.getenv("MUSIC_PLAYER_DB", os.path.join(os.path.dirname(__file__), "cache.db"))
CACHE_TTL = int(os.getenv("BILIBILI_CACHE_TTL", "900"))
BILIBILI_COOKIES = CookieJar()
BILIBILI_PROXY = os.getenv("BILIBILI_PROXY", "http://127.0.0.1:7890").strip()
BILIBILI_PROXY_HANDLER = ProxyHandler(
    {"http": BILIBILI_PROXY, "https": BILIBILI_PROXY} if BILIBILI_PROXY else {}
)
BILIBILI_OPENER = build_opener(BILIBILI_PROXY_HANDLER, HTTPCookieProcessor(BILIBILI_COOKIES))
COOKIE_BOOTSTRAPPED = False

MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
]

app = FastAPI(title="Music Player Bilibili Backend", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("CORS_ORIGINS", "*").split(","),
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["*"],
)


def db() -> sqlite3.Connection:
    connection = sqlite3.connect(DB_PATH)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute(
        """CREATE TABLE IF NOT EXISTS cache (
            cache_key TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            expires_at INTEGER NOT NULL
        )"""
    )
    connection.execute(
        """CREATE TABLE IF NOT EXISTS search_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword TEXT NOT NULL,
            page INTEGER NOT NULL DEFAULT 1,
            result_count INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        )"""
    )
    connection.execute(
        """CREATE TABLE IF NOT EXISTS play_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bvid TEXT,
            title TEXT NOT NULL,
            uri TEXT,
            position_ms INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT -1,
            played_at INTEGER NOT NULL
        )"""
    )
    connection.execute(
        """CREATE TABLE IF NOT EXISTS downloads (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bvid TEXT,
            title TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            progress INTEGER NOT NULL DEFAULT 0,
            local_path TEXT,
            file_size INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )"""
    )
    connection.execute("CREATE INDEX IF NOT EXISTS idx_cache_expires ON cache(expires_at)")
    connection.execute("CREATE INDEX IF NOT EXISTS idx_search_history_created ON search_history(created_at DESC)")
    connection.execute("CREATE INDEX IF NOT EXISTS idx_play_history_played ON play_history(played_at DESC)")
    connection.execute("CREATE INDEX IF NOT EXISTS idx_downloads_updated ON downloads(updated_at DESC)")
    connection.commit()
    return connection


def cache_get(key: str) -> Any | None:
    with closing(db()) as connection:
        row = connection.execute(
            "SELECT payload FROM cache WHERE cache_key = ? AND expires_at > ?",
            (key, int(time.time())),
        ).fetchone()
    return json.loads(row["payload"]) if row else None


def cache_put(key: str, value: Any, ttl: int = CACHE_TTL) -> None:
    with closing(db()) as connection:
        connection.execute(
            "INSERT OR REPLACE INTO cache(cache_key, payload, expires_at) VALUES (?, ?, ?)",
            (key, json.dumps(value, ensure_ascii=False), int(time.time()) + ttl),
        )
        connection.commit()


def record_search(keyword: str, page: int, result_count: int) -> None:
    with closing(db()) as connection:
        connection.execute(
            "INSERT INTO search_history(keyword, page, result_count, created_at) VALUES (?, ?, ?, ?)",
            (keyword, page, result_count, int(time.time())),
        )
        connection.commit()


def limit_value(value: int, default: int = 50, maximum: int = 200) -> int:
    return max(1, min(value or default, maximum))


def bootstrap_bilibili_cookies() -> None:
    """Obtain anonymous web cookies required by Bilibili search, including buvid3."""
    global COOKIE_BOOTSTRAPPED
    if COOKIE_BOOTSTRAPPED:
        return
    request = Request(
        "https://www.bilibili.com/",
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
    )
    try:
        with BILIBILI_OPENER.open(request, timeout=20) as response:
            response.read(1024)
        if not any(cookie.name == "buvid3" for cookie in BILIBILI_COOKIES):
            raise HTTPException(status_code=502, detail="Bilibili did not issue required anonymous buvid3 cookie")
        COOKIE_BOOTSTRAPPED = True
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Bilibili cookie bootstrap failed: {exc}") from exc


def bilibili_request(path: str, params: dict[str, Any], *, signed: bool = False) -> dict[str, Any]:
    bootstrap_bilibili_cookies()
    request_params = {key: value for key, value in params.items() if value is not None}
    if signed:
        img_key, sub_key = get_wbi_keys()
        request_params = sign_wbi(request_params, img_key, sub_key)
    query = encode_query(request_params)
    headers = {"User-Agent": USER_AGENT, "Referer": "https://www.bilibili.com/"}
    request = Request(f"{API}{path}?{query}", headers=headers)
    try:
        with BILIBILI_OPENER.open(request, timeout=20) as response:
            body = json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Bilibili request failed: {exc}") from exc
    if body.get("code", 0) != 0:
        raise HTTPException(status_code=502, detail=body.get("message") or body.get("msg") or "Bilibili API error")
    return body


def get_wbi_keys() -> tuple[str, str]:
    cached = cache_get("wbi_keys")
    if cached:
        return cached["img_key"], cached["sub_key"]
    body = bilibili_request("/x/web-interface/nav", {}, signed=False)
    images = body.get("data", {}).get("wbi_img", {})
    img_url, sub_url = images.get("img_url"), images.get("sub_url")
    if not img_url or not sub_url:
        raise HTTPException(status_code=502, detail="Bilibili WBI keys unavailable")
    result = {
        "img_key": img_url.rsplit("/", 1)[-1].split(".", 1)[0],
        "sub_key": sub_url.rsplit("/", 1)[-1].split(".", 1)[0],
    }
    cache_put("wbi_keys", result, 24 * 60 * 60)
    return result["img_key"], result["sub_key"]


def sign_wbi(params: dict[str, Any], img_key: str, sub_key: str) -> dict[str, Any]:
    mixin = "".join((img_key + sub_key)[index] for index in MIXIN_KEY_ENC_TAB)[:32]
    signed = {key: re.sub(r"[!'()*]", "", str(value)) for key, value in params.items()}
    signed["wts"] = str(int(time.time()))
    canonical = encode_query(dict(sorted(signed.items())))
    signed["w_rid"] = hashlib.md5((canonical + mixin).encode()).hexdigest()
    return signed


def encode_query(params: dict[str, Any]) -> str:
    """Encode like JavaScript encodeURIComponent (WBI requires %20, not +)."""
    return "&".join(f"{quote(str(key), safe='')}={quote(str(value), safe='')}" for key, value in params.items())


def normalize_search_item(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "video",
        "bvid": item.get("bvid"),
        "aid": item.get("aid"),
        "title": re.sub(r"<[^>]+>", "", item.get("title", "")),
        "author": item.get("author", ""),
        "description": re.sub(r"<[^>]+>", "", item.get("description", "")),
        "cover": item.get("pic", ""),
        "duration": item.get("duration", ""),
        "play": item.get("play", 0),
        "pubdate": item.get("pubdate", 0),
        "url": f"https://www.bilibili.com/video/{item.get('bvid')}" if item.get("bvid") else None,
    }


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/search")
def search(
    keyword: str = Query(..., min_length=1, max_length=100),
    page: int = Query(1, ge=1, le=50),
    order: str = Query("totalrank", pattern="^(totalrank|click|pubdate|dm|stow|scores)$"),
) -> dict[str, Any]:
    cache_key = f"search:{keyword}:{page}:{order}"
    cached = cache_get(cache_key)
    if cached:
        record_search(keyword, page, len(cached.get("items", [])))
        return cached
    body = bilibili_request(
        # The WBI search endpoint currently returns “账号未登录” for an
        # anonymous buvid3 session. The legacy endpoint remains available
        # for public video search and does not require account credentials.
        "/x/web-interface/search/type",
        {"search_type": "video", "keyword": keyword, "order": order, "duration": 0, "tids": 0, "page": page},
        signed=False,
    )
    data = body.get("data") or {}
    result = {
        "keyword": keyword,
        "page": data.get("page", page),
        "page_size": data.get("pagesize", 20),
        "total": data.get("numResults", 0),
        "pages": data.get("numPages", 0),
        "items": [normalize_search_item(item) for item in (data.get("result") or [])],
    }
    cache_put(cache_key, result)
    record_search(keyword, page, len(result["items"]))
    return result


@app.get("/api/history/search")
def search_history(limit: int = Query(50, ge=1, le=200)) -> dict[str, Any]:
    with closing(db()) as connection:
        rows = connection.execute(
            "SELECT id, keyword, page, result_count, created_at FROM search_history ORDER BY created_at DESC, id DESC LIMIT ?",
            (limit_value(limit),),
        ).fetchall()
    return {"items": [dict(row) for row in rows]}


@app.delete("/api/history/search")
def clear_search_history() -> dict[str, int]:
    with closing(db()) as connection:
        result = connection.execute("DELETE FROM search_history")
        connection.commit()
    return {"deleted": result.rowcount}


@app.post("/api/history/play")
def add_play_history(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    title = str(payload.get("title", "")).strip()
    if not title:
        raise HTTPException(status_code=422, detail="title is required")
    position_ms = max(0, int(payload.get("position_ms", 0)))
    duration_ms = int(payload.get("duration_ms", -1))
    with closing(db()) as connection:
        cursor = connection.execute(
            "INSERT INTO play_history(bvid, title, uri, position_ms, duration_ms, played_at) VALUES (?, ?, ?, ?, ?, ?)",
            (payload.get("bvid"), title, payload.get("uri"), position_ms, duration_ms, int(time.time())),
        )
        connection.commit()
        record_id = cursor.lastrowid
    return {"id": record_id, "title": title}


@app.get("/api/history/play")
def get_play_history(limit: int = Query(50, ge=1, le=200)) -> dict[str, Any]:
    with closing(db()) as connection:
        rows = connection.execute(
            "SELECT id, bvid, title, uri, position_ms, duration_ms, played_at FROM play_history ORDER BY played_at DESC, id DESC LIMIT ?",
            (limit_value(limit),),
        ).fetchall()
    return {"items": [dict(row) for row in rows]}


@app.delete("/api/history/play")
def clear_play_history() -> dict[str, int]:
    with closing(db()) as connection:
        result = connection.execute("DELETE FROM play_history")
        connection.commit()
    return {"deleted": result.rowcount}


DOWNLOAD_STATUSES = {"pending", "downloading", "paused", "completed", "failed"}


@app.post("/api/downloads")
def create_download(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    title = str(payload.get("title", "")).strip()
    if not title:
        raise HTTPException(status_code=422, detail="title is required")
    status = str(payload.get("status", "pending"))
    if status not in DOWNLOAD_STATUSES:
        raise HTTPException(status_code=422, detail=f"status must be one of {sorted(DOWNLOAD_STATUSES)}")
    now = int(time.time())
    with closing(db()) as connection:
        cursor = connection.execute(
            "INSERT INTO downloads(bvid, title, status, progress, local_path, file_size, error_message, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (payload.get("bvid"), title, status, max(0, min(int(payload.get("progress", 0)), 100)), payload.get("local_path"), max(0, int(payload.get("file_size", 0))), payload.get("error_message"), now, now),
        )
        connection.commit()
        record_id = cursor.lastrowid
    return {"id": record_id, "title": title, "status": status}


@app.get("/api/downloads")
def list_downloads(limit: int = Query(50, ge=1, le=200)) -> dict[str, Any]:
    with closing(db()) as connection:
        rows = connection.execute(
            "SELECT id, bvid, title, status, progress, local_path, file_size, error_message, created_at, updated_at FROM downloads ORDER BY updated_at DESC, id DESC LIMIT ?",
            (limit_value(limit),),
        ).fetchall()
    return {"items": [dict(row) for row in rows]}


@app.get("/api/downloads/{download_id}")
def get_download(download_id: int) -> dict[str, Any]:
    with closing(db()) as connection:
        row = connection.execute(
            "SELECT id, bvid, title, status, progress, local_path, file_size, error_message, created_at, updated_at FROM downloads WHERE id = ?",
            (download_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="download record not found")
    return dict(row)


@app.patch("/api/downloads/{download_id}")
def update_download(download_id: int, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    fields: list[str] = []
    values: list[Any] = []
    if "status" in payload:
        status = str(payload["status"])
        if status not in DOWNLOAD_STATUSES:
            raise HTTPException(status_code=422, detail=f"status must be one of {sorted(DOWNLOAD_STATUSES)}")
        fields.append("status = ?")
        values.append(status)
    if "progress" in payload:
        fields.append("progress = ?")
        values.append(max(0, min(int(payload["progress"]), 100)))
    for field in ("local_path", "file_size", "error_message"):
        if field in payload:
            fields.append(f"{field} = ?")
            values.append(max(0, int(payload[field])) if field == "file_size" else payload[field])
    if not fields:
        raise HTTPException(status_code=422, detail="no fields to update")
    fields.append("updated_at = ?")
    values.extend([int(time.time()), download_id])
    with closing(db()) as connection:
        result = connection.execute(f"UPDATE downloads SET {', '.join(fields)} WHERE id = ?", values)
        connection.commit()
    if result.rowcount == 0:
        raise HTTPException(status_code=404, detail="download record not found")
    return {"id": download_id, "updated": True}


@app.delete("/api/downloads/{download_id}")
def delete_download(download_id: int) -> dict[str, Any]:
    with closing(db()) as connection:
        result = connection.execute("DELETE FROM downloads WHERE id = ?", (download_id,))
        connection.commit()
    if result.rowcount == 0:
        raise HTTPException(status_code=404, detail="download record not found")
    return {"id": download_id, "deleted": True}


@app.get("/api/cache/stats")
def cache_stats() -> dict[str, int]:
    with closing(db()) as connection:
        row = connection.execute(
            "SELECT COUNT(*) AS total, COALESCE(SUM(CASE WHEN expires_at > ? THEN 1 ELSE 0 END), 0) AS active FROM cache",
            (int(time.time()),),
        ).fetchone()
    return {"total": int(row["total"]), "active": int(row["active"])}


@app.delete("/api/cache")
def clear_cache() -> dict[str, int]:
    with closing(db()) as connection:
        result = connection.execute("DELETE FROM cache")
        connection.commit()
    return {"deleted": result.rowcount}


def video_info(bvid: str) -> dict[str, Any]:
    cache_key = f"video:{bvid}"
    cached = cache_get(cache_key)
    if cached:
        return cached
    body = bilibili_request("/x/web-interface/view", {"bvid": bvid})
    data = body.get("data") or {}
    if not data.get("cid"):
        raise HTTPException(status_code=404, detail="Video has no playable page")
    cache_put(cache_key, data)
    return data


def audio_url_for_video(bvid: str, cid: int, quality: int) -> tuple[str, str, str]:
    body = bilibili_request(
        # The legacy endpoint currently supports anonymous playback. The WBI
        # variant can return “账号未登录” even with a valid anonymous buvid3.
        "/x/player/playurl",
        {"bvid": bvid, "cid": cid, "qn": 80, "fnval": 4048, "fnver": 0, "fourk": 0, "platform": "html5"},
        signed=False,
    )
    dash = (body.get("data") or {}).get("dash") or {}
    tracks = dash.get("audio") or []
    tracks += (dash.get("dolby") or {}).get("audio") or []
    tracks += [dash["flac"]["audio"]] if (dash.get("flac") or {}).get("audio") else []
    if tracks:
        chosen = min(tracks, key=lambda track: abs(int(track.get("id", quality)) - quality))
        return chosen.get("baseUrl") or chosen.get("base_url"), "audio/mp4", ".m4a"
    # Older or restricted videos may expose only a muxed MP4 stream. It still
    # contains playable audio, although it is not an audio-only download.
    durl = (body.get("data") or {}).get("durl") or []
    if durl and durl[0].get("url"):
        return durl[0]["url"], "video/mp4", ".mp4"
    raise HTTPException(status_code=404, detail="No playable audio or MP4 stream is available")


def stream_response(url: str, filename: str, incoming: FastAPIRequest) -> StreamingResponse:
    headers = {"User-Agent": USER_AGENT, "Referer": "https://www.bilibili.com/"}
    range_header = incoming.headers.get("range")
    if range_header:
        headers["Range"] = range_header
    try:
        upstream = BILIBILI_OPENER.open(Request(url, headers=headers), timeout=30)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Audio stream request failed: {exc}") from exc

    def chunks() -> Iterator[bytes]:
        try:
            while block := upstream.read(1024 * 256):
                yield block
        finally:
            upstream.close()

    safe_filename = re.sub(r"[\\/\r\n\"]+", "_", filename).strip() or "audio.m4a"
    response_headers = {
        "Content-Disposition": f'attachment; filename="audio.m4a"; filename*=UTF-8\'\'{quote(safe_filename)}'
    }
    for name in ("Content-Length", "Content-Range", "Accept-Ranges", "Content-Type"):
        if upstream.headers.get(name):
            response_headers[name] = upstream.headers[name]
    return StreamingResponse(
        chunks(),
        status_code=206 if range_header else 200,
        headers=response_headers,
        media_type=upstream.headers.get_content_type() or "audio/mp4",
    )


@app.get("/api/videos/{bvid}/audio")
def video_audio(bvid: str, request: FastAPIRequest, quality: int = Query(30280, ge=30216, le=30280)) -> StreamingResponse:
    if not re.fullmatch(r"BV[0-9A-Za-z]{10}", bvid):
        raise HTTPException(status_code=400, detail="Invalid BVID")
    info = video_info(bvid)
    url, _, extension = audio_url_for_video(bvid, int(info["cid"]), quality)
    return stream_response(url, f"{info.get('title', bvid)}{extension}", request)


@app.get("/api/videos/{bvid}/audio/metadata")
def video_audio_metadata(bvid: str, quality: int = Query(30280, ge=30216, le=30280)) -> dict[str, Any]:
    """Return frontend download metadata without exposing the upstream URL."""
    if not re.fullmatch(r"BV[0-9A-Za-z]{10}", bvid):
        raise HTTPException(status_code=400, detail="Invalid BVID")
    info = video_info(bvid)
    _, media_type, extension = audio_url_for_video(bvid, int(info["cid"]), quality)
    return {
        "bvid": bvid,
        "title": info.get("title", bvid),
        "duration_ms": int(info.get("duration", 0)) * 1000,
        "content_type": media_type,
        "extension": extension,
        "stream_url": f"/api/videos/{bvid}/audio?quality={quality}",
        "stream_kind": "dash_audio" if extension == ".m4a" else "mp4_fallback",
    }


@app.get("/api/audio/{sid}/download")
def audio_download(sid: int, request: FastAPIRequest, quality: int = Query(2, ge=0, le=3)) -> StreamingResponse:
    body = bilibili_request("/audio/music-service-c/web/url", {"sid": sid, "quality": quality, "privilege": 2})
    data = body.get("data") or {}
    urls = data.get("cdns") or []
    if not urls:
        raise HTTPException(status_code=404, detail="Audio is unavailable or requires authorization")
    return stream_response(urls[0], f"{data.get('title') or sid}.m4a", request)
