#!/usr/bin/env python3
"""Build the mirakc configuration for the hardware available at runtime."""

import argparse
import getopt
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

import yaml

from tuner_commands import CHANNEL, PX4_BIN, SIANO_BIN, px4_command, siano_command


SIANO_WRAPPER = "/usr/local/bin/px-s1ud-stream"
Q3U4_WRAPPER = "/usr/local/bin/px4-ts-stream"
SIANO_ASSIGNMENT_PREFIX = "PX_S1UD_ADAPTER="
Q3U4_ASSIGNMENT_PREFIX = "PX4_RECEIVER="
SIANO_ASSIGNMENT = re.compile(r"^PX_S1UD_ADAPTER=([0-9]+)$")
Q3U4_ASSIGNMENT = re.compile(r"^PX4_RECEIVER=([0-9]+)$")
SUPPORTED_RIO_IDS = frozenset(("3275:0080", "187f:0600", "187f:0302"))
KNOWN_SIANO_VENDORS = frozenset(("3275", "187f"))
PX4_MODELS = frozenset((
    "px_q3u4", "px_q3pe4", "px_q3pe5",
    "px_w3u4", "px_w3pe4", "px_w3pe5",
    "px_mlt5pe", "dtv02a_5ts_p", "px_mlt8pe3", "px_mlt8pe5", "dtv02a_4ts_p",
    "px_m1ur", "px_s1ur", "dtv03a_1tu", "dtv02_1t1s_u", "dtv02a_1t1s_u",
))
PX4_RECEIVER_UPPER_BOUND = {
    "px_q3u4": 7, "px_q3pe4": 7, "px_q3pe5": 7,
    "px_w3u4": 3, "px_w3pe4": 3, "px_w3pe5": 3,
    "px_mlt5pe": 4, "dtv02a_5ts_p": 4, "px_mlt8pe5": 4,
    "px_mlt8pe3": 2,
    "dtv02a_4ts_p": 3,
    "px_m1ur": 0, "px_s1ur": 0, "dtv03a_1tu": 0,
    "dtv02_1t1s_u": 0, "dtv02a_1t1s_u": 0,
}
SIANO_DEVICE = re.compile(
    r"^([0-9]+|-):\s+([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})(?:\s+.*)?$"
)
SIANO_SUMMARY = re.compile(
    r"^([0-9]+) supported RIO device\(s\), "
    r"([0-9]+) known Siano device\(s\)$"
)
SIANO_KV_RECEIVER = re.compile(
    r"^receiver=([0-9]+) device=([0-9]+) local=([0-9]+) system=ISDB-[TS]$"
)


class ConfigError(Exception):
    """An input or output cannot safely produce an effective config."""


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--siano-list", required=True, type=Path)
    parser.add_argument("--warmup-file", required=True, type=Path)
    parser.add_argument("--q3u4-enabled", choices=("0", "1"), required=True)
    parser.add_argument(
        "--px4-model", choices=tuple(sorted(PX4_MODELS)), default="px_q3u4"
    )
    parser.add_argument("--px4-plan", type=Path)
    parser.add_argument("--siano-wrapper", default=SIANO_WRAPPER)
    parser.add_argument("--q3u4-wrapper", default=Q3U4_WRAPPER)
    parser.add_argument("--px4-bin", default=os.environ.get("PX4_TS_BIN", PX4_BIN))
    parser.add_argument("--siano-bin", default=os.environ.get("SIANO_TS_BIN", SIANO_BIN))
    parser.add_argument("--runtime-dir", default=os.environ.get("PX4_RUNTIME_DIR"))
    parser.add_argument("--siano-firmware", default=os.environ.get("PX_S1UD_FIRMWARE"))
    return parser.parse_args()


def read_text(path, description):
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ConfigError(f"could not read {description} {path}: {exc}") from exc


