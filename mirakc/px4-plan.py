#!/usr/bin/env python3
"""`px4d --list-json` の出力を検証し、同梱チューナー定義を組み立てる計画を出す。

1筐体につき enclosures の1要素、物理受信機1基につき slots の1要素を出力する。
出力は空白区切りの内部形式で、mirakc の起動スクリプトと実効設定生成が読む。

  enclosure MODEL_KEY MODEL_NAME INSTANCE SERIAL USBPATHS BRIDGES
  slot MODEL_KEY MODEL_NAME INSTANCE SERIAL RECEIVER SYSTEMS

USBPATHS は `--usb-path` へ渡す順のカンマ区切り、SYSTEMS は T/S/TS のいずれか。
"""

import argparse
import json
import re
import sys
from pathlib import Path

# px4d の model (筐体行の model=) から、同梱チューナー定義に使う
# profile キーと USB ブリッジ数への対応。キーは model 名を小文字化して
# `-` を `_` に置き換えたものと一致する。
MODEL_BRIDGES = {
    "PX-Q3U4": 2,
    "PX-Q3PE4": 2,
    "PX-Q3PE5": 2,
    "PX-W3U4": 1,
    "PX-W3PE4": 1,
    "PX-W3PE5": 1,
    "PX-MLT5PE": 1,
    "DTV02A-5TS-P": 1,
    "PX-MLT8PE3": 1,
    "PX-MLT8PE5": 1,
    "DTV02A-4TS-P": 1,
    "PX-M1UR": 1,
    "PX-S1UR": 1,
    "DTV03A-1TU": 1,
    "DTV02-1T1S-U": 1,
    "DTV02A-1T1S-U": 1,
}
MODEL_RECEIVERS = {
    "PX-Q3U4": 8,
    "PX-Q3PE4": 8,
    "PX-Q3PE5": 8,
    "PX-W3U4": 4,
    "PX-W3PE4": 4,
    "PX-W3PE5": 4,
    "PX-MLT5PE": 5,
    "DTV02A-5TS-P": 5,
    "PX-MLT8PE3": 3,
    "PX-MLT8PE5": 5,
    "DTV02A-4TS-P": 4,
    "PX-M1UR": 1,
    "PX-S1UR": 1,
    "DTV03A-1TU": 1,
    "DTV02-1T1S-U": 1,
    "DTV02A-1T1S-U": 1,
}
SYSTEM_CODES = {
    "ISDB-T": "T",
    "ISDB-S": "S",
    "ISDB-T/S": "TS",
}
USB_PATH = re.compile(r"^[0-9]+(?:-[0-9]+(?:\.[0-9]+)*|:[0-9]+)$")


class PlanError(Exception):
    """列挙結果を安全な計画へ変換できない。"""


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-json", required=True, type=Path)
    parser.add_argument("--plan", required=True, type=Path)
    return parser.parse_args()


