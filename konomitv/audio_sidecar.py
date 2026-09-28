#!/usr/bin/env python3
"""Audio-only streaming sidecar for the KonomiTV add-on.

The Home Assistant integration resolves audio items to this server.  It reads
the recorded TS file directly (recordings) or the live MPEG-TS endpoint (live)
and streams audio-only MP3 using the FFmpeg bundled with KonomiTV.

Endpoints:
  GET /healthz
  GET /api/recorded/{video_id}/audio.mp3
  GET /api/streams/live/{channel}/audio.mp3?quality=720p

Environment:
  KONOMI_API                 KonomiTV server base URL (default http://127.0.0.77:7010)
  KONOMI_FFMPEG              FFmpeg binary (default /code/server/thirdparty/FFmpeg/ffmpeg.elf)
  KONOMI_AUDIO_BIND          bind address (default 0.0.0.0)
  KONOMI_AUDIO_PORT          listen port (default 7002)
  KONOMI_AUDIO_LIVE_QUALITY  default live quality (default 720p)
"""

from __future__ import annotations

import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KONOMI_API = os.environ.get("KONOMI_API", "http://127.0.0.77:7010").rstrip("/")
FFMPEG = os.environ.get(
    "KONOMI_FFMPEG", "/code/server/thirdparty/FFmpeg/ffmpeg.elf"
)
BIND = os.environ.get("KONOMI_AUDIO_BIND", "0.0.0.0")
PORT = int(os.environ.get("KONOMI_AUDIO_PORT", "7002"))
LIVE_QUALITY = os.environ.get("KONOMI_AUDIO_LIVE_QUALITY", "720p")
VIDEO_QUALITY = {"720p", "720p-hevc"}
HLS_KEEPALIVE_INTERVAL = float(os.environ.get("KONOMI_HLS_KEEPALIVE_INTERVAL", "3"))
HLS_IDLE_TIMEOUT = float(os.environ.get("KONOMI_HLS_IDLE_TIMEOUT", "8"))
HTTP_TIMEOUT = 10
LIVE_CONNECT_TIMEOUT = 90
LIVE_HLS_START_TIMEOUT = 60
LIVE_HLS_IDLE_TIMEOUT = float(os.environ.get("KONOMI_LIVE_HLS_IDLE_TIMEOUT", "8"))

AUDIO_OPTS = [
    "-vn", "-sn", "-dn",
    "-map", "0:a:0?",
    "-c:a", "libmp3lame",
    "-b:a", "128k",
    "-f", "mp3",
    "pipe:1",
]

CHUNK = 64 * 1024