def parse_siano_adapters(path):
    lines = [line.strip() for line in read_text(path, "Siano --list output").splitlines()]
    lines = [line for line in lines if line]
    if not lines:
        # v0.1.9 emits no text when no compatible RIO device is attached.
        return []

    if lines[-1] == "0 devices":
        if len(lines) != 1:
            raise ConfigError("Siano --list output contradicts its 0 devices summary")
        return []

    if lines[0].startswith("model=") or lines[0].startswith("rejected "):
        # v0.1.9 uses one key=value line per device, followed by receiver
        # detail lines. Device indices are the emitted order of supported RIOs.
        adapters = []
        last_line_was_device = False
        for line in lines:
            if line.startswith("receiver="):
                if not last_line_was_device or SIANO_KV_RECEIVER.fullmatch(line) is None:
                    raise ConfigError(f"malformed Siano --list receiver line: {line}")
                last_line_was_device = False
                continue

            rejected = line.startswith("rejected ")
            fields = {}
            for item in line.removeprefix("rejected ").split():
                key, separator, value = item.partition("=")
                if not separator or key in fields:
                    raise ConfigError(f"malformed Siano --list device line: {line}")
                fields[key] = value
            expected_fields = {"model", "usb", "bus", "address", "port", "status"}
            if not rejected:
                expected_fields.add("receivers")
            if set(fields) != expected_fields:
                raise ConfigError(f"malformed Siano --list device line: {line}")
            if not fields["bus"].isdigit() or not fields["address"].isdigit():
                raise ConfigError(f"malformed Siano --list USB location: {line}")
            if fields["port"] != "-" and re.fullmatch(
                r"[0-9]+-[0-9]+(?:\.[0-9]+)*", fields["port"]
            ) is None:
                raise ConfigError(f"malformed Siano --list USB port: {line}")
            usb_match = re.fullmatch(
                r"([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})", fields["usb"]
            )
            if usb_match is None:
                raise ConfigError(f"malformed Siano --list USB ID: {line}")
            vendor, product = (part.lower() for part in usb_match.groups())
            device_id = f"{vendor}:{product}"

            if device_id in SUPPORTED_RIO_IDS:
                if rejected or not fields["model"] or fields["status"] != "ready":
                    raise ConfigError(f"supported Siano device is not ready: {line}")
                if fields["receivers"] != "1":
                    raise ConfigError(f"unexpected Siano receiver count: {line}")
                adapters.append(len(adapters))
            elif vendor in KNOWN_SIANO_VENDORS:
                if (
                    not rejected
                    or not fields["model"]
                    or fields["status"] != "unsupported"
                ):
                    raise ConfigError(f"unsupported Siano device was not rejected: {line}")
            else:
                raise ConfigError(f"unknown USB vendor in Siano --list output: {line}")
            last_line_was_device = not rejected
        return adapters

    summary = SIANO_SUMMARY.fullmatch(lines[-1])
    if summary is None:
        raise ConfigError(f"malformed Siano --list summary: {lines[-1]}")
    supported = int(summary.group(1))
    known = int(summary.group(2))
    adapters = []
    for line in lines[:-1]:
        device = SIANO_DEVICE.fullmatch(line)
        if device is None:
            raise ConfigError(f"malformed Siano --list device line: {line}")
        device_id = f"{device.group(2).lower()}:{device.group(3).lower()}"
        if device.group(1) == "-":
            if device.group(2).lower() not in KNOWN_SIANO_VENDORS:
                raise ConfigError(f"dashed line has an unknown Siano vendor: {line}")
            if device_id in SUPPORTED_RIO_IDS:
                raise ConfigError(
                    f"supported Siano ID has a dashed adapter index: {line}"
                )
            continue
        if device_id not in SUPPORTED_RIO_IDS:
            raise ConfigError(f"numeric adapter line has an unsupported Siano ID: {line}")
        adapter = int(device.group(1))
        if adapter != len(adapters):
            raise ConfigError(
                "Siano --list adapter indices are not contiguous in emitted order: "
                f"expected={len(adapters)}, got={adapter}"
            )
        if adapter in adapters:
            raise ConfigError(f"duplicate Siano adapter index in --list output: {adapter}")
        adapters.append(adapter)
    if known != len(lines) - 1:
        raise ConfigError(
            "Siano --list known count disagrees with device lines: "
            f"summary={known}, lines={len(lines) - 1}"
        )
    if supported != len(adapters):
        raise ConfigError(
            "Siano --list supported count disagrees with device lines: "
            f"summary={supported}, lines={len(adapters)}"
        )
    if known < supported:
        raise ConfigError(
            "Siano --list known count is less than supported count: "
            f"known={known}, supported={supported}"
        )
    return adapters


def load_config(path):
    try:
        config = yaml.safe_load(read_text(path, "user config"))
    except yaml.YAMLError as exc:
        raise ConfigError(f"user config is not valid YAML {path}: {exc}") from exc
    if not isinstance(config, dict):
        raise ConfigError(f"user config must be a YAML mapping: {path}")
    tuners = config.get("tuners")
    if tuners is None:
        tuners = []
        config["tuners"] = tuners
    if not isinstance(tuners, list):
        raise ConfigError(f"user config tuners must be a YAML sequence: {path}")
    return config, tuners


