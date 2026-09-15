#!/bin/sh
set -eu

if [ "$#" -ne 6 ] && [ "$#" -ne 7 ]; then
    echo "usage: $0 [--new] CONFIG AWK_SCRIPT AAC_TS AAC_ENCODED MP3_TS MP3_ENCODED" >&2
    exit 2
fi

new_config=0
if [ "$1" = '--new' ]; then
    new_config=1
    shift
fi

source=$1
awk_script=$2
ts_profile=$3
encoded_profile=$4
ts_mp3_profile=$5
encoded_mp3_profile=$6
config_dir=$(dirname -- "$source")
backup=${source}.pre-mp3-audio-profile.bak
tmp=$(mktemp "$config_dir/.$(basename -- "$source").audio-profile.XXXXXX")

cleanup() {
    rm -f -- "$tmp"
}
on_signal() {
    cleanup
    trap - EXIT
    exit 1
}
trap cleanup EXIT
trap on_signal HUP INT TERM

if ! awk -v ts_profile_file="$ts_profile" \
    -v encoded_profile_file="$encoded_profile" \
    -v ts_mp3_profile_file="$ts_mp3_profile" \
    -v encoded_mp3_profile_file="$encoded_mp3_profile" \
    -f "$awk_script" "$source" > "$tmp"; then
    echo "recorded-audio-profile: refusing to modify $source (invalid structure or duplicate profile)" >&2
    exit 1
fi

if ! awk -v validate_only=1 -f "$awk_script" "$tmp" >/dev/null; then
    echo "recorded-audio-profile: generated configuration failed validation; $source is unchanged" >&2
    exit 1
fi

if cmp -s -- "$source" "$tmp"; then
    echo "recorded-audio-profile: $source already contains the audio profiles" >&2
    exit 0
fi

if [ "$new_config" -eq 0 ] && [ ! -e "$backup" ]; then
    cp -p -- "$source" "$backup"
    echo "recorded-audio-profile: saved pre-migration backup at $backup" >&2
fi

mv -f -- "$tmp" "$source"
trap - EXIT
trap - HUP INT TERM
echo "recorded-audio-profile: migrated $source" >&2
