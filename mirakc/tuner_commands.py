"""Native driver argv shared by mirakc configuration and terrestrial scanning."""

import os


PX4_BIN = "/usr/local/bin/px4-ts"
SIANO_BIN = "/usr/local/bin/siano-ts"
CHANNEL = "{{{channel}}}"


def px4_command(channel, *, receiver, instance=None, device=None,
                binary=PX4_BIN, runtime_dir=None):
    if instance:
        target = ["--instance", str(instance)]
    elif device:
        target = ["--device", str(device)]
    else:
        raise ValueError("a PX4 instance or device is required")
    if receiver is None or not str(receiver).isdigit():
        raise ValueError("a numeric PX4 receiver is required")
    runtime_dir = runtime_dir or os.environ.get("PX4_RUNTIME_DIR", "/run/px4-userland")
    return [binary, *target, "--receiver", str(receiver), "--channel", channel,
            "--runtime-dir", runtime_dir, "--output", "-"]


def siano_command(channel, *, device, binary=SIANO_BIN, firmware=None):
    firmware = firmware or os.environ.get("PX_S1UD_FIRMWARE", "/lib/firmware/isdbt_rio.inp")
    return [binary, "--channel", channel, "--device", str(device), "--firmware", firmware]