def command_tokens(command, wrapper, description):
    # Only classify the add-on's simple forms: the wrapper itself, or
    # `env NAME=value ... wrapper`. A pathname used as an argument to echo or
    # to another executable is data, not an invocation of the managed driver.
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars="|&;<>()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        tokens = list(lexer)
    except ValueError as exc:
        simple_prefix = re.compile(
            rf"^\s*(?:{re.escape(wrapper)}|env(?:\s+[A-Za-z_][A-Za-z0-9_]*=[^\s]+)*\s+"
            rf"{re.escape(wrapper)})(?:\s|$)"
        )
        if simple_prefix.search(command):
            raise ConfigError(f"managed tuner command is malformed ({description}): {exc}") from exc
        return None
    positions = [position for position, token in enumerate(tokens) if token == wrapper]
    if not positions:
        return None
    position = positions[0]
    if position == 0:
        return tokens
    if tokens[0] != "env":
        return None
    if all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token) for token in tokens[1:position]):
        return tokens
    return None


def managed_index(tokens, assignment, assignment_prefix, description, upper_bound=None):
    values = [token for token in tokens if token.startswith(assignment_prefix)]
    if len(values) != 1:
        raise ConfigError(f"managed tuner command has no unique valid index ({description})")
    match = assignment.fullmatch(values[0])
    if match is None:
        raise ConfigError(f"managed tuner command has an invalid index ({description})")
    index = int(match.group(1))
    if upper_bound is not None and index > upper_bound:
        raise ConfigError(f"managed tuner receiver is outside 0..{upper_bound} ({description})")
    return index


def px4_profile(tokens, description):
    values = [token for token in tokens if token.startswith("PX4_PROFILE=")]
    if not values:
        return "px_q3u4"
    if len(values) != 1 or values[0].split("=", 1)[1] not in PX4_MODELS:
        raise ConfigError(f"managed tuner command has an invalid PX4 profile ({description})")
    return values[0].split("=", 1)[1]


def is_shell_operator(token):
    return bool(token) and not token.strip("|&;<>()")


def option_value(tokens, names, description, default=None):
    """Read driver options before any pipeline; reject ambiguous assignments."""
    values = []
    for index, token in enumerate(tokens):
        if is_shell_operator(token):
            break
        if token in names:
            if index + 1 == len(tokens) or tokens[index + 1].startswith("--"):
                raise ConfigError(f"missing value for {token} ({description})")
            values.append(tokens[index + 1])
        elif any(token.startswith(name + "=") for name in names if name.startswith("--")):
            values.append(token.split("=", 1)[1])
        elif any(token.startswith(name) and len(token) > 2 for name in names if len(name) == 2):
            values.append(token[2:])
    if len(values) > 1:
        raise ConfigError(f"duplicate {'/'.join(names)} ({description})")
    return values[0] if values else default


def native_command_tokens(command, binary, default_binary, description):
    for executable in dict.fromkeys((binary, default_binary, Path(default_binary).name)):
        tokens = command_tokens(command, executable, description)
        if tokens is not None:
            return tokens
    return None


def siano_device_option(tokens, description):
    # Match siano-ts v0.1.10's GNU getopt grammar, including -vd1/-vd 1.
    position = 0
    if tokens[0] == "env":
        position = 1
        while position < len(tokens) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[position]):
            position += 1
    arguments = []
    for token in tokens[position + 1:]:
        if is_shell_operator(token):
            break
        arguments.append(token)
    try:
        options, _ = getopt.gnu_getopt(
            arguments, "c:f:t:F:d:p:o:vlh",
            ("channel=", "freq=", "time=", "firmware=", "device=", "fd=", "pid=",
             "output=", "verbose", "list", "control", "detach-kernel-driver", "fail-on-drop", "help"),
        )
    except getopt.GetoptError as exc:
        raise ConfigError(f"cannot identify Siano device ({description}): {exc}") from exc
    if any(option == "--fd" for option, _ in options):
        raise ConfigError(f"use --device for automatic Siano assignment ({description})")
    devices = [value for option, value in options if option in ("-d", "--device")]
    if len(devices) > 1:
        raise ConfigError(f"duplicate Siano device selector ({description})")
    return devices[0] if devices else "0"


