from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app
from fastapi import HTTPException


class BackendUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        app.DB_PATH = str(Path(self.temp_dir.name) / "test-cache.db")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_query_encoding_uses_percent20(self) -> None:
        self.assertEqual(app.encode_query({"keyword": "hello world"}), "keyword=hello%20world")
        self.assertNotIn("+", app.encode_query({"keyword": "hello world"}))

    def test_wbi_signature_has_timestamp_and_digest(self) -> None:
        with patch.object(app.time, "time", return_value=1702204169):
            signed = app.sign_wbi({"foo": "one one"}, "a" * 32, "b" * 32)
        self.assertEqual(signed["wts"], "1702204169")
        self.assertEqual(len(signed["w_rid"]), 32)
        self.assertNotIn("w_rid", {"foo": "one one"})

    def test_sqlite_cache_round_trip_and_expiry(self) -> None:
        app.cache_put("key", {"value": "cached"}, ttl=60)
        self.assertEqual(app.cache_get("key"), {"value": "cached"})
        app.cache_put("expired", {"value": "old"}, ttl=0)
        self.assertIsNone(app.cache_get("expired"))

    def test_search_result_normalization_removes_markup(self) -> None:
        result = app.normalize_search_item({
            "bvid": "BV1234567890",
            "title": "<em>音乐</em>",
            "description": "<em>简介</em>",
            "author": "up",
            "pic": "//image.example/a.jpg",
        })
        self.assertEqual(result["title"], "音乐")
        self.assertEqual(result["description"], "简介")
        self.assertEqual(result["url"], "https://www.bilibili.com/video/BV1234567890")

    def test_search_uses_sqlite_cache(self) -> None:
        response = {"code": 0, "data": {"page": 1, "pagesize": 20, "numResults": 1, "numPages": 1, "result": [{"bvid": "BV1234567890", "title": "测试"}]}}
        with patch.object(app, "bilibili_request", return_value=response) as request:
            first = app.search(keyword="测试", page=1, order="totalrank")
            second = app.search(keyword="测试", page=1, order="totalrank")
        self.assertEqual(first, second)
        self.assertEqual(request.call_count, 1)
        self.assertEqual(first["items"][0]["bvid"], "BV1234567890")

    def test_video_audio_prefers_dash_track(self) -> None:
        response = {"code": 0, "data": {"dash": {"audio": [{"id": 30280, "baseUrl": "https://audio.example/a.m4a"}]}}}
        with patch.object(app, "bilibili_request", return_value=response):
            self.assertEqual(app.audio_url_for_video("BV1234567890", 1, 30280), ("https://audio.example/a.m4a", "audio/mp4", ".m4a"))

    def test_video_audio_falls_back_to_mp4(self) -> None:
        response = {"code": 0, "data": {"durl": [{"url": "https://video.example/a.mp4"}]}}
        with patch.object(app, "bilibili_request", return_value=response):
            self.assertEqual(app.audio_url_for_video("BV1234567890", 1, 30280), ("https://video.example/a.mp4", "video/mp4", ".mp4"))

    def test_frontend_audio_metadata_hides_upstream_url(self) -> None:
        with patch.object(app, "video_info", return_value={"cid": 1, "title": "测试", "duration": 12}), patch.object(
            app, "audio_url_for_video", return_value=("https://upstream.example/signed", "audio/mp4", ".m4a")
        ):
            metadata = app.video_audio_metadata("BV1234567890", quality=30280)
        self.assertEqual(metadata["stream_url"], "/api/videos/BV1234567890/audio?quality=30280")
        self.assertNotIn("upstream.example", str(metadata))

    def test_invalid_bvid_is_rejected(self) -> None:
        with self.assertRaises(HTTPException) as error:
            app.video_audio("not-a-bvid", None)
        self.assertEqual(error.exception.status_code, 400)

    def test_audio_download_rejects_empty_result(self) -> None:
        with patch.object(app, "bilibili_request", return_value={"code": 0, "data": {}}):
            with self.assertRaises(HTTPException) as error:
                app.audio_download(123, None)
        self.assertEqual(error.exception.status_code, 404)

    def test_play_history_can_be_created_and_listed(self) -> None:
        created = app.add_play_history({"title": "测试歌曲", "bvid": "BV1234567890", "position_ms": 1200})
        history = app.get_play_history(limit=10)
        self.assertEqual(created["title"], "测试歌曲")
        self.assertEqual(history["items"][0]["bvid"], "BV1234567890")

    def test_download_record_can_be_created_updated_and_deleted(self) -> None:
        created = app.create_download({"title": "测试下载", "bvid": "BV1234567890"})
        updated = app.update_download(created["id"], {"status": "completed", "progress": 100, "file_size": 1024})
        self.assertTrue(updated["updated"])
        self.assertEqual(app.list_downloads(limit=50)["items"][0]["status"], "completed")
        self.assertTrue(app.delete_download(created["id"])["deleted"])

    def test_cache_stats_and_clear(self) -> None:
        app.cache_put("one", {"ok": True})
        self.assertGreaterEqual(app.cache_stats()["active"], 1)
        self.assertGreaterEqual(app.clear_cache()["deleted"], 1)


if __name__ == "__main__":
    unittest.main()