class FacadeError(Exception):
    """An expected error that should be returned to the HTTP client."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class HlsSession:
    """One Cast playback and its isolated KonomiTV streaming session."""

    def __init__(self, video_id: str, quality: str):
        self.token = uuid.uuid4().hex
        self.video_id = video_id
        self.quality = quality
        self.upstream_id = f"sidecar-{uuid.uuid4().hex}"
        self.last_access = time.monotonic()
        self.active_requests = 0
        self.closed = False
        self.condition = threading.Condition()
        self.next_keepalive = time.monotonic() + HLS_KEEPALIVE_INTERVAL
        self.thread = threading.Thread(target=self._keep_alive_loop, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def touch(self) -> None:
        with self.condition:
            if self.closed:
                raise FacadeError(410, "playback session expired")
            self.last_access = time.monotonic()
            self.active_requests += 1
            self.condition.notify_all()

    def release_request(self) -> None:
        with self.condition:
            self.active_requests = max(0, self.active_requests - 1)
            self.last_access = time.monotonic()
            self.condition.notify_all()

    def close(self) -> None:
        with self.condition:
            self.closed = True
            self.condition.notify_all()

    def _keep_alive_loop(self) -> None:
        while True:
            with self.condition:
                while not self.closed:
                    now = time.monotonic()
                    if (self.active_requests == 0 and
                            now - self.last_access >= HLS_IDLE_TIMEOUT):
                        self.closed = True
                        break
                    wait_for = self.next_keepalive - now
                    if self.active_requests == 0:
                        wait_for = min(
                            wait_for,
                            max(0.0, HLS_IDLE_TIMEOUT - (now - self.last_access)),
                        )
                    if wait_for <= 0:
                        if now >= self.next_keepalive:
                            self.next_keepalive = now + HLS_KEEPALIVE_INTERVAL
                            break
                        continue
                    self.condition.wait(timeout=wait_for)
                if self.closed:
                    break
            try:
                url = upstream_video_url(
                    self.video_id, self.quality, "keep-alive",
                    {"session_id": self.upstream_id},
                )
                request = urllib.request.Request(url, method="PUT")
                with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT):
                    pass
            except Exception as exc:
                log(f"HLS session {self.token}: keep-alive failed: {exc}")
                with self.condition:
                    self.closed = True
                    self.condition.notify_all()
                break
        with HLS_SESSIONS_LOCK:
            HLS_SESSIONS.pop(self.token, None)
        log(f"HLS session {self.token}: released")


class LiveHlsSession:
    """One live channel converted to an isolated local HLS stream."""

    def __init__(self, channel: str, quality: str, upstream, client_key):
        self.token = uuid.uuid4().hex
        self.channel = channel
        self.quality = quality
        self.client_key = client_key
        self.upstream = upstream
        self.directory = tempfile.mkdtemp(prefix=f"konomitv-live-{self.token}-")
        self.playlist_path = os.path.join(self.directory, "index.m3u8")
        self.segment_pattern = os.path.join(self.directory, "seg%05d.ts")
        self.last_access = time.monotonic()
        self.active_requests = 1  # the request waiting for the first playlist
        self.condition = threading.Condition()
        self.stop_event = threading.Event()
        self.stop_lock = threading.Lock()
        self.closed = False
        self.process: subprocess.Popen | None = None
        self.reader_thread: threading.Thread | None = None
        self.monitor_thread: threading.Thread | None = None
        self.client_gone = False

    def start(self) -> None:
        command = [
            FFMPEG, "-hide_banner", "-loglevel", "error",
            "-i", "pipe:0", "-c", "copy",
            "-f", "hls", "-hls_time", "3", "-hls_list_size", "17",
            "-hls_flags", "delete_segments",
            "-hls_segment_filename", self.segment_pattern,
            self.playlist_path,
        ]
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError as exc:
            self.close()
            raise FacadeError(502, "FFmpeg could not be started") from exc
        self.reader_thread = threading.Thread(target=self._feed_ffmpeg, daemon=True)
        self.monitor_thread = threading.Thread(target=self._monitor_idle, daemon=True)
        self.reader_thread.start()
        self.monitor_thread.start()

    def touch(self) -> None:
        with self.condition:
            if self.closed:
                raise FacadeError(410, "live playback session expired")
            self.last_access = time.monotonic()
            self.active_requests += 1
            self.condition.notify_all()

    def release_request(self) -> None:
        with self.condition:
            self.active_requests = max(0, self.active_requests - 1)
            self.last_access = time.monotonic()
            self.condition.notify_all()

    def wait_for_playlist(self, timeout: float, client_socket) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.condition:
                if self.closed:
                    return False
            if os.path.isfile(self.playlist_path):
                return True
            try:
                readable, _, exceptional = select.select([client_socket], [], [client_socket], 0)
                if exceptional:
                    self.client_gone = True
                    self.close()
                    return False
                if readable and client_socket.recv(1, socket.MSG_PEEK) == b"":
                    self.client_gone = True
                    self.close()
                    return False
            except (OSError, ValueError):
                self.client_gone = True
                self.close()
                return False
            if self.process is not None and self.process.poll() is not None:
                return False
            time.sleep(0.05)
        return False

    def playlist(self) -> bytes:
        with open(self.playlist_path, "r", encoding="utf-8") as source:
            lines = source.read().splitlines()
        local_prefix = f"/api/streams/live/{self.channel}/video/{self.token}/"
        rewritten = [
            line if not line or line.startswith("#")
            else local_prefix + os.path.basename(line.strip())
            for line in lines
        ]
        return ("\n".join(rewritten) + "\n").encode("utf-8")

    def segment_path(self, name: str) -> str:
        if not re.fullmatch(r"seg\d+\.ts", name):
            raise FacadeError(404, "segment not found")
        return os.path.join(self.directory, name)

    def _feed_ffmpeg(self) -> None:
        assert self.process is not None and self.process.stdin is not None
        try:
            while not self.stop_event.is_set():
                chunk = self.upstream.read(CHUNK)
                if not chunk:
                    break
                self.process.stdin.write(chunk)
                self.process.stdin.flush()
        except (BrokenPipeError, ConnectionResetError, OSError, ValueError) as exc:
            if not self.stop_event.is_set():
                log(f"live HLS {self.token}: upstream/FFmpeg stream ended: {exc}")
        finally:
            try:
                self.process.stdin.close()
            except (OSError, ValueError):
                pass
            if not self.stop_event.is_set():
                self.close()

    def _monitor_idle(self) -> None:
        while not self.stop_event.wait(0.2):
            with self.condition:
                idle = time.monotonic() - self.last_access
                if self.active_requests == 0 and idle >= LIVE_HLS_IDLE_TIMEOUT:
                    break
        if not self.stop_event.is_set():
            self.close()

    def close(self) -> None:
        with self.stop_lock:
            if self.closed:
                return
            with self.condition:
                self.closed = True
                self.condition.notify_all()
            self.stop_event.set()
            try:
                upstream_socket = self.upstream.fp.raw._sock
                upstream_socket.shutdown(socket.SHUT_RDWR)
            except (AttributeError, OSError):
                pass
            try:
                self.upstream.close()
            except OSError:
                pass
            process = self.process
            if process is not None and process.poll() is None:
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    process.wait()
            shutil.rmtree(self.directory, ignore_errors=True)
            with LIVE_HLS_SESSIONS_LOCK:
                LIVE_HLS_SESSIONS.pop(self.token, None)
                if LIVE_HLS_CLIENT_SESSIONS.get(self.client_key) == self.token:
                    LIVE_HLS_CLIENT_SESSIONS.pop(self.client_key, None)
            log(f"live HLS session {self.token}: released")


LIVE_HLS_SESSIONS: dict[str, LiveHlsSession] = {}
LIVE_HLS_SESSIONS_LOCK = threading.Lock()
LIVE_HLS_CLIENT_SESSIONS: dict[tuple[str, str, str, str], str] = {}


HLS_SESSIONS: dict[str, HlsSession] = {}
HLS_SESSIONS_LOCK = threading.Lock()


def upstream_video_url(video_id: str, quality: str, endpoint: str,
                       query: dict[str, str]) -> str:
    encoded_query = urllib.parse.urlencode(query)
    return (f"{KONOMI_API}/api/streams/video/{video_id}/{quality}/"
            f"{endpoint}?{encoded_query}")


def fetch_upstream(url: str, method: str = "GET") -> tuple[bytes, str]:
    request = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            return response.read(), response.headers.get_content_type()
    except urllib.error.HTTPError as exc:
        raise FacadeError(502, f"KonomiTV returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FacadeError(502, "KonomiTV is unavailable") from exc


def resolve_recorded_video(video_id: str) -> None:
    query = urllib.parse.urlencode({"ids": video_id, "order": "ids"})
    try:
        with urllib.request.urlopen(f"{KONOMI_API}/api/videos?{query}", timeout=HTTP_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise FacadeError(502, f"KonomiTV returned HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise FacadeError(502, "KonomiTV is unavailable") from exc

    programs = data.get("recorded_programs") or []
    if not programs or str(programs[0].get("id")) != video_id:
        raise FacadeError(404, "recording not found")
    recorded_video = programs[0].get("recorded_video") or {}
    if recorded_video.get("status") != "Recorded":
        raise FacadeError(409, "recording is not complete")
    file_path = recorded_video.get("file_path") or ""
    if file_path.startswith("/host-rootfs"):
        file_path = file_path[len("/host-rootfs"):]
    if not file_path or not os.path.isfile(file_path):
        raise FacadeError(404, "recording file not found")


def rewrite_playlist(playlist: str, session: HlsSession) -> str:
    """Replace every upstream segment URI with an opaque local session URL."""
    output: list[str] = []
    for line in playlist.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            output.append(line)
            continue
        parsed = urllib.parse.urlsplit(stripped)
        params = urllib.parse.parse_qs(parsed.query)
        if "sequence" not in params:
            raise FacadeError(502, "unexpected URI in KonomiTV playlist")
        try:
            sequence = int(params["sequence"][0])
        except (ValueError, IndexError) as exc:
            raise FacadeError(502, "invalid segment URI in KonomiTV playlist") from exc
        audio = params.get("audio", ["primary"])[0]
        cache_key = params.get("cache_key", [""])[0]
        local_query = urllib.parse.urlencode({"audio": audio, "cache_key": cache_key})
        output.append(
            f"/api/recorded/{session.video_id}/video/{session.token}/segment.ts"
            f"?sequence={sequence}&{local_query}"
        )
    return "\n".join(output) + ("\n" if playlist.endswith("\n") else "")


def find_hls_session(video_id: str, token: str) -> HlsSession:
    with HLS_SESSIONS_LOCK:
        session = HLS_SESSIONS.get(token)
    if session is None or session.video_id != video_id:
        raise FacadeError(404, "playback session not found")
    session.touch()
    return session


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def resolve_recorded_file(video_id: str) -> str:
    """Return the recorded TS file path for a KonomiTV recording ID."""
    query = urllib.parse.urlencode({"ids": video_id, "order": "ids"})
    url = f"{KONOMI_API}/api/videos?{query}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    programs = data.get("recorded_programs") or []
    if not programs:
        raise LookupError(f"recording {video_id} not found")
    recorded_video = programs[0].get("recorded_video") or {}
    status = recorded_video.get("status")
    if status != "Recorded":
        raise LookupError(f"recording {video_id} is not ready (status={status})")
    file_path = recorded_video.get("file_path") or ""
    if not file_path:
        raise LookupError(f"recording {video_id} has no file_path")
    # コンテナ判定用の /host-rootfs は / へのシンボリックリンクなので剥がす。
    if file_path.startswith("/host-rootfs"):
        file_path = file_path[len("/host-rootfs"):]
    if not os.path.isfile(file_path):
        raise LookupError(f"recording {video_id}: file not found: {file_path}")
    return file_path


def stream_audio(handler: BaseHTTPRequestHandler, source: str) -> None:
    """Transcode `source` (file path or URL) to audio-only MP3 and stream it."""
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-i", source, *AUDIO_OPTS]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
    )
    assert proc.stdout is not None
    try:
        while True:
            chunk = proc.stdout.read(CHUNK)
            if not chunk:
                break
            try:
                handler.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                log("client disconnected, stopping ffmpeg")
                break
    finally:
        proc.stdout.close()
        if proc.stderr is not None:
            try:
                proc.stderr.close()
            except OSError:
                pass
        if proc.poll() is None:
            proc.kill()
        proc.wait()
    stderr = ""
    # エラーは標準エラー出力へ残す（ログ確認用）。
    if proc.returncode not in (0, -9):  # -9 はクライアント切断時の kill
        log(f"ffmpeg exited with {proc.returncode}: {' '.join(cmd[:6])} ...")


class Handler(BaseHTTPRequestHandler):
    server_version = "KonomiTVAudioSidecar/1.0"

    def end_headers(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Range, Content-Type")
        self.send_header("Access-Control-Expose-Headers", "Content-Length, Content-Range")
        super().end_headers()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = urllib.parse.parse_qs(parsed.query)
        try:
            if path == "/healthz":
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", "3")
                self.end_headers()
                self.wfile.write(b"ok\n")
                return

            if path == "/api/videos":
                self.proxy_videos(parsed.query)
                return

            live_video_match = re.fullmatch(
                r"/api/streams/live/([^/]+)/video\.ts", path
            )
            if live_video_match:
                channel = live_video_match.group(1)
                quality = query.get("quality", ["720p"])[0]
                if quality not in VIDEO_QUALITY:
                    raise FacadeError(400, "unsupported video quality")
                self.proxy_live_video(channel, quality)
                return

            live_hls_match = re.fullmatch(
                r"/api/streams/live/([^/]+)/video\.m3u8", path
            )
            live_segment_match = re.fullmatch(
                r"/api/streams/live/([^/]+)/video/([a-f0-9]{32})/(seg\d+\.ts)",
                path,
            )
            if live_hls_match:
                channel = live_hls_match.group(1)
                quality = query.get("quality", ["720p"])[0]
                if quality not in VIDEO_QUALITY:
                    raise FacadeError(400, "unsupported video quality")
                self.serve_live_playlist(channel, quality)
                return

            if live_segment_match:
                channel, token, name = live_segment_match.groups()
                self.serve_live_segment(channel, token, name)
                return

            video_match = re.fullmatch(
                r"/api/recorded/(\d+)/video\.m3u8", path
            )
            segment_match = re.fullmatch(
                r"/api/recorded/(\d+)/video/([a-f0-9]{32})/segment\.ts", path
            )
            if video_match:
                video_id = video_match.group(1)
                quality = query.get("quality", ["720p"])[0]
                if quality not in VIDEO_QUALITY:
                    raise FacadeError(400, "unsupported video quality")
                resolve_recorded_video(video_id)
                session = HlsSession(video_id, quality)
                upstream_url = upstream_video_url(
                    video_id, quality, "playlist",
                    {"session_id": session.upstream_id, "type": "primary-audio"},
                )
                playlist_data, _ = fetch_upstream(upstream_url)
                rewritten = rewrite_playlist(playlist_data.decode("utf-8"), session)
                with HLS_SESSIONS_LOCK:
                    HLS_SESSIONS[session.token] = session
                session.start()
                body = rewritten.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            if segment_match:
                video_id, token = segment_match.groups()
                try:
                    sequence = int(query.get("sequence", [""])[0])
                except ValueError as exc:
                    raise FacadeError(400, "invalid segment sequence") from exc
                if sequence < 0:
                    raise FacadeError(400, "invalid segment sequence")
                audio = query.get("audio", ["primary"])[0]
                if audio not in {"primary", "secondary"}:
                    raise FacadeError(400, "invalid audio track")
                session = find_hls_session(video_id, token)
                upstream_query = {
                    "session_id": session.upstream_id,
                    "sequence": str(sequence),
                    "cache_key": query.get("cache_key", [""])[0],
                    "audio": audio,
                }
                try:
                    body, content_type = fetch_upstream(
                        upstream_video_url(video_id, session.quality, "segment", upstream_query)
                    )
                    self.send_response(200)
                    self.send_header("Content-Type", content_type or "video/mp2t")
                    self.send_header("Cache-Control", "max-age=10800")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                finally:
                    session.release_request()
                return

            source: str | None = None
            if path.startswith("/api/recorded/") and path.endswith("/audio.mp3"):
                video_id = path[len("/api/recorded/"):-len("/audio.mp3")]
                if not video_id.isdigit():
                    self.send_error(400, "invalid recording id")
                    return
                source = resolve_recorded_file(video_id)
            elif path.startswith("/api/streams/live/") and path.endswith("/audio.mp3"):
                channel = path[len("/api/streams/live/"):-len("/audio.mp3")]
                if not channel or "/" in channel:
                    self.send_error(400, "invalid channel id")
                    return
                quality = query.get("quality", [LIVE_QUALITY])[0]
                source = f"{KONOMI_API}/api/streams/live/{channel}/{quality}/mpegts"
            else:
                self.send_error(404)
                return

            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            stream_audio(self, source)
        except FacadeError as exc:
            self.send_error_response(exc.status, str(exc))
        except (LookupError, urllib.error.URLError) as exc:
            log(f"{path}: {exc}")
            self.send_error(404, str(exc))
        except BrokenPipeError:
            pass

    def proxy_videos(self, raw_query: str) -> None:
        """Pass the upstream recording list and its original query through."""
        url = f"{KONOMI_API}/api/videos"
        if raw_query:
            url += f"?{raw_query}"
        try:
            response = urllib.request.urlopen(url, timeout=HTTP_TIMEOUT)
        except urllib.error.HTTPError as exc:
            response = exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise FacadeError(502, "KonomiTV is unavailable") from exc

        with response:
            body = response.read()
            self.send_response(response.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

    def serve_live_playlist(self, channel: str, quality: str) -> None:
        deadline = time.monotonic() + LIVE_HLS_START_TIMEOUT
        client_key = (
            str(self.client_address[0]),
            self.headers.get("User-Agent", ""),
            channel,
            quality,
        )
        with LIVE_HLS_SESSIONS_LOCK:
            token = LIVE_HLS_CLIENT_SESSIONS.get(client_key)
            session = LIVE_HLS_SESSIONS.get(token) if token else None
            if session is not None:
                try:
                    session.touch()
                except FacadeError:
                    session = None
        if session is not None:
            self.write_live_playlist(session)
            return

        url = (f"{KONOMI_API}/api/streams/live/{channel}/"
               f"{quality}/mpegts")
        try:
            upstream = urllib.request.urlopen(
                url, timeout=max(0.1, deadline - time.monotonic())
            )
        except urllib.error.HTTPError as exc:
            exc.close()
            if exc.code == 422:
                raise FacadeError(404, "channel not found") from exc
            raise FacadeError(502, f"KonomiTV returned HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise FacadeError(502, "KonomiTV is unavailable") from exc

        session = LiveHlsSession(channel, quality, upstream, client_key)
        with LIVE_HLS_SESSIONS_LOCK:
            LIVE_HLS_SESSIONS[session.token] = session
            LIVE_HLS_CLIENT_SESSIONS[client_key] = session.token
        try:
            session.start()
            remaining = max(0.0, deadline - time.monotonic())
            if not session.wait_for_playlist(remaining, self.connection):
                if session.client_gone:
                    return
                session.close()
                raise FacadeError(502, "live HLS playlist was not generated")
            self.write_live_playlist(session)
        except (BrokenPipeError, ConnectionResetError):
            session.close()
        except OSError as exc:
            session.close()
            raise FacadeError(502, "live HLS playlist is unavailable") from exc

    def write_live_playlist(self, session: LiveHlsSession) -> None:
        try:
            body = session.playlist()
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            session.close()
        finally:
            if not session.closed:
                session.release_request()

    def serve_live_segment(self, channel: str, token: str, name: str) -> None:
        with LIVE_HLS_SESSIONS_LOCK:
            session = LIVE_HLS_SESSIONS.get(token)
        if session is None or session.channel != channel:
            raise FacadeError(404, "live playback session not found")
        session.touch()
        try:
            path = session.segment_path(name)
            try:
                source = open(path, "rb")
            except FileNotFoundError as exc:
                raise FacadeError(404, "live segment not found") from exc
            with source:
                size = os.fstat(source.fileno()).st_size
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                while True:
                    chunk = source.read(CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            log(f"live HLS {token}: client disconnected during segment")
            session.close()
        finally:
            if not session.closed:
                session.release_request()

    def proxy_live_video(self, channel: str, quality: str) -> None:
        """Stream live MPEG-TS while tying the upstream socket to this request."""
        url = (f"{KONOMI_API}/api/streams/live/{channel}/"
               f"{quality}/mpegts")
        try:
            upstream = urllib.request.urlopen(url, timeout=LIVE_CONNECT_TIMEOUT)
        except urllib.error.HTTPError as exc:
            if exc.code == 422:
                exc.close()
                raise FacadeError(404, "channel not found") from exc
            body = exc.read()
            self.send_response(exc.code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            exc.close()
            return
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise FacadeError(502, "KonomiTV is unavailable") from exc

        try:
            # Live streams can remain idle indefinitely between startup and data.
            # The 90-second timeout above applies to startup; disable it once the
            # upstream response is established.
            try:
                upstream.fp.raw._sock.settimeout(None)
            except (AttributeError, OSError):
                pass
            self.send_response(upstream.status)
            self.send_header("Content-Type", "video/mp2t")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            while True:
                chunk = upstream.read(CHUNK)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            log(f"live stream {channel}/{quality}: client disconnected")
        finally:
            upstream.close()

    def send_error_response(self, status: int, message: str) -> None:
        body = json.dumps({"error": message}, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        log(f"{self.address_string()} - {format % args}")


def main() -> int:
    if not shutil.which(FFMPEG) and not os.path.isfile(FFMPEG):
        log(f"ffmpeg not found: {FFMPEG}")
        return 1
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    log(f"audio sidecar listening on {BIND}:{PORT} (api={KONOMI_API})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
