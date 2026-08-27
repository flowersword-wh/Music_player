"""Live smoke test for anonymous Bilibili search and audio download.

Run from the backend directory:
    python anonymous_search_download_test.py --keyword "音乐"

The test uses the documented WBI search, view and playurl endpoints without a
Cookie. It downloads only the first 64 KiB unless --full is specified.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from urllib.parse import quote, urlencode
from urllib.request import Request, build_opener

API = "https://api.bilibili.com"
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
MIXIN_KEY_ENC_TAB = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]


def get_json(base: str, path: str, params: dict[str, object], opener):
    query = urlencode(params)
    request = Request(f"{base}{path}?{query}", headers={"User-Agent": USER_AGENT, "Referer": "https://www.bilibili.com/"})
    with opener.open(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8")), response


def require_ok(body: dict, label: str) -> dict:
    if body.get("code", 0) != 0:
        raise RuntimeError(f"{label} failed: {body.get('message') or body.get('msg') or body}")
    return body


def signed_params(params: dict[str, object], img: str, sub: str) -> dict[str, object]:
    mixin = "".join((img + sub)[index] for index in MIXIN_KEY_ENC_TAB)[:32]
    signed = {key: str(value) for key, value in params.items()}
    signed["wts"] = str(int(time.time()))
    canonical = "&".join(f"{quote(str(key), safe='')}={quote(str(value), safe='')}" for key, value in sorted(signed.items()))
    signed["w_rid"] = hashlib.md5((canonical + mixin).encode()).hexdigest()
    return signed


def search(keyword: str, opener) -> dict:
    nav, _ = get_json(API, "/x/web-interface/nav", {}, opener)
    images = (nav.get("data") or {}).get("wbi_img") or {}
    img = images["img_url"].rsplit("/", 1)[-1].split(".", 1)[0]
    sub = images["sub_url"].rsplit("/", 1)[-1].split(".", 1)[0]
    mixin = "".join((img + sub)[index] for index in MIXIN_KEY_ENC_TAB)[:32]
    params = signed_params({"search_type": "video", "keyword": keyword, "order": "totalrank", "duration": 0, "tids": 0, "page": 1}, img, sub)
    body, _ = get_json(API, "/x/web-interface/wbi/search/type", params, opener)
    data = require_ok(body, "anonymous video search").get("data") or {}
    items = data.get("result") or []
    if not items:
        raise RuntimeError("Anonymous search succeeded but returned no results")
    print(f"匿名搜索成功：{len(items)} 条，第一条：{items[0].get('title', '')}")
    return items[0]


def download_audio(item: dict, output: str, full: bool, opener) -> None:
    bvid = item.get("bvid")
    info_body, _ = get_json(API, "/x/web-interface/view", {"bvid": bvid}, opener)
    info = require_ok(info_body, "anonymous video info").get("data") or {}
    nav, _ = get_json(API, "/x/web-interface/nav", {}, opener)
    images = (nav.get("data") or {}).get("wbi_img") or {}
    img = images["img_url"].rsplit("/", 1)[-1].split(".", 1)[0]
    sub = images["sub_url"].rsplit("/", 1)[-1].split(".", 1)[0]
    play_params = signed_params({"bvid": bvid, "cid": info["cid"], "qn": 80, "fnval": 4048, "fnver": 0, "fourk": 0, "platform": "html5"}, img, sub)
    play_body, _ = get_json(API, "/x/player/wbi/playurl", play_params, opener)
    data = require_ok(play_body, "anonymous playurl").get("data") or {}
    dash = data.get("dash") or {}
    tracks = dash.get("audio") or []
    if tracks:
        url = tracks[0].get("baseUrl") or tracks[0].get("base_url")
        kind = "DASH audio"
    else:
        durl = data.get("durl") or []
        if not durl:
            raise RuntimeError("Anonymous playurl returned neither DASH audio nor MP4")
        url = durl[0].get("url")
        kind = "MP4 fallback"
        if output.lower().endswith(".m4a"):
            output = output[:-4] + ".mp4"
    request = Request(url, headers={"User-Agent": USER_AGENT, "Referer": "https://www.bilibili.com/", "Range": "bytes=0-" if full else "bytes=0-65535"})
    with opener.open(request, timeout=30) as response, open(output, "wb") as file:
        remaining = None if full else 65536
        while True:
            block = response.read(256 * 1024 if remaining is None else min(256 * 1024, remaining))
            if not block:
                break
            file.write(block)
            if remaining is not None:
                remaining -= len(block)
                if remaining <= 0:
                    break
    print(f"匿名下载成功：{os.path.abspath(output)}（{os.path.getsize(output)} bytes，{kind}，{bvid}）")


def main() -> int:
    parser = argparse.ArgumentParser(description="Anonymous Bilibili search + audio download smoke test")
    parser.add_argument("--keyword", default="音乐")
    parser.add_argument("--output", default="anonymous-search-download-test.m4a")
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()
    try:
        opener = build_opener()
        download_audio(search(args.keyword, opener), args.output, args.full, opener)
    except Exception as exc:
        print(f"匿名搜索下载测试失败：{exc}", file=sys.stderr)
        return 1
    print("匿名搜索和下载功能全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