def siano_device_aliases(path, adapters):
    aliases = {str(adapter): adapter for adapter in adapters}
    records = []
    for line in read_text(path, "Siano list").splitlines():
        if not line.startswith("model="):
            continue
        fields = dict(token.split("=", 1) for token in line.split())
        if fields.get("usb", "").lower() in SUPPORTED_RIO_IDS:
            records.append(fields)
    for adapter, record in zip(adapters, records):
        aliases[f"{int(record['bus'])}:{int(record['address'])}"] = adapter
        if record["port"] != "-":
            aliases[record["port"]] = adapter
    return aliases


def px4_binding(tokens, slots, description):
    instance = option_value(tokens, ("--instance",), description)
    device = option_value(tokens, ("--device",), description)
    receiver = option_value(tokens, ("--receiver",), description)
    if bool(instance) == bool(device) or receiver is None or not receiver.isdigit():
        raise ConfigError(f"PX4 command needs a unique target and numeric receiver ({description})")
    matches = [slot for slot in slots if int(slot[4]) == int(receiver)
               and (slot[2] == instance if instance else slot[3] == device)]
    if len(matches) > 1:
        raise ConfigError(f"PX4 serial is ambiguous; use --instance ({description})")
    return matches[0] if matches else None


def validate_tuner_types(tuner, allowed, description):
    types = tuner.get("types", [])
    if not isinstance(types, list) or not set(types).issubset(allowed):
        raise ConfigError(f"tuner types exceed detected receiver capabilities ({description})")


def reserve(binding, configured, description):
    if binding in configured:
        raise ConfigError(f"multiple definitions use the same physical tuner ({description})")
    configured.append(binding)


def filter_tuners(
    tuners,
    adapters,
    q3u4_enabled,
    px4_model,
    siano_wrapper,
    q3u4_wrapper,
    drop_px4=False,
    px4_slots=(),
    siano_aliases=None,
    px4_bin=PX4_BIN,
    siano_bin=SIANO_BIN,
):
    retained = []
    retained_siano = []
    retained_q3u4 = []
    removed_siano = 0
    removed_q3u4 = 0

    for position, tuner in enumerate(tuners, start=1):
        if not isinstance(tuner, dict) or not isinstance(tuner.get("command"), str):
            retained.append(tuner)
            continue
        command = tuner["command"]
        description = f"tuner #{position}"
        # Native user commands reserve their physical tuner too. This avoids
        # adding a second auto-generated definition for a manually configured
        # receiver while preserving the user's other command options.
        native_siano = native_command_tokens(command, siano_bin, SIANO_BIN, description)
        native_px4 = native_command_tokens(command, px4_bin, PX4_BIN, description)
        if native_siano is not None:
            device = siano_device_option(native_siano, description)
            if device.isdigit():
                device = str(int(device))
            elif re.fullmatch(r"[0-9]+:[0-9]+", device):
                device = ":".join(str(int(part)) for part in device.split(":"))
            elif re.fullmatch(r"[0-9]+-[0-9]+(?:\.[0-9]+)*", device):
                device = re.sub(r"[0-9]+", lambda match: str(int(match[0])), device)
            adapter = (siano_aliases or {}).get(device)
            if adapter is None and device.isdigit() and int(device) in adapters:
                adapter = int(device)
            if adapter is None:
                removed_siano += 1
            else:
                validate_tuner_types(tuner, {"GR"}, description)
                reserve(adapter, retained_siano, description)
                retained.append(tuner)
            continue
        if native_px4 is not None and drop_px4:
            slot = px4_binding(native_px4, px4_slots, description)
            if slot is None:
                removed_q3u4 += 1
                continue
            _, _, instance, _, receiver, systems = slot
            validate_tuner_types(tuner, PX4_SLOT_TYPES[systems], description)
            if option_value(native_px4, ("--device",), description) is not None:
                # px4d is started under the generated instance, so the serial
                # alias must connect to that endpoint, not a serial endpoint.
                if any(is_shell_operator(token) for token in native_px4):
                    raise ConfigError(f"use --instance in a custom PX4 shell command ({description})")
                target = next(index for index, token in enumerate(native_px4)
                              if token == "--device" or token.startswith("--device="))
                length = 2 if native_px4[target] == "--device" else 1
                native_px4[target:target + length] = ["--instance", instance]
                tuner = dict(tuner, command=shlex.join(native_px4))
            reserve((instance, receiver), retained_q3u4, description)
            retained.append(tuner)
            continue
        siano_tokens = command_tokens(command, siano_wrapper, description)
        q3u4_tokens = command_tokens(command, q3u4_wrapper, description)
        if siano_tokens is not None and q3u4_tokens is not None:
            raise ConfigError(f"tuner invokes both managed wrappers ({description})")
        if siano_tokens is not None:
            adapter = managed_index(
                siano_tokens, SIANO_ASSIGNMENT, SIANO_ASSIGNMENT_PREFIX, description
            )
            if adapter in adapters:
                retained.append(tuner)
                reserve(adapter, retained_siano, description)
            else:
                removed_siano += 1
            continue
        if q3u4_tokens is not None:
            profile = px4_profile(q3u4_tokens, description)
            receiver = managed_index(
                q3u4_tokens,
                Q3U4_ASSIGNMENT,
                Q3U4_ASSIGNMENT_PREFIX,
                description,
                upper_bound=PX4_RECEIVER_UPPER_BOUND.get(profile, 7),
            )
            explicit_instance = [token.split("=", 1)[1] for token in q3u4_tokens
                                 if token.startswith("PX4_INSTANCE=")]
            if drop_px4 and len(explicit_instance) == 1:
                matches = [slot for slot in px4_slots
                           if slot[2] == explicit_instance[0] and int(slot[4]) == receiver]
                if matches:
                    slot = matches[0]
                    validate_tuner_types(tuner, PX4_SLOT_TYPES[slot[5]], description)
                    reserve((slot[2], slot[4]), retained_q3u4, description)
                    retained.append(tuner)
                    continue
            if not drop_px4 and q3u4_enabled and profile == px4_model:
                retained.append(tuner)
                retained_q3u4.append(receiver)
            else:
                removed_q3u4 += 1
            continue
        retained.append(tuner)

    return retained, retained_siano, retained_q3u4, removed_siano, removed_q3u4