def read_json(path):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise PlanError(f"could not read px4d --list-json output {path}: {exc}") from exc
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise PlanError(f"px4d --list-json output is not valid JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise PlanError("px4d --list-json output must be a JSON object")
    enclosures = document.get("enclosures")
    ungrouped = document.get("ungrouped_usb_devices")
    if not isinstance(enclosures, list) or not isinstance(ungrouped, list):
        raise PlanError("px4d --list-json output must contain enclosures and ungrouped_usb_devices arrays")
    return enclosures, ungrouped


def model_key(model):
    return model.lower().replace("-", "_")


def check_usb_path(value, description):
    if not isinstance(value, str) or USB_PATH.fullmatch(value) is None:
        raise PlanError(f"invalid USB path ({description}): {value!r}")
    return value


def check_device_count(entry, bridges, description):
    devices = entry.get("devices")
    candidates = entry.get("candidates")
    if not isinstance(devices, list) or not isinstance(candidates, list):
        raise PlanError(f"enclosure has no devices/candidates arrays ({description})")
    status = entry.get("status")
    if status == "ready" and not candidates:
        selected = devices
    elif status == "duplicate" and not devices and len(candidates) == bridges:
        # M1UR and S1UR intentionally share a USB serial. px4d reports each
        # model group as duplicate, but one candidate per distinct model is
        # still uniquely selectable by its exact USB path.
        selected = candidates
    else:
        raise PlanError(
            f"enclosure status/candidate set cannot be selected safely ({description}): "
            f"status={status!r} devices={len(devices)} candidates={len(candidates)}"
        )
    if len(selected) != bridges:
        raise PlanError(
            f"enclosure has {len(selected)} USB device(s), expected {bridges} ({description})"
        )
    paths = {}
    seen_paths = set()
    for device in selected:
        if not isinstance(device, dict):
            raise PlanError(f"malformed device record ({description})")
        index = device.get("device")
        if index not in range(1, bridges + 1):
            raise PlanError(f"unexpected USB device id ({description}): {index!r}")
        if index in paths:
            raise PlanError(f"duplicate USB device id ({description}): {index}")
        path = device.get("port")
        if path is None:
            bus = device.get("bus")
            address = device.get("address")
            if (
                not isinstance(bus, int)
                or isinstance(bus, bool)
                or not isinstance(address, int)
                or isinstance(address, bool)
            ):
                raise PlanError(
                    f"USB location has neither port nor numeric bus/address "
                    f"({description} dev{index})"
                )
            path = f"{bus}:{address}"
        path = check_usb_path(path, f"{description} dev{index}")
        if path in seen_paths:
            raise PlanError(f"duplicate USB path ({description}): {path}")
        seen_paths.add(path)
        paths[index] = path
    return [paths[index] for index in range(1, bridges + 1)]


def check_receivers(entry, description, expected_count):
    receivers = entry.get("receivers")
    if not isinstance(receivers, list) or not receivers:
        raise PlanError(f"enclosure has no receiver table ({description})")
    slots = []
    seen = set()
    for record in receivers:
        if not isinstance(record, dict):
            raise PlanError(f"malformed receiver record ({description})")
        receiver = record.get("receiver")
        if not isinstance(receiver, int) or isinstance(receiver, bool) or receiver < 0:
            raise PlanError(f"invalid receiver id ({description}): {receiver!r}")
        if receiver in seen:
            raise PlanError(f"duplicate receiver id ({description}): {receiver}")
        seen.add(receiver)
        systems = SYSTEM_CODES.get(record.get("system"))
        if systems is None:
            raise PlanError(
                f"unknown receiver system ({description}): {record.get('system')!r}"
            )
        slots.append((receiver, systems))
    if len(slots) != expected_count:
        raise PlanError(
            f"enclosure has {len(slots)} receiver(s), expected {expected_count} ({description})"
        )
    if seen != set(range(len(receivers))):
        raise PlanError(f"receiver ids are not contiguous from 0 ({description})")
    return slots


def build_plan(enclosures, ungrouped):
    if ungrouped:
        raise PlanError(
            "a PX4 USB device could not be assigned to an enclosure; "
            "reconnect or free it and restart"
        )

    serial_groups = {}
    for position, entry in enumerate(enclosures, start=1):
        if not isinstance(entry, dict):
            raise PlanError(f"malformed enclosure record #{position}")
        serial = entry.get("serial")
        if isinstance(serial, str):
            serial_groups.setdefault(serial, []).append(entry)

    plan = []
    selected = set()
    selected_usb_paths = set()
    for position, entry in enumerate(enclosures, start=1):
        if not isinstance(entry, dict):
            raise PlanError(f"malformed enclosure record #{position}")
        model = entry.get("model")
        bridges = MODEL_BRIDGES.get(model)
        if bridges is None:
            raise PlanError(f"unsupported PX4 enclosure model: {model!r}")
        status = entry.get("status")
        if status not in ("ready", "duplicate"):
            raise PlanError(f"PX4 enclosure is not ready ({model}): status={status!r}")
        description = f"{model} serial={entry.get('serial')!r}"
        serial = entry.get("serial")
        if not isinstance(serial, str) or re.fullmatch(
            r"[0-9]{%d}" % (14 if bridges == 2 else 15), serial
        ) is None:
            raise PlanError(f"invalid PX4 serial ({description})")
        identity = (model, serial)
        if identity in selected:
            raise PlanError(
                f"multiple ready enclosures share model and serial and cannot be "
                f"distinguished: {model} serial={serial}"
            )
        selected.add(identity)
        if status == "duplicate":
            same_serial = serial_groups.get(serial, [])
            if (
                len(same_serial) != 2
                or len({candidate.get("model") for candidate in same_serial}) != 2
                or any(candidate.get("status") != "duplicate" for candidate in same_serial)
            ):
                raise PlanError(
                    f"duplicate serial cannot be uniquely resolved across models: "
                    f"serial={serial}"
                )

        paths = check_device_count(entry, bridges, description)
        overlap = selected_usb_paths.intersection(paths)
        if overlap:
            raise PlanError(
                f"USB path is claimed by multiple enclosure models ({description}): "
                f"{sorted(overlap)!r}"
            )
        selected_usb_paths.update(paths)
        slots = check_receivers(entry, description, MODEL_RECEIVERS[model])

        key = model_key(model)
        instance = f"px4-{key}-{serial}"
        plan.append(
            ("enclosure", key, model, instance, serial, ",".join(paths), str(bridges))
        )
        for receiver, systems in slots:
            plan.append(("slot", key, model, instance, serial, str(receiver), systems))
    return plan


def write_plan(plan, path):
    try:
        path.write_text(
            "".join(" ".join(fields) + "\n" for fields in plan), encoding="utf-8"
        )
    except OSError as exc:
        raise PlanError(f"could not write PX4 plan {path}: {exc}") from exc


def main():
    args = parse_args()
    enclosures, ungrouped = read_json(args.list_json)
    plan = build_plan(enclosures, ungrouped)
    write_plan(plan, args.plan)
    slots = sum(1 for fields in plan if fields[0] == "slot")
    print(
        f"px4 plan: enclosures={len(enclosures)} slots={slots} plan={args.plan}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PlanError as exc:
        print(f"px4 plan generation failed: {exc}", file=sys.stderr)
        sys.exit(1)
