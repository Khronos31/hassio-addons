#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: $0 MIGRATOR [MIGRATOR_ARGUMENT ...]" >&2
    exit 2
fi

if "$@"; then
    exit 0
fi

echo "WARNING: optional recorded-audio profile migration was skipped and the migrator left the source config untouched; Home Assistant audio profiles are unavailable, but EPGStation will continue startup without them. Review the migration error and add the profiles manually when the config format is supported." >&2
exit 0