PX4_SLOT_TYPES = {"T": ("GR",), "S": ("BS", "CS"), "TS": ("GR", "BS", "CS")}


def siano_tuners_from_adapters(adapters, configured_adapters, binary=SIANO_BIN, firmware=None):
    """Generate a default mirakc tuner for each detected Siano adapter not configured yet."""
    configured = set(configured_adapters)
    tuners = []
    for adapter in adapters:
        if adapter in configured:
            continue
        command = shlex.join(siano_command(CHANNEL, device=adapter,
                                          binary=binary, firmware=firmware))
        if os.environ.get("PX_S1UD_SETTLE_SECONDS", "0") not in ("", "0"):
            # An explicitly requested per-stream delay still uses the legacy
            # shim; default auto-generated commands invoke the driver directly.
            command = shlex.join(["env", f"PX_S1UD_ADAPTER={adapter}",
                                  f"SIANO_TS_BIN={binary}",
                                  f"PX_S1UD_FIRMWARE={firmware or os.environ.get('PX_S1UD_FIRMWARE', '/lib/firmware/isdbt_rio.inp')}",
                                  SIANO_WRAPPER, CHANNEL])
        tuners.append(
            {
                "name": f"PX-S1UD #{adapter}",
                "types": ["GR"],
                "command": command,
            }
        )
    return tuners


def load_px4_plan(path):
    """px4-plan.py が書いた内部計画から受信機ごとの slot を読む。"""
    slots = []
    seen = set()
    for line in read_text(path, "PX4 plan").splitlines():
        if not line.strip():
            continue
        fields = line.split()
        if fields[0] == "enclosure" and len(fields) == 7:
            continue
        if fields[0] == "slot" and len(fields) == 7:
            _, key, name, instance, serial, receiver, systems = fields
            if systems not in PX4_SLOT_TYPES:
                raise ConfigError(f"unknown PX4 slot system set in plan: {line}")
            if not receiver.isdigit():
                raise ConfigError(f"invalid receiver in PX4 plan: {line}")
            receiver = str(int(receiver))
            if (instance, receiver) in seen:
                raise ConfigError(f"duplicate receiver in PX4 plan: {line}")
            seen.add((instance, receiver))
            slots.append((key, name, instance, serial, receiver, systems))
            continue
        raise ConfigError(f"malformed PX4 plan line: {line}")
    return slots


def px4_tuners_from_plan(slots, configured=(), binary=PX4_BIN, runtime_dir=None):
    """物理受信機1基につき1つの managed tuner を組み立てる。"""
    tuners = []
    # Mirakc tries available tuner definitions by order. Put the only T/S
    # hybrid receiver after dedicated T and S receivers so an early GR request
    # leaves it available for a later satellite request.
    slots = sorted(slots, key=lambda slot: slot[5] == "TS")
    for _, name, instance, _, receiver, systems in slots:
        if (instance, receiver) in configured:
            continue
        command = shlex.join(px4_command(CHANNEL, instance=instance, receiver=receiver,
                                        binary=binary, runtime_dir=runtime_dir))
        tuners.append(
            {
                "name": f"{name} #{receiver}",
                "types": list(PX4_SLOT_TYPES[systems]),
                "command": command,
            }
        )
    return tuners


