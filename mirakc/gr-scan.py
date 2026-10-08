#!/usr/bin/env python3
"""受信可能な地上波チャンネルを走査して mirakc の channels 形式で出力する。

px4-ts / siano-ts が吐く TS を mirakc-arib scan-services に
通して、放送中のサービスと名前（ARIB デコード済み）を得る。

使い方:
  gr-scan.py --px4-bin /usr/local/bin/px4-ts --px4-instance INSTANCE --px4-receiver 2
  gr-scan.py --siano-bin /usr/local/bin/siano-ts --siano-adapter 0
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

from tuner_commands import CHANNEL, px4_command, siano_command

# Japanese terrestrial broadcasting uses UHF 13..52; higher channels are
# still accepted by the driver and can be requested explicitly via --channels.
DEFAULT_CHANNELS = [f"T{n}" for n in range(13, 53)]
CAPTURE_SECONDS = 12.0

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
    if args.settle_seconds:
        time.sleep(args.settle_seconds)
    stream = subprocess.Popen(
        [channel if arg == CHANNEL else arg for arg in args.stream_cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=args.stream_env,
    )
    # まず TS を一時ファイルへ受ける。パイプ直結だと mirakc-arib が
    # stdin からテーブルを拾えない環境があるため。
    data = bytearray()
    deadline = time.monotonic() + args.capture_seconds
    try:
        while time.monotonic() < deadline and len(data) < 12 * 1024 * 1024:
            ready, _, _ = select.select([stream.stdout], [], [], 0.5)
            if not ready:
                continue
            chunk = stream.stdout.read(188 * 1024)
            if not chunk:
                break
            data.extend(chunk)
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
                stream.wait()
    stream_err = stream.stderr.read() if stream.stderr is not None else b""
    stream.stdout.close()
    stream.stderr.close()

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
    """config.yml の先頭の GR ブロックを走査結果で差し替える。

    既存 GR ブロックがなければ、最初の BS/CS 項目の直前へ走査結果を挿入する。
    BS/CS 以降は触らない。
    """
    from pathlib import Path

    path = Path(config_path)
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("channels:")) + 1
    except StopIteration:
        return False
    first_satellite_type = None
    for i in range(start, len(lines)):
        stripped = lines[i].strip()
        if stripped in ("type: BS", "type: CS", "type: SKY"):
            first_satellite_type = i
            break
    if first_satellite_type is None:
        return False
    block = []
    for channel, services in found:
        block.append(f"  - name: {channel_name(services)}")
        block.append("    type: GR")
        block.append(f"    channel: {channel}")
    first_satellite_name = first_satellite_type - 1
    has_gr_seed = any(
        lines[i].strip() == "type: GR" for i in range(start, first_satellite_name)
    )
    if has_gr_seed:
        # 最初の衛星局の name 行より前が既存のGRシード。
        new_lines = lines[:start] + block + lines[first_satellite_name:]
    else:
        # GRシードなしのテンプレートには、BS/CS局を残して走査結果を挿入。
        new_lines = lines[:first_satellite_name] + block + lines[first_satellite_name:]
    path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
    return True


def stream_command(args):
    """Use the actual selected receiver; do not infer it from the model."""
    if args.px4_bin:
        return px4_command(CHANNEL, instance=args.px4_instance, device=args.px4_device,
                           receiver=args.px4_receiver, binary=args.px4_bin,
                           runtime_dir=args.runtime_dir)
    return siano_command(CHANNEL, device=args.siano_adapter, binary=args.siano_bin,
                         firmware=args.siano_firmware)


def main() -> int:
    parser = argparse.ArgumentParser()
    drivers = parser.add_mutually_exclusive_group(required=True)
    drivers.add_argument("--px4-bin")
    drivers.add_argument("--siano-bin")
    parser.add_argument("--px4-model", help=argparse.SUPPRESS)  # old callers; selection uses the plan
    parser.add_argument("--px4-instance", default=os.environ.get("PX4_INSTANCE"))
    parser.add_argument("--px4-device", default=os.environ.get("PX4_DEVICE"))
    parser.add_argument("--px4-receiver", default=os.environ.get("PX4_RECEIVER"))
    parser.add_argument("--runtime-dir", default=os.environ.get("PX4_RUNTIME_DIR"))
    parser.add_argument("--siano-adapter", default="0")
    parser.add_argument("--siano-firmware", default=os.environ.get("PX_S1UD_FIRMWARE"))
    parser.add_argument("--arib-bin", default=os.environ.get("MIRAKC_ARIB", "mirakc-arib"))
    parser.add_argument("--channels", nargs="*", default=DEFAULT_CHANNELS)
    parser.add_argument("--replace-config")
    parser.add_argument("--capture-seconds", type=float, default=CAPTURE_SECONDS)
    args = parser.parse_args()

    try:
        args.stream_cmd = stream_command(args)
        args.settle_seconds = float(os.environ.get("PX_S1UD_SETTLE_SECONDS", "0")) if args.siano_bin else 0
        if args.settle_seconds < 0:
            raise ValueError("PX_S1UD_SETTLE_SECONDS must not be negative")
    except ValueError as exc:
        parser.error(str(exc))
    args.stream_env = os.environ.copy()

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
