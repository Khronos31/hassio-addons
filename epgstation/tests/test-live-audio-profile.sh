#!/bin/sh
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
AWK_SCRIPT=$ROOT/recorded-audio-profile.awk
TS_PROFILE=$ROOT/recorded-audio-profile-ts.yml
ENCODED_PROFILE=$ROOT/recorded-audio-profile-encoded.yml
MP3_TS_PROFILE=$ROOT/recorded-audio-profile-mp3-ts.yml
MP3_ENCODED_PROFILE=$ROOT/recorded-audio-profile-mp3-encoded.yml
LIVE_MP3_PROFILE=$ROOT/live-audio-profile-mp3.yml
MIGRATOR=$ROOT/migrate-recorded-audio-profile.sh
OPTIONAL_MIGRATOR=$ROOT/run-optional-recorded-audio-migration.sh
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

write_template_config() {
    cat > "$1" <<'YAML'
stream:
    live:
        ts:
            mp4:
                - name: 720p
                  cmd: '%FFMPEG% -i pipe:0 -f mp4 pipe:1'
                - name: 480p
                  cmd: '%FFMPEG% -i pipe:0 -f mp4 pipe:1'
    recorded:
        ts:
            mp4:
                - name: Video
                  cmd: '%FFMPEG% -i pipe:0 -f mp4 pipe:1'
        encoded:
            mp4:
                - name: Video
                  cmd: '%FFMPEG% -ss %SS% -i %INPUT% -f mp4 pipe:1'
YAML
}

apply_profiles() {
    if [ "$1" = "--new" ]; then
        shift
        "$OPTIONAL_MIGRATOR" "$MIGRATOR" --new "$1" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
            "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" "$LIVE_MP3_PROFILE" >/dev/null
    else
        "$OPTIONAL_MIGRATOR" "$MIGRATOR" "$1" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
            "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" "$LIVE_MP3_PROFILE" >/dev/null
    fi
}

assert_profiles() {
    config=$1
    test "$(yq e '.stream.live.ts.mp4 | map(select(.name == "Home Assistant Live Audio MP3")) | length' "$config")" = 1
    test "$(yq e '.stream.live.ts.mp4 | map(select(.name == "720p")) | length' "$config")" = 1
    test "$(yq e '.stream.live.ts.mp4 | map(select(.name == "480p")) | length' "$config")" = 1
    test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Video")) | length' "$config")" = 1
    test "$(yq e '.stream.recorded.encoded.mp4 | map(select(.name == "Video")) | length' "$config")" = 1
    test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Home Assistant Audio")) | length' "$config")" = 1
    test "$(yq e '.stream.recorded.encoded.mp4 | map(select(.name == "Home Assistant Audio")) | length' "$config")" = 1
    test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Home Assistant Audio MP3")) | length' "$config")" = 1
    test "$(yq e '.stream.recorded.encoded.mp4 | map(select(.name == "Home Assistant Audio MP3")) | length' "$config")" = 1
    yq e '.' "$config" >/dev/null
}

write_template_config "$TMP_DIR/new-config.yml"
apply_profiles --new "$TMP_DIR/new-config.yml"
assert_profiles "$TMP_DIR/new-config.yml"
live_cmd=$(yq e -r '.stream.live.ts.mp4[] | select(.name == "Home Assistant Live Audio MP3") | .cmd' "$TMP_DIR/new-config.yml")
test "$live_cmd" = '%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1'
test ! -e "$TMP_DIR/new-config.yml.pre-mp3-audio-profile.bak"

write_template_config "$TMP_DIR/existing-config.yml"
cp "$TMP_DIR/existing-config.yml" "$TMP_DIR/existing-before.yml"
apply_profiles "$TMP_DIR/existing-config.yml"
cmp "$TMP_DIR/existing-before.yml" "$TMP_DIR/existing-config.yml.pre-mp3-audio-profile.bak"
assert_profiles "$TMP_DIR/existing-config.yml"
first_checksum=$(cksum "$TMP_DIR/existing-config.yml")
backup_checksum=$(cksum "$TMP_DIR/existing-config.yml.pre-mp3-audio-profile.bak")
apply_profiles "$TMP_DIR/existing-config.yml"
test "$first_checksum" = "$(cksum "$TMP_DIR/existing-config.yml")"
test "$backup_checksum" = "$(cksum "$TMP_DIR/existing-config.yml.pre-mp3-audio-profile.bak")"

write_template_config "$TMP_DIR/with-existing-live.yml"
sed -i '/^    recorded:$/i\                - name: Home Assistant Live Audio MP3\n                  cmd: custom live command' "$TMP_DIR/with-existing-live.yml"
"$MIGRATOR" "$TMP_DIR/with-existing-live.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" "$LIVE_MP3_PROFILE" >/dev/null
test "$(yq e '.stream.live.ts.mp4 | map(select(.name == "Home Assistant Live Audio MP3")) | length' "$TMP_DIR/with-existing-live.yml")" = 1
test "$(yq e -r '.stream.live.ts.mp4[] | select(.name == "Home Assistant Live Audio MP3") | .cmd' "$TMP_DIR/with-existing-live.yml")" = 'custom live command'

write_template_config "$TMP_DIR/invalid.yml"
sed -i '/^    live:/d' "$TMP_DIR/invalid.yml"
cp "$TMP_DIR/invalid.yml" "$TMP_DIR/invalid-before.yml"
if "$MIGRATOR" "$TMP_DIR/invalid.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" "$LIVE_MP3_PROFILE" >"$TMP_DIR/invalid.out" 2>"$TMP_DIR/invalid.err"; then
    echo "migration unexpectedly accepted config without stream.live.ts.mp4" >&2
    exit 1
fi
cmp "$TMP_DIR/invalid-before.yml" "$TMP_DIR/invalid.yml"

write_template_config "$TMP_DIR/duplicate.yml"
yq e -i '.stream.live.ts.mp4 += [{"name": "Home Assistant Live Audio MP3", "cmd": "duplicate"}]' "$TMP_DIR/duplicate.yml"
cp "$TMP_DIR/duplicate.yml" "$TMP_DIR/duplicate-before.yml"
if "$MIGRATOR" "$TMP_DIR/duplicate.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" "$LIVE_MP3_PROFILE" >"$TMP_DIR/duplicate.out" 2>"$TMP_DIR/duplicate.err"; then
    echo "migration unexpectedly accepted duplicate live profiles" >&2
    exit 1
fi
cmp "$TMP_DIR/duplicate-before.yml" "$TMP_DIR/duplicate.yml"

if "$OPTIONAL_MIGRATOR" "$MIGRATOR" "$TMP_DIR/invalid.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" "$LIVE_MP3_PROFILE" >"$TMP_DIR/optional.out" 2>"$TMP_DIR/optional.err"; then
    grep -q 'optional recorded-audio profile migration was skipped' "$TMP_DIR/optional.err"
else
    echo "optional migration wrapper stopped startup" >&2
    exit 1
fi
cmp "$TMP_DIR/invalid-before.yml" "$TMP_DIR/invalid.yml"

echo "PASS: new and existing configs contain one live MP3 profile; repeat migration is idempotent"
echo "PASS: live command, existing video/audio profiles, malformed config preservation, and warning behavior"
