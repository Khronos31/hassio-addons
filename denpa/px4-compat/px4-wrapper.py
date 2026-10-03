#!/usr/bin/python3
"""Bridge Denpa's serial-keyed px4 API to px4-userland's path/instance API."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
from typing import Any


REAL_DIR = pathlib.Path(os.environ.get("PX4_REAL_USERLAND_DIR", "/opt/px4-compat-real"))
MAP_FILE = pathlib.Path(
    os.environ.get("PX4_COMPAT_MAP", "/run/px4-userland/denpa-serial-map.json")
)
RUNTIME_DIR = pathlib.Path(os.environ.get("PX4_RUNTIME_DIR", "/run/px4-userland"))


def read_map() -> dict[str, dict[str, Any]]:
    try:
        items = json.loads(MAP_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    return {item["id"]: item for item in items}


def usb_paths(enclosure: dict[str, Any]) -> list[str] | None:
    devices = enclosure.get("devices")
    if not isinstance(devices, list) or not devices or len(devices) > 2:
        return None
    ordered = sorted(devices, key=lambda item: item.get("device", 0))
    paths: list[str] = []
    for device in ordered:
        port = device.get("port")
        if isinstance(port, str) and port:
            path = port
        elif isinstance(device.get("bus"), int) and isinstance(device.get("address"), int):
            path = f"{device['bus']}:{device['address']}"
        else:
            return None
        paths.append(path)
    return paths


def make_aliases(document: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    enclosures = document.get("enclosures")
    if not isinstance(enclosures, list):
        return document, []

    # Denpa displays the last four ID digits in the internal-card-reader name.
    # Reserve existing suffixes so synthetic IDs remain distinct in that UI too.
    occupied_suffixes = {
        str(item.get("serial", ""))[-4:]
        for item in enclosures
        if item.get("serial_unique") is True
    }
    eligible: list[tuple[int, dict[str, Any], list[str]]] = []
    for index, enclosure in enumerate(enclosures):
        if enclosure.get("status") != "ready" or enclosure.get("serial_unique") is not False:
            continue
        serial = enclosure.get("serial")
        model = enclosure.get("model")
        paths = usb_paths(enclosure)
        if not isinstance(serial, str) or not serial.isdigit() or not isinstance(model, str) or not paths:
            continue
        eligible.append((index, enclosure, paths))

    # Sorting by observed identity and USB topology makes aliases stable across
    # repeated --list-json calls regardless of libusb enumeration order.
    eligible.sort(key=lambda row: (row[1]["model"], row[1]["serial"], row[2]))
    aliases: list[dict[str, Any]] = []
    for index, enclosure, paths in eligible:
        serial = enclosure["serial"]
        model = enclosure["model"]
        identity = f"{model}|{serial}|{'|'.join(paths)}"
        salt = 0
        while True:
            digest = hashlib.sha256(f"{identity}|{salt}".encode("utf-8")).hexdigest()
            suffix = f"{int(digest[-8:], 16) % 10000:04d}"
            if suffix not in occupied_suffixes:
                break
            salt += 1
            if salt > 10000:
                raise RuntimeError("synthetic tuner ID suffix space is exhausted")

        occupied_suffixes.add(suffix)
        alias = f"9999999999999{suffix}"
        token = f"denpa-{digest[:24]}"
        aliases.append(
            {
                "id": alias,
                "serial": serial,
                "model": model,
                "paths": paths,
                "instance": token,
                "index": index,
            }
        )

    rewritten = json.loads(json.dumps(document))
    for alias in aliases:
        enclosure = rewritten["enclosures"][alias["index"]]
        enclosure["serial"] = alias["id"]
        enclosure["serial_unique"] = True
        print(
            f"[px4-compat] {alias['model']} {alias['serial']} USB {' / '.join(alias['paths'])} "
            f"を Denpa ID {alias['id']} / instance {alias['instance']} に割り当てます",
            file=sys.stderr,
        )
        del alias["index"]

    return rewritten, aliases


def write_map(aliases: list[dict[str, Any]]) -> None:
    MAP_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=".denpa-serial-map-", dir=MAP_FILE.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(aliases, stream, separators=(",", ":"))
            stream.write("\n")
        os.replace(temp_name, MAP_FILE)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def list_json(real_binary: pathlib.Path) -> int:
    result = subprocess.run([str(real_binary), "--list-json"], capture_output=True, check=False)
    sys.stderr.buffer.write(result.stderr)
    if result.returncode != 0:
        sys.stdout.buffer.write(result.stdout)
        return result.returncode
    try:
        document = json.loads(result.stdout)
        rewritten, aliases = make_aliases(document)
        write_map(aliases)
    except (UnicodeDecodeError, json.JSONDecodeError, RuntimeError, OSError, TypeError, KeyError) as error:
        print(f"[px4-compat] --list-json の別名処理に失敗しました: {error}", file=sys.stderr)
        sys.stdout.buffer.write(result.stdout)
        return 0
    sys.stdout.write(json.dumps(rewritten, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


def option_value(args: list[str], option: str, default: str) -> str:
    for index, value in enumerate(args[:-1]):
        if value == option:
            return args[index + 1]
    return default


def with_instance(args: list[str], alias: dict[str, Any]) -> list[str]:
    rewritten: list[str] = []
    index = 0
    while index < len(args):
        value = args[index]
        if value in ("--device", "--instance") and index + 1 < len(args):
            index += 2
            continue
        if value == "--usb-path" and index + 1 < len(args):
            index += 2
            continue
        rewritten.append(value)
        index += 1
    return [*rewritten, "--device", alias["serial"], *sum((["--usb-path", path] for path in alias["paths"]), []), "--instance", alias["instance"]]


def run_aliased_daemon(real_binary: pathlib.Path, args: list[str], alias: dict[str, Any]) -> int:
    runtime = pathlib.Path(option_value(args, "--runtime-dir", str(RUNTIME_DIR)))
    socket_root = runtime / "px4-userland"
    try:
        socket_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if socket_root.is_symlink() or not socket_root.is_dir():
            raise OSError("ソケットディレクトリが通常のディレクトリではありません")
        # mkdir の mode は umask の影響を受ける。px4-userland は既存の
        # product directory も 0700 と照合するため、ここで正確に設定する。
        socket_root.chmod(0o700)
    except OSError as error:
        print(f"[px4-compat] ソケットディレクトリを準備できません: {socket_root}: {error}", file=sys.stderr)
        return 73
    alias_path = socket_root / alias["id"]
    created_alias = False
    if alias_path.is_symlink():
        # 自分の instance を指すリンクは再利用する。別の実体を指すリンクは
        # 他が使っているかもしれないので触らずに諦める。
        if os.readlink(alias_path) != alias["instance"]:
            print(f"[px4-compat] 別名ソケットの場所が別の実体を指しています: {alias_path}", file=sys.stderr)
            return 73
    elif alias_path.exists():
        print(f"[px4-compat] 別名ソケットの場所が既存ディレクトリです: {alias_path}", file=sys.stderr)
        return 73
    else:
        alias_path.symlink_to(alias["instance"], target_is_directory=True)
        created_alias = True

    try:
        command = with_instance(args, alias)
        child = subprocess.Popen([str(real_binary), *command])

        def forward(signum: int, _frame: Any) -> None:
            if child.poll() is None:
                child.send_signal(signum)

        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, forward)
        return child.wait()
    finally:
        if created_alias and alias_path.is_symlink() and os.readlink(alias_path) == alias["instance"]:
            alias_path.unlink()


def rewrite_client(args: list[str], aliases: dict[str, dict[str, Any]]) -> list[str]:
    rewritten: list[str] = []
    index = 0
    while index < len(args):
        value = args[index]
        if value == "--device" and index + 1 < len(args) and args[index + 1] in aliases:
            rewritten.extend(("--instance", aliases[args[index + 1]]["instance"]))
            index += 2
        else:
            rewritten.append(value)
            index += 1
    return rewritten


def main() -> int:
    command_name = pathlib.Path(sys.argv[0]).name
    real_binary = REAL_DIR / command_name
    args = sys.argv[1:]
    if not real_binary.is_file():
        print(f"[px4-compat] px4-userland の実行ファイルがありません: {real_binary}", file=sys.stderr)
        return 127

    if command_name == "px4d" and args == ["--list-json"]:
        return list_json(real_binary)

    aliases = read_map()
    if command_name == "px4d":
        device = option_value(args, "--device", "")
        if device in aliases:
            return run_aliased_daemon(real_binary, args, aliases[device])
    elif command_name == "px4ctl":
        args = rewrite_client(args, aliases)

    os.execv(str(real_binary), [str(real_binary), *args])
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
