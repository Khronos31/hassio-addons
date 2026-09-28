"""End-to-end tests for the 7002 HLS facade using a local mock upstream."""

from __future__ import annotations

import json
import os
import select
import socket
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import audio_sidecar as sidecar


class MockKonomiHandler(BaseHTTPRequestHandler):
    sessions: set[str] = set()
    keepalives: list[str] = []
    keepalive_times: list[float] = []
    segments: list[tuple[str, str]] = []
    video_requests: list[str] = []
    live_stream_closed: list[str] = []
    live_hls_upstream_closed: list[str] = []
    recorded_file = ""
    channels_body = json.dumps({
        "GR": [{"display_channel_id": "gr011", "name": "NHK総合"}],
        "BS": [],
        "CS": [],
        "SKY": [],
        "CATV": [],
        "BS4K": [],
    }).encode()

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == "/api/channels":
            self._send(200, self.channels_body, "application/json")
            return
        if parsed.path == "/api/videos":
            self.video_requests.append(self.path)
            if query.get("passthrough") == ["1"]:
                body = json.dumps({
                    "recorded_programs": [{
                        "id": 1, "title": "sample",
                        "recorded_video": {"status": "Recorded"},
                    }],
                }).encode()
                self._send(200, body, "application/json; charset=utf-8")
                return
            video_id = query.get("ids", [""])[0]
            entries = {
                "1": {"status": "Recorded", "file_path": self.recorded_file},
                "2": {"status": "Recording", "file_path": self.recorded_file},
                "3": {"status": "Recorded", "file_path": "/missing/mock.ts"},
            }
            item = entries.get(video_id)
            programs = [] if item is None else [{
                "id": int(video_id), "recorded_video": item,
            }]
            self._send(200, json.dumps({"recorded_programs": programs}).encode(), "application/json")
            return
        if parsed.path.startswith("/api/streams/live/") and parsed.path.endswith("/mpegts"):
            if "/missing/" in parsed.path:
                self._send(422, b'{"detail":"channel not found"}', "application/json")
                return
            if "/hls/" in parsed.path:
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.end_headers()
                try:
                    while True:
                        self.wfile.write(b"mock-mpegts-payload" * 1024)
                        self.wfile.flush()
                        time.sleep(0.01)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    self.live_hls_upstream_closed.append(parsed.path)
                return
            if "/idle/" in parsed.path:
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.end_headers()
                self.wfile.write(b"first-mpegts-packet" * 8192)
                self.wfile.flush()
                try:
                    while True:
                        readable, _, _ = select.select([self.connection], [], [], 0.1)
                        if readable and self.connection.recv(1, socket.MSG_PEEK) == b"":
                            self.live_hls_upstream_closed.append(parsed.path)
                            break
                except OSError:
                    self.live_hls_upstream_closed.append(parsed.path)
                return
            if "/disconnect/" in parsed.path:
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.end_headers()
                try:
                    while True:
                        self.wfile.write(b"x" * 65536)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    self.live_stream_closed.append(parsed.path)
                return
            self._send(200, b"mock-live-ts-bytes", "video/mp2t")
            return
        if parsed.path.endswith("/playlist"):
            session_id = query["session_id"][0]
            self.sessions.add(session_id)
            body = ("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4.0,\n"
                    f"segment?session_id={session_id}&sequence=0&cache_key=abcd\n").encode()
            self._send(200, body, "application/vnd.apple.mpegurl")
            return
        if parsed.path.endswith("/segment"):
            session_id = query.get("session_id", [""])[0]
            sequence = query.get("sequence", [""])[0]
            self.segments.append((session_id, sequence))
            self._send(200, b"mock-ts-segment", "video/mp2t")
            return
        self._send(404, b"not found", "text/plain")

    def do_PUT(self) -> None:  # noqa: N802
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        self.keepalives.append(query.get("session_id", [""])[0])
        self.keepalive_times.append(time.monotonic())
        self._send(204, b"", "text/plain")

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        pass


class VideoFacadeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_file = tempfile.NamedTemporaryFile(delete=False)
        cls.temp_file.write(b"recorded-ts")
        cls.temp_file.close()
        cls.ffmpeg_temp = tempfile.TemporaryDirectory()
        cls.fake_ffmpeg = os.path.join(cls.ffmpeg_temp.name, "fake-ffmpeg")
        cls.fake_ffmpeg_args = os.path.join(cls.ffmpeg_temp.name, "ffmpeg-args.json")
        fake_ffmpeg_source = f'''#!/usr/bin/env python3
import json
import os
import sys
with open({cls.fake_ffmpeg_args!r}, "w", encoding="utf-8") as args_file:
    json.dump(sys.argv[1:], args_file)
segment_pattern = sys.argv[sys.argv.index("-hls_segment_filename") + 1]
playlist_path = sys.argv[-1]
first = sys.stdin.buffer.read(1)
if first:
    segment_path = segment_pattern.replace("%05d", "00000")
    with open(segment_path, "wb") as segment:
        segment.write(b"fake-ffmpeg-ts" * 600000)
    with open(playlist_path, "w", encoding="utf-8") as playlist:
        playlist.write("#EXTM3U\\n#EXT-X-VERSION:3\\n#EXTINF:3.0,\\nseg00000.ts\\n")
    while sys.stdin.buffer.read(65536):
        pass
'''
        with open(cls.fake_ffmpeg, "w", encoding="utf-8") as fake_ffmpeg:
            fake_ffmpeg.write(fake_ffmpeg_source)
        os.chmod(cls.fake_ffmpeg, 0o755)
        cls.original_ffmpeg = sidecar.FFMPEG
        sidecar.FFMPEG = cls.fake_ffmpeg
        MockKonomiHandler.recorded_file = cls.temp_file.name
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), MockKonomiHandler)
        cls.upstream_thread = threading.Thread(target=cls.upstream.serve_forever, daemon=True)
        cls.upstream_thread.start()
        sidecar.KONOMI_API = f"http://127.0.0.1:{cls.upstream.server_port}"
        sidecar.HLS_KEEPALIVE_INTERVAL = 0.3
        sidecar.HLS_IDLE_TIMEOUT = 1.0
        sidecar.LIVE_HLS_IDLE_TIMEOUT = 1.0
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), sidecar.Handler)
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.upstream.shutdown()
        cls.upstream.server_close()
        os.unlink(cls.temp_file.name)
        sidecar.FFMPEG = cls.original_ffmpeg
        cls.ffmpeg_temp.cleanup()
        for session in list(sidecar.HLS_SESSIONS.values()):
            session.close()

    def setUp(self) -> None:
        MockKonomiHandler.sessions.clear()
        MockKonomiHandler.keepalives.clear()
        MockKonomiHandler.keepalive_times.clear()
        MockKonomiHandler.segments.clear()
        MockKonomiHandler.video_requests.clear()
        MockKonomiHandler.live_stream_closed.clear()
        MockKonomiHandler.live_hls_upstream_closed.clear()
        MockKonomiHandler.channels_body = json.dumps({
            "GR": [{"display_channel_id": "gr011", "name": "NHK総合"}],
            "BS": [],
            "CS": [],
            "SKY": [],
            "CATV": [],
            "BS4K": [],
        }).encode()

    def request(self, path: str, method: str = "GET") -> tuple[int, bytes, object]:
        req = urllib.request.Request(self.base_url + path, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.status, response.read(), response.headers
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read(), exc.headers

    def test_hls_keepalive_session_rewrite_and_idle_release(self) -> None:
        status, playlist_bytes, headers = self.request("/api/recorded/1/video.m3u8?quality=720p")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "application/vnd.apple.mpegurl")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")
        playlist = playlist_bytes.decode()
        local_urls = [line for line in playlist.splitlines() if line and not line.startswith("#")]
        self.assertEqual(len(local_urls), 1)
        self.assertTrue(local_urls[0].startswith("/api/recorded/1/video/"))
        self.assertIn("segment.ts?sequence=0", local_urls[0])
        self.assertNotIn("127.0.0.1", playlist)
        token = local_urls[0].split("/video/")[1].split("/")[0]
        segment_path = urllib.parse.urlsplit(local_urls[0]).path + "?" + urllib.parse.urlsplit(local_urls[0]).query

        # Keep requesting segments for more than the KonomiTV ten-second timeout.
        end = time.monotonic() + 15.2
        while time.monotonic() < end:
            segment_status, segment, segment_headers = self.request(segment_path)
            self.assertEqual(segment_status, 200)
            self.assertEqual(segment, b"mock-ts-segment")
            self.assertEqual(segment_headers.get_content_type(), "video/mp2t")
            time.sleep(0.45)
        self.assertTrue(MockKonomiHandler.keepalives)
        self.assertGreaterEqual(len(MockKonomiHandler.keepalives), 10)
        self.assertEqual(len(set(MockKonomiHandler.keepalives)), 1)
        gaps = [later - earlier for earlier, later in zip(
            MockKonomiHandler.keepalive_times,
            MockKonomiHandler.keepalive_times[1:],
        )]
        self.assertTrue(gaps)
        self.assertLess(max(gaps), 10)
        upstream_session = MockKonomiHandler.keepalives[0]
        self.assertTrue(upstream_session.startswith("sidecar-"))
        self.assertEqual(MockKonomiHandler.segments[-1][0], upstream_session)

        # A new top-level request gets a new playback, not the earlier session.
        second_status, second_playlist, _ = self.request("/api/recorded/1/video.m3u8?quality=720p")
        self.assertEqual(second_status, 200)
        second_uri = [line for line in second_playlist.decode().splitlines()
                      if line and not line.startswith("#")][0]
        second_token = second_uri.split("/video/")[1].split("/")[0]
        self.assertNotEqual(token, second_token)
        second_url = urllib.parse.urlsplit(second_uri)
        second_status, _, _ = self.request(second_url.path + "?" + second_url.query)
        self.assertEqual(second_status, 200)
        deadline = time.monotonic() + 2
        while len(set(MockKonomiHandler.keepalives)) < 2 and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(len(set(MockKonomiHandler.keepalives)), 2)
        self.assertNotEqual(MockKonomiHandler.segments[-1][0], upstream_session)

        count_at_stop = MockKonomiHandler.keepalives.count(upstream_session)
        expired = time.monotonic() + 4
        while token in sidecar.HLS_SESSIONS and time.monotonic() < expired:
            time.sleep(0.1)
        self.assertNotIn(token, sidecar.HLS_SESSIONS)
        after_release = MockKonomiHandler.keepalives.count(upstream_session)
        time.sleep(0.7)
        self.assertEqual(MockKonomiHandler.keepalives.count(upstream_session), after_release)
        self.assertGreaterEqual(after_release, count_at_stop)

    def test_validation_errors_and_upstream_unavailable(self) -> None:
        self.assertEqual(self.request("/api/recorded/nope/video.m3u8")[0], 404)
        self.assertEqual(self.request("/api/recorded/999/video.m3u8")[0], 404)
        self.assertEqual(self.request("/api/recorded/2/video.m3u8")[0], 409)
        self.assertEqual(self.request("/api/recorded/3/video.m3u8")[0], 404)
        self.assertEqual(self.request("/api/recorded/1/video.m3u8?quality=original")[0], 400)

        original_api = sidecar.KONOMI_API
        sidecar.KONOMI_API = "http://127.0.0.1:1"
        try:
            status, body, headers = self.request("/api/recorded/1/video.m3u8")
            self.assertEqual(status, 502)
            self.assertEqual(headers.get_content_type(), "application/json")
            self.assertIn(b"unavailable", body)
        finally:
            sidecar.KONOMI_API = original_api

    def test_recording_list_proxy_preserves_query_payload_and_cors(self) -> None:
        path = "/api/videos?order=desc&page=1&ids=1%2C2&passthrough=1"
        status, body, headers = self.request(path)
        self.assertEqual(status, 200)
        self.assertEqual(MockKonomiHandler.video_requests[-1], path)
        self.assertEqual(headers.get_content_type(), "application/json")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")
        expected = json.dumps({
            "recorded_programs": [{
                "id": 1, "title": "sample",
                "recorded_video": {"status": "Recorded"},
            }],
        }).encode()
        self.assertEqual(body, expected)
        self.assertEqual(json.loads(body)["recorded_programs"][0]["title"], "sample")

        original_api = sidecar.KONOMI_API
        sidecar.KONOMI_API = "http://127.0.0.1:1"
        try:
            status, body, headers = self.request(path)
            self.assertEqual(status, 502)
            self.assertEqual(headers.get_content_type(), "application/json")
            self.assertIn(b"unavailable", body)
        finally:
            sidecar.KONOMI_API = original_api

    def test_channels_proxy_and_validation(self) -> None:
        status, body, headers = self.request("/api/channels")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "application/json")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")
        data = json.loads(body)
        self.assertEqual(data["GR"][0]["display_channel_id"], "gr011")
        self.assertIn("BS4K", data)

        # クエリ付きは許可しない
        self.assertEqual(self.request("/api/channels?x=1")[0], 400)
        # POST も許可しない（既定の 501）
        self.assertEqual(self.request("/api/channels", method="POST")[0], 501)

        # 非JSON・非オブジェクト応答は 502
        for broken in (b"<html>oops</html>", b"[1,2,3]"):
            MockKonomiHandler.channels_body = broken
            status, body, headers = self.request("/api/channels")
            self.assertEqual(status, 502)
            self.assertEqual(headers.get_content_type(), "application/json")

        # 上流停止は 502
        original_api = sidecar.KONOMI_API
        sidecar.KONOMI_API = "http://127.0.0.1:1"
        try:
            status, body, headers = self.request("/api/channels")
            self.assertEqual(status, 502)
            self.assertEqual(headers.get_content_type(), "application/json")
        finally:
            sidecar.KONOMI_API = original_api

    def test_live_mpegts_proxy_validation_errors_and_disconnect(self) -> None:
        path = "/api/streams/live/gr011/video.ts?quality=720p"
        status, body, headers = self.request(path)
        self.assertEqual((status, body), (200, b"mock-live-ts-bytes"))
        self.assertEqual(headers.get_content_type(), "video/mp2t")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")

        self.assertEqual(self.request(
            "/api/streams/live/gr011/video.ts?quality=original"
        )[0], 400)
        self.assertEqual(self.request(
            "/api/streams/live/missing/video.ts?quality=720p"
        )[0], 404)

        original_api = sidecar.KONOMI_API
        sidecar.KONOMI_API = "http://127.0.0.1:1"
        try:
            self.assertEqual(self.request(path)[0], 502)
        finally:
            sidecar.KONOMI_API = original_api

        import socket
        client = socket.create_connection(("127.0.0.1", self.server.server_port))
        client.sendall(
            b"GET /api/streams/live/disconnect/video.ts?quality=720p HTTP/1.1\r\n"
            b"Host: localhost\r\nConnection: close\r\n\r\n"
        )
        client.settimeout(3)
        self.assertIn(b"video/mp2t", client.recv(4096))
        client.close()
        deadline = time.monotonic() + 3
        while not MockKonomiHandler.live_stream_closed and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(MockKonomiHandler.live_stream_closed)

    def test_live_hls_playlist_segment_and_idle_cleanup(self) -> None:
        status, playlist_bytes, headers = self.request(
            "/api/streams/live/hls/video.m3u8?quality=720p"
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "application/vnd.apple.mpegurl")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")
        playlist = playlist_bytes.decode()
        segment_urls = [line for line in playlist.splitlines()
                        if line and not line.startswith("#")]
        self.assertEqual(len(segment_urls), 1)
        self.assertTrue(segment_urls[0].startswith("/api/streams/live/hls/video/"))
        self.assertIn("/seg00000.ts", segment_urls[0])

        token = segment_urls[0].split("/video/")[1].split("/")[0]
        session = sidecar.LIVE_HLS_SESSIONS[token]
        directory = session.directory
        pid = session.process.pid
        upstream = session.upstream
        repeat_status, repeated_playlist, _ = self.request(
            "/api/streams/live/hls/video.m3u8?quality=720p"
        )
        repeated_token = next(
            line.split("/video/")[1].split("/")[0]
            for line in repeated_playlist.decode().splitlines()
            if line and not line.startswith("#")
        )
        self.assertEqual(repeat_status, 200)
        self.assertEqual(repeated_token, token)
        self.assertEqual(sidecar.LIVE_HLS_SESSIONS[token].process.pid, pid)
        with open(self.fake_ffmpeg_args, encoding="utf-8") as args_file:
            ffmpeg_args = json.load(args_file)
        self.assertEqual(ffmpeg_args[ffmpeg_args.index("-c") + 1], "copy")
        self.assertEqual(ffmpeg_args[ffmpeg_args.index("-hls_time") + 1], "3")
        self.assertEqual(ffmpeg_args[ffmpeg_args.index("-hls_list_size") + 1], "17")
        self.assertEqual(
            ffmpeg_args[ffmpeg_args.index("-hls_flags") + 1], "delete_segments"
        )
        status, segment, headers = self.request(segment_urls[0])
        self.assertEqual(status, 200)
        self.assertEqual(headers.get_content_type(), "video/mp2t")
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), "*")
        self.assertEqual(segment, b"fake-ffmpeg-ts" * 600000)

        deadline = time.monotonic() + 4
        while token in sidecar.LIVE_HLS_SESSIONS and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertNotIn(token, sidecar.LIVE_HLS_SESSIONS)
        self.assertFalse(os.path.exists(directory))
        self.assertTrue(upstream.closed)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_live_hls_errors_and_client_disconnect_cleanup(self) -> None:
        self.assertEqual(self.request(
            "/api/streams/live/hls/video.m3u8?quality=original"
        )[0], 400)
        self.assertEqual(self.request(
            "/api/streams/live/missing/video.m3u8?quality=720p"
        )[0], 404)

        original_api = sidecar.KONOMI_API
        sidecar.KONOMI_API = "http://127.0.0.1:1"
        try:
            status, body, _ = self.request(
                "/api/streams/live/hls/video.m3u8?quality=720p"
            )
            self.assertEqual(status, 502)
            self.assertIn(b"unavailable", body)
        finally:
            sidecar.KONOMI_API = original_api

        status, playlist_bytes, _ = self.request(
            "/api/streams/live/hls/video.m3u8?quality=720p"
        )
        self.assertEqual(status, 200)
        segment_url = next(line for line in playlist_bytes.decode().splitlines()
                           if line and not line.startswith("#"))
        token = segment_url.split("/video/")[1].split("/")[0]
        session = sidecar.LIVE_HLS_SESSIONS[token]
        directory = session.directory
        pid = session.process.pid

        import socket
        client = socket.create_connection(("127.0.0.1", self.server.server_port))
        client.sendall(
            f"GET {segment_url} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
        )
        client.settimeout(3)
        response_headers = b""
        while b"\r\n\r\n" not in response_headers:
            response_headers += client.recv(4096)
        self.assertIn(b"200", response_headers)
        client.close()

        deadline = time.monotonic() + 3
        while token in sidecar.LIVE_HLS_SESSIONS and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertNotIn(token, sidecar.LIVE_HLS_SESSIONS)
        self.assertFalse(os.path.exists(directory))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_live_hls_idle_cleanup_while_upstream_is_silent(self) -> None:
        status, playlist_bytes, _ = self.request(
            "/api/streams/live/idle/video.m3u8?quality=720p"
        )
        self.assertEqual(status, 200)
        token = next(
            line.split("/video/")[1].split("/")[0]
            for line in playlist_bytes.decode().splitlines()
            if line and not line.startswith("#")
        )
        session = sidecar.LIVE_HLS_SESSIONS[token]
        directory = session.directory
        pid = session.process.pid
        reader_thread = session.reader_thread
        upstream = session.upstream

        deadline = time.monotonic() + 4
        while token in sidecar.LIVE_HLS_SESSIONS and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertNotIn(token, sidecar.LIVE_HLS_SESSIONS)
        self.assertFalse(os.path.exists(directory))
        self.assertTrue(upstream.closed)
        self.assertFalse(reader_thread.is_alive())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertTrue(MockKonomiHandler.live_hls_upstream_closed)

    def test_health_audio_regression_and_cors_preflight(self) -> None:
        status, body, _ = self.request("/healthz")
        self.assertEqual((status, body), (200, b"ok\n"))
        original_stream_audio = sidecar.stream_audio
        sources: list[str] = []

        def mock_stream_audio(handler, source: str) -> None:
            sources.append(source)
            handler.wfile.write(b"mock-mp3")

        sidecar.stream_audio = mock_stream_audio
        try:
            status, body, headers = self.request("/api/recorded/1/audio.mp3")
            self.assertEqual((status, body), (200, b"mock-mp3"))
            self.assertEqual(headers.get_content_type(), "audio/mpeg")
            status, body, headers = self.request("/api/streams/live/gr011/audio.mp3?quality=720p")
            self.assertEqual((status, body), (200, b"mock-mp3"))
            self.assertEqual(headers.get_content_type(), "audio/mpeg")
            self.assertIn("/api/streams/live/gr011/720p/mpegts", sources[-1])
        finally:
            sidecar.stream_audio = original_stream_audio

        status, _, headers = self.request("/api/recorded/1/video.m3u8", method="OPTIONS")
        self.assertEqual(status, 204)
        self.assertIn("GET", headers.get("Access-Control-Allow-Methods", ""))


if __name__ == "__main__":
    unittest.main()