def retained_tuner_types(tuners):
    types = set()
    for tuner in tuners:
        if not isinstance(tuner, dict) or not isinstance(tuner.get("types"), list):
            continue
        types.update(value for value in tuner["types"] if isinstance(value, str))
    return types


def filter_channels(config, tuner_types):
    if "channels" not in config:
        return None, None
    channels = config["channels"]
    if not isinstance(channels, list):
        raise ConfigError("user config channels must be a YAML sequence")
    retained = []
    removed = 0
    for channel in channels:
        if isinstance(channel, dict) and isinstance(channel.get("type"), str):
            if channel["type"] not in tuner_types:
                removed += 1
                continue
        retained.append(channel)
    config["channels"] = retained
    return len(retained), removed


def remove_old_output(path):
    try:
        if path.is_symlink() or path.exists():
            if path.is_dir() and not path.is_symlink():
                raise ConfigError(f"effective config path is a directory: {path}")
            path.unlink()
    except OSError as exc:
        raise ConfigError(f"could not remove prior effective config {path}: {exc}") from exc


def write_atomic(config, output, warmup_file, warmup_adapters):
    parent = output.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ConfigError(f"could not create effective config directory {parent}: {exc}") from exc

    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=f".{output.name}.", dir=parent)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            yaml.safe_dump(config, stream, sort_keys=False, allow_unicode=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        warmup_file.write_text(
            "".join(f"{adapter}\n" for adapter in warmup_adapters), encoding="ascii"
        )
        os.replace(temporary, output)
        temporary = None
    except (OSError, yaml.YAMLError) as exc:
        raise ConfigError(f"could not write effective config {output}: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            except OSError:
                print(f"warning: could not remove temporary effective config {temporary}", file=sys.stderr)


def main():
    args = parse_args()
    remove_old_output(args.output)
    adapters = parse_siano_adapters(args.siano_list)
    px4_slots = load_px4_plan(args.px4_plan) if args.px4_plan is not None else []
    config, tuners = load_config(args.input)
    filtered, retained_siano, retained_q3u4, removed_siano, removed_q3u4 = filter_tuners(
        tuners,
        adapters,
        args.q3u4_enabled == "1",
        args.px4_model,
        args.siano_wrapper,
        args.q3u4_wrapper,
        drop_px4=args.px4_plan is not None,
        px4_slots=px4_slots,
        siano_aliases=siano_device_aliases(args.siano_list, adapters),
        px4_bin=args.px4_bin,
        siano_bin=args.siano_bin,
    )
    generated_siano = siano_tuners_from_adapters(
        adapters, retained_siano, args.siano_bin, args.siano_firmware
    )
    filtered.extend(generated_siano)
    if px4_slots:
        filtered.extend(px4_tuners_from_plan(px4_slots, retained_q3u4,
                                            args.px4_bin, args.runtime_dir))
    if not filtered:
        raise ConfigError("effective config has no tuners after hardware filtering")
    config["tuners"] = filtered
    tuner_types = retained_tuner_types(filtered)
    retained_channels, removed_channels = filter_channels(config, tuner_types)
    write_atomic(config, args.output, args.warmup_file, adapters)
    q3_state = "enabled" if args.q3u4_enabled == "1" else "disabled"
    detected = ",".join(str(adapter) for adapter in adapters) or "none"
    channel_counts = (
        f"retained_channels={retained_channels} removed_channels={removed_channels}"
        if retained_channels is not None
        else "retained_channels=absent removed_channels=absent"
    )
    type_set = ",".join(sorted(tuner_types)) or "none"
    print(
        "effective config: "
        f"user={args.input} effective={args.output} "
        f"detected_siano={detected} q3u4={q3_state} "
        f"retained_managed_siano={len(retained_siano)} "
        f"generated_siano={len(generated_siano)} "
        f"removed_managed_siano={removed_siano} "
        f"retained_managed_q3u4={len(retained_q3u4)} "
        f"removed_managed_q3u4={removed_q3u4} "
        f"tuner_types={type_set} {channel_counts}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ConfigError as exc:
        print(f"effective config generation failed: {exc}", file=sys.stderr)
        sys.exit(1)
