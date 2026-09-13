#!/usr/bin/env python3
"""Build the mirakc configuration for the hardware available at runtime."""

import argparse
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

import yaml


SIANO_WRAPPER = "/usr/local/bin/px-s1ud-stream"
Q3U4_WRAPPER = "/usr/local/bin/px4-ts-stream"
SIANO_ASSIGNMENT_PREFIX = "PX_S1UD_ADAPTER="
Q3U4_ASSIGNMENT_PREFIX = "PX4_RECEIVER="
SIANO_ASSIGNMENT = re.compile(r"^PX_S1UD_ADAPTER=([0-9]+)$")
Q3U4_ASSIGNMENT = re.compile(r"^PX4_RECEIVER=([0-9]+)$")
SUPPORTED_RIO_IDS = frozenset(("3275:0080", "187f:0600", "187f:0302"))
KNOWN_SIANO_VENDORS = frozenset(("3275", "187f"))
SIANO_DEVICE = re.compile(
    r"^([0-9]+|-):\s+([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})(?:\s+.*)?$"
)
SIANO_SUMMARY = re.compile(
    r"^([0-9]+) supported RIO device\(s\), "
    r"([0-9]+) known Siano device\(s\)$"
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
    parser.add_argument("--siano-wrapper", default=SIANO_WRAPPER)
    parser.add_argument("--q3u4-wrapper", default=Q3U4_WRAPPER)
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
        raise ConfigError("Siano --list output is empty")

    if lines[-1] == "0 devices":
        if len(lines) != 1:
            raise ConfigError("Siano --list output contradicts its 0 devices summary")
        return []

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
    # `env NAME=value ... wrapper`. An exact token in `echo`, a shell pipeline,
    # or another custom command is data, not proof that the wrapper is invoked.
    try:
        tokens = shlex.split(command)
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


def filter_tuners(tuners, adapters, q3u4_enabled, siano_wrapper, q3u4_wrapper):
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
                retained_siano.append(adapter)
            else:
                removed_siano += 1
            continue
        if q3u4_tokens is not None:
            receiver = managed_index(
                q3u4_tokens,
                Q3U4_ASSIGNMENT,
                Q3U4_ASSIGNMENT_PREFIX,
                description,
                upper_bound=7,
            )
            if q3u4_enabled:
                retained.append(tuner)
                retained_q3u4.append(receiver)
            else:
                removed_q3u4 += 1
            continue
        retained.append(tuner)

    if not retained:
        raise ConfigError("effective config has no tuners after hardware filtering")
    return retained, retained_siano, retained_q3u4, removed_siano, removed_q3u4


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
    config, tuners = load_config(args.input)
    filtered, retained_siano, retained_q3u4, removed_siano, removed_q3u4 = filter_tuners(
        tuners,
        adapters,
        args.q3u4_enabled == "1",
        args.siano_wrapper,
        args.q3u4_wrapper,
    )
    config["tuners"] = filtered
    tuner_types = retained_tuner_types(filtered)
    retained_channels, removed_channels = filter_channels(config, tuner_types)
    write_atomic(config, args.output, args.warmup_file, sorted(set(retained_siano)))
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
