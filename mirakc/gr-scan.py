#!/usr/bin/env python3
"""受信可能な地上波チャンネルを走査して mirakc の channels 形式で出力する。

px4-ts-stream / px-s1ud-stream が吐く TS を mirakc-arib scan-services に
通して、放送中のサービスと名前（ARIB デコード済み）を得る。

使い方:
  gr-scan.py --px4-bin /usr/local/bin/px4-ts-stream --px4-model px_q3u4
  gr-scan.py --siano-bin /usr/local/bin/px-s1ud-stream --siano-adapter 0
  gr-scan.py ... --replace-config /config/config.yml
"""

import argparse
import json
import os
import re
import select
import subprocess
import sys
import time

DEFAULT_CHANNELS = [f"T{n}" for n in range(13, 63)]
CAPTURE_SECONDS = 12.0

# モデルごとの最初の地上波受信機番号
PX4_GR_RECEIVER = {
    "px_q3u4": 2, "px_q3pe4": 2, "px_q3pe5": 2,
    "px_w3u4": 2, "px_w3pe4": 2, "px_w3pe5": 2,
    "px_mlt5pe": 0, "dtv02a_5ts_p": 0, "px_mlt8pe5": 0,
    "px_mlt8pe3": 0,
    "dtv02a_4ts_p": 0,
    "px_m1ur": 0, "px_s1ur": 0, "dtv03a_1tu": 0,
    "dtv02_1t1s_u": 0, "dtv02a_1t1s_u": 0,
}


def channel_name(services: list) -> str:
    """先頭の TV サービス名からチャンネル名を作る。"""
    tv = [s for s in services if s.get("type") == 1]
    src = tv[0] if tv else services[0]
    name = src.get("name") or f"GR {src.get('sid')}"
    name = re.sub(r"[0-9０-９]+$", "", name)
    name = name.replace("　", " ").rstrip(" ・.")
    return name or (src.get("name") or "")


def scan_channel(args, channel: str) -> list:
    """1チャンネル分を走査してサービス一覧（dict）を返す。"""
    import tempfile

    ts_path = None
    stream = subprocess.Popen(
        list(args.stream_cmd) + [channel],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=args.stream_env,
    )
    # まず TS を一時ファイルへ受ける。パイプ直結だと mirakc-arib が
    # stdin からテーブルを拾えない環境があるため。
    data = bytearray()
    deadline = time.monotonic() + args.capture_seconds
    last_data = time.monotonic()
    try:
        while time.monotonic() < deadline and len(data) < 12 * 1024 * 1024:
            ready, _, _ = select.select([stream.stdout], [], [], 0.5)
            if not ready:
                # 4秒間データが来なければ空きチャンネルとみなして打ち切る。
                # px4-ts は同調失敗で約10秒待つため、これを待たずに次へ進む。
                if time.monotonic() - last_data > 4.0:
                    break
                continue
            chunk = stream.stdout.read(188 * 1024)
            if not chunk:
                break
            data.extend(chunk)
            last_data = time.monotonic()
            if stream.poll() is not None and data:
                break
    except Exception as exc:
        print(f"scan {channel}: stream read error {exc!r}", file=sys.stderr)
    finally:
        if stream.poll() is None:
            stream.terminate()
            try:
                stream.wait(timeout=3)
            except Exception:
                stream.kill()
    stream_err = stream.stderr.read() if stream.stderr is not None else b""

    services = []
    if data:
        try:
            fd, ts_path = tempfile.mkstemp(prefix="gr-scan-", suffix=".ts", dir="/tmp")
            with os.fdopen(fd, "wb") as f:
                f.write(bytes(data))
            arib = subprocess.run(
                [args.arib_bin, "scan-services", ts_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=args.stream_env,
                timeout=30,
            )
            for line in arib.stdout.decode("utf-8", errors="replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, list):
                    for item in obj:
                        if isinstance(item, dict) and item.get("name"):
                            services.append(item)
                elif isinstance(obj, dict) and obj.get("name"):
                    services.append(obj)
        except Exception as exc:
            print(f"scan {channel}: arib error {exc!r}", file=sys.stderr)
        finally:
            if ts_path:
                try:
                    os.unlink(ts_path)
                except OSError:
                    pass
    if not services:
        print(
            f"debug {channel}: stream_stderr={stream_err.decode(errors='replace')[:120]!r}",
            file=sys.stderr,
        )
    return services


def emit_channels(found: list) -> str:
    lines = []
    for channel, services in found:
        lines.append(f"  - name: {channel_name(services)}")
        lines.append("    type: GR")
        lines.append(f"    channel: {channel}")
    return "\n".join(lines)


def replace_gr_channels(config_path: str, found: list) -> bool:
    """config.yml の channels 先頭の GR ブロックを走査結果で差し替える。

    テンプレートの GR ブロックは channels: の直後から最初の type: BS/CS の
    直前まで。コメントや BS/CS 以降は触らない。
    """
    from pathlib import Path

    path = Path(config_path)
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("channels:")) + 1
    except StopIteration:
        return False
    end = None
    for i in range(start, len(lines)):
        stripped = lines[i].strip()
        if stripped in ("type: BS", "type: CS", "type: SKY"):
            end = i - 2  # そのエントリの name 行の前まで
            break
    if end is None or end < start:
        return False
    block = []
    for channel, services in found:
        block.append(f"  - name: {channel_name(services)}")
        block.append("    type: GR")
        block.append(f"    channel: {channel}")
    # end は最後の GR エントリの channel 行を指す。その次（最初の BS/CS の
    # name 行）から後を残す。
    new_lines = lines[:start] + block + lines[end + 1:]
    path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--px4-bin")
    parser.add_argument("--px4-model")
    parser.add_argument("--siano-bin")
    parser.add_argument("--siano-adapter", default="0")
    parser.add_argument("--arib-bin", default=os.environ.get("MIRAKC_ARIB", "mirakc-arib"))
    parser.add_argument("--channels", nargs="*", default=DEFAULT_CHANNELS)
    parser.add_argument("--replace-config")
    parser.add_argument("--capture-seconds", type=float, default=CAPTURE_SECONDS)
    args = parser.parse_args()

    env = os.environ.copy()
    if args.px4_bin and args.px4_model:
        receiver = PX4_GR_RECEIVER.get(args.px4_model)
        if receiver is None:
            print(f"unknown px4 model: {args.px4_model}", file=sys.stderr)
            return 2
        args.stream_cmd = [args.px4_bin]
        env["PX4_PROFILE"] = args.px4_model
        env["PX4_RECEIVER"] = str(receiver)
    elif args.siano_bin:
        args.stream_cmd = [args.siano_bin]
        env["PX_S1UD_ADAPTER"] = args.siano_adapter
    else:
        print("either --px4-bin/--px4-model or --siano-bin is required", file=sys.stderr)
        return 2
    args.stream_env = env

    found = []
    for channel in args.channels:
        services = scan_channel(args, channel)
        if services:
            found.append((channel, services))
            print(f"found {channel}: {channel_name(services)}", file=sys.stderr)

    if not found:
        print("no GR services found", file=sys.stderr)
        return 1

    if args.replace_config:
        if replace_gr_channels(args.replace_config, found):
            print(f"replaced GR channels in {args.replace_config}", file=sys.stderr)
            return 0
        print("failed to replace GR channels", file=sys.stderr)
        return 1

    print(emit_channels(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
