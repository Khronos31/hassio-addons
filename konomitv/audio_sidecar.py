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
  KONOMI_API                 KonomiTV server base URL (default http://127.0.0.1:7000)
  KONOMI_FFMPEG              FFmpeg binary (default /code/server/thirdparty/FFmpeg/ffmpeg.elf)
  KONOMI_AUDIO_BIND          bind address (default 0.0.0.0)
  KONOMI_AUDIO_PORT          listen port (default 7002)
  KONOMI_AUDIO_LIVE_QUALITY  default live quality (default 720p)
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KONOMI_API = os.environ.get("KONOMI_API", "http://127.0.0.1:7000").rstrip("/")
FFMPEG = os.environ.get(
    "KONOMI_FFMPEG", "/code/server/thirdparty/FFmpeg/ffmpeg.elf"
)
BIND = os.environ.get("KONOMI_AUDIO_BIND", "0.0.0.0")
PORT = int(os.environ.get("KONOMI_AUDIO_PORT", "7002"))
LIVE_QUALITY = os.environ.get("KONOMI_AUDIO_LIVE_QUALITY", "720p")

AUDIO_OPTS = [
    "-vn", "-sn", "-dn",
    "-map", "0:a:0?",
    "-c:a", "libmp3lame",
    "-b:a", "128k",
    "-f", "mp3",
    "pipe:1",
]

CHUNK = 64 * 1024


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
        except (LookupError, urllib.error.URLError) as exc:
            log(f"{path}: {exc}")
            self.send_error(404, str(exc))
        except BrokenPipeError:
            pass

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
