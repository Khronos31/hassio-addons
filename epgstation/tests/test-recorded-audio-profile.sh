#!/bin/sh
set -eu

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
AWK_SCRIPT=$ROOT/recorded-audio-profile.awk
TS_PROFILE=$ROOT/recorded-audio-profile-ts.yml
ENCODED_PROFILE=$ROOT/recorded-audio-profile-encoded.yml
MP3_TS_PROFILE=$ROOT/recorded-audio-profile-mp3-ts.yml
MP3_ENCODED_PROFILE=$ROOT/recorded-audio-profile-mp3-encoded.yml
MIGRATOR=$ROOT/migrate-recorded-audio-profile.sh
OPTIONAL_MIGRATOR=$ROOT/run-optional-recorded-audio-migration.sh
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/config.yml" <<'YAML'
stream:
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

apply_profiles() {
    "$OPTIONAL_MIGRATOR" "$MIGRATOR" "$TMP_DIR/config.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
        "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null
}

assert_profiles() {
    test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Home Assistant Audio")) | length' "$1")" = 1
    test "$(yq e '.stream.recorded.encoded.mp4 | map(select(.name == "Home Assistant Audio")) | length' "$1")" = 1
    test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Home Assistant Audio MP3")) | length' "$1")" = 1
    test "$(yq e '.stream.recorded.encoded.mp4 | map(select(.name == "Home Assistant Audio MP3")) | length' "$1")" = 1
    yq e '.' "$1" >/dev/null
}

cp "$TMP_DIR/config.yml" "$TMP_DIR/config.before"
apply_profiles
cmp "$TMP_DIR/config.before" "$TMP_DIR/config.yml.pre-mp3-audio-profile.bak"
assert_profiles "$TMP_DIR/config.yml"
first_checksum=$(cksum "$TMP_DIR/config.yml")
ts_cmd=$(yq e -r '.stream.recorded.ts.mp4[] | select(.name == "Home Assistant Audio") | .cmd' "$TMP_DIR/config.yml")
encoded_cmd=$(yq e -r '.stream.recorded.encoded.mp4[] | select(.name == "Home Assistant Audio") | .cmd' "$TMP_DIR/config.yml")
mp3_ts_cmd=$(yq e -r '.stream.recorded.ts.mp4[] | select(.name == "Home Assistant Audio MP3") | .cmd' "$TMP_DIR/config.yml")
mp3_encoded_cmd=$(yq e -r '.stream.recorded.encoded.mp4[] | select(.name == "Home Assistant Audio MP3") | .cmd' "$TMP_DIR/config.yml")
test "${ts_cmd#*pipe:0}" != "$ts_cmd"
test "${encoded_cmd#*%SS%}" != "$encoded_cmd"
test "${encoded_cmd#*%INPUT%}" != "$encoded_cmd"
test "${mp3_ts_cmd#*libmp3lame}" != "$mp3_ts_cmd"
test "${mp3_encoded_cmd#*%INPUT%}" != "$mp3_encoded_cmd"
backup_checksum=$(cksum "$TMP_DIR/config.yml.pre-mp3-audio-profile.bak")

apply_profiles
test "$first_checksum" = "$(cksum "$TMP_DIR/config.yml")"
test "$backup_checksum" = "$(cksum "$TMP_DIR/config.yml.pre-mp3-audio-profile.bak")"

cp "$TMP_DIR/config.yml.pre-mp3-audio-profile.bak" "$TMP_DIR/config.yml"
cmp "$TMP_DIR/config.yml" "$TMP_DIR/config.before"

cp "$TMP_DIR/config.before" "$TMP_DIR/existing-backup.yml"
printf '%s\n' 'pre-existing backup sentinel' > "$TMP_DIR/existing-backup.yml.pre-mp3-audio-profile.bak"
cp "$TMP_DIR/existing-backup.yml.pre-mp3-audio-profile.bak" "$TMP_DIR/existing-backup.before"
"$MIGRATOR" "$TMP_DIR/existing-backup.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null
cmp "$TMP_DIR/existing-backup.before" "$TMP_DIR/existing-backup.yml.pre-mp3-audio-profile.bak"
assert_profiles "$TMP_DIR/existing-backup.yml"

cat > "$TMP_DIR/failing-migrator.sh" <<'SH'
#!/bin/sh
echo 'intentional optional migration failure' >&2
exit 17
SH
chmod 755 "$TMP_DIR/failing-migrator.sh"
if "$OPTIONAL_MIGRATOR" "$TMP_DIR/failing-migrator.sh" >"$TMP_DIR/optional.out" 2>"$TMP_DIR/optional.err"; then
    printf '%s\n' continued > "$TMP_DIR/optional.continued"
else
    echo "optional migration wrapper stopped startup" >&2
    exit 1
fi
test "$(cat "$TMP_DIR/optional.continued")" = continued
grep -q 'optional recorded-audio profile migration was skipped' "$TMP_DIR/optional.err"
grep -q 'migrator left the source config untouched' "$TMP_DIR/optional.err"
grep -q 'Home Assistant audio profiles are unavailable' "$TMP_DIR/optional.err"

cat > "$TMP_DIR/one-sided.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0?
                      -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k
                      -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000
                      -y -f mp4 pipe:1
            hls: []
        encoded:
            mp4:
                - name: Video
                  cmd: '%FFMPEG% -ss %SS% -i %INPUT% -f mp4 pipe:1'
            hls: []
YAML
mv "$TMP_DIR/one-sided.yml" "$TMP_DIR/config.yml"
cp "$TMP_DIR/config.yml" "$TMP_DIR/one-sided.before"
rm -f "$TMP_DIR/config.yml.pre-mp3-audio-profile.bak"
apply_profiles
assert_profiles "$TMP_DIR/config.yml"
test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Home Assistant Audio")) | length' "$TMP_DIR/config.yml")" = 1
cmp "$TMP_DIR/one-sided.before" "$TMP_DIR/config.yml.pre-mp3-audio-profile.bak"

cat > "$TMP_DIR/mp3-only.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio MP3
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0?
                      -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1
        encoded:
            mp4:
                - name: Home Assistant Audio MP3
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0?
                      -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1
YAML
mv "$TMP_DIR/mp3-only.yml" "$TMP_DIR/config.yml"
apply_profiles
assert_profiles "$TMP_DIR/config.yml"

cat > "$TMP_DIR/malformed.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4: []
        encoded:
            hls: []
YAML
cp "$TMP_DIR/malformed.yml" "$TMP_DIR/malformed.before"
if "$MIGRATOR" "$TMP_DIR/malformed.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" \
    2>"$TMP_DIR/malformed.err"; then
    echo "malformed config unexpectedly migrated" >&2
    exit 1
fi
cmp "$TMP_DIR/malformed.before" "$TMP_DIR/malformed.yml"
test ! -e "$TMP_DIR/malformed.yml.pre-mp3-audio-profile.bak"
grep -q 'refusing to modify' "$TMP_DIR/malformed.err"

cat > "$TMP_DIR/duplicate.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio
                  cmd: first
                - name: Home Assistant Audio
                  cmd: duplicate
            hls: []
        encoded:
            mp4:
                - name: Video
                  cmd: '%FFMPEG% -ss %SS% -i %INPUT% -f mp4 pipe:1'
            hls: []
YAML
cp "$TMP_DIR/duplicate.yml" "$TMP_DIR/duplicate.before"
if "$MIGRATOR" "$TMP_DIR/duplicate.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null 2>&1; then
    echo "duplicate config unexpectedly migrated" >&2
    exit 1
fi
cmp "$TMP_DIR/duplicate.before" "$TMP_DIR/duplicate.yml"
test ! -e "$TMP_DIR/duplicate.yml.pre-mp3-audio-profile.bak"

cat > "$TMP_DIR/quoted.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: "Home Assistant Audio"
                  cmd: '%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -y -f mp4 pipe:1'
                - name: 'Home Assistant Audio MP3'
                  cmd: '%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1'
            hls: []
        encoded:
            mp4:
                - name: "Home Assistant Audio"
                  cmd: '%FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0? -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -y -f mp4 pipe:1'
                - name: 'Home Assistant Audio MP3'
                  cmd: '%FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1'
YAML
cp "$TMP_DIR/quoted.yml" "$TMP_DIR/quoted.before"
rm -f "$TMP_DIR/quoted.yml.pre-mp3-audio-profile.bak"
"$MIGRATOR" "$TMP_DIR/quoted.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null
cmp "$TMP_DIR/quoted.before" "$TMP_DIR/quoted.yml"
yq e '.' "$TMP_DIR/quoted.yml" >/dev/null
test ! -e "$TMP_DIR/quoted.yml.pre-mp3-audio-profile.bak"

for variant in two-space stream-comment; do
    if [ "$variant" = two-space ]; then
        awk '{ line = $0; match(line, /^ */); spaces = RLENGTH; sub(/^ */, "", line); indent = ""; for (i = 0; i < spaces; i += 4) indent = indent "  "; print indent line }' \
            "$TMP_DIR/quoted.yml" > "$TMP_DIR/$variant.yml"
    else
        sed '1s/^stream:$/stream: # comment/' "$TMP_DIR/quoted.yml" > "$TMP_DIR/$variant.yml"
    fi
    cp "$TMP_DIR/$variant.yml" "$TMP_DIR/$variant.before"
    yq e '.' "$TMP_DIR/$variant.yml" >/dev/null
    if "$MIGRATOR" "$TMP_DIR/$variant.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
        "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null 2>"$TMP_DIR/$variant.err"; then
        echo "$variant fixture unexpectedly migrated" >&2
        exit 1
    fi
    cmp "$TMP_DIR/$variant.before" "$TMP_DIR/$variant.yml"
    test ! -e "$TMP_DIR/$variant.yml.pre-mp3-audio-profile.bak"
done

awk '
    /^            hls:/ && !inserted {
        print "                - name: \"Home Assistant Audio\""
        print "                  cmd: '\''%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -y -f mp4 pipe:1'\''"
        inserted=1
    }
    { print }
' "$TMP_DIR/quoted.yml" > "$TMP_DIR/quoted-ts-duplicate.yml"
cp "$TMP_DIR/quoted-ts-duplicate.yml" "$TMP_DIR/quoted-ts-duplicate.before"
if "$MIGRATOR" "$TMP_DIR/quoted-ts-duplicate.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null 2>"$TMP_DIR/quoted-ts-duplicate.err"; then
    echo "quoted TS duplicate unexpectedly migrated" >&2
    exit 1
fi
cmp "$TMP_DIR/quoted-ts-duplicate.before" "$TMP_DIR/quoted-ts-duplicate.yml"
test ! -e "$TMP_DIR/quoted-ts-duplicate.yml.pre-mp3-audio-profile.bak"
grep -q 'duplicate Home Assistant Audio' "$TMP_DIR/quoted-ts-duplicate.err"

awk '
    END {
        print "                - name: '\''Home Assistant Audio MP3'\''"
        print "                  cmd: '\''%FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1'\''"
    }
    { print }
' "$TMP_DIR/quoted.yml" > "$TMP_DIR/quoted-encoded-duplicate.yml"
cp "$TMP_DIR/quoted-encoded-duplicate.yml" "$TMP_DIR/quoted-encoded-duplicate.before"
if "$MIGRATOR" "$TMP_DIR/quoted-encoded-duplicate.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null 2>"$TMP_DIR/quoted-encoded-duplicate.err"; then
    echo "quoted encoded duplicate unexpectedly migrated" >&2
    exit 1
fi
cmp "$TMP_DIR/quoted-encoded-duplicate.before" "$TMP_DIR/quoted-encoded-duplicate.yml"
test ! -e "$TMP_DIR/quoted-encoded-duplicate.yml.pre-mp3-audio-profile.bak"
grep -q 'duplicate Home Assistant Audio MP3' "$TMP_DIR/quoted-encoded-duplicate.err"

cat > "$TMP_DIR/commented.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio # legacy AAC
                  cmd: '%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -y -f mp4 pipe:1'
                - name: "Home Assistant Audio MP3" # canonical MP3
                  cmd: '%FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1'
            hls: []
        encoded:
            mp4:
                - name: 'Home Assistant Audio' # encoded AAC
                  cmd: '%FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0? -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -y -f mp4 pipe:1'
                - name: Home Assistant Audio MP3 # encoded MP3
                  cmd: '%FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0? -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1'
YAML
cp "$TMP_DIR/commented.yml" "$TMP_DIR/commented.before"
"$MIGRATOR" "$TMP_DIR/commented.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null
cmp "$TMP_DIR/commented.before" "$TMP_DIR/commented.yml"
test ! -e "$TMP_DIR/commented.yml.pre-mp3-audio-profile.bak"
assert_profiles "$TMP_DIR/commented.yml"

cat > "$TMP_DIR/quoted-hash.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0?
                      -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k
                      -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000
                      -y -f mp4 pipe:1
                - name: "Home Assistant Audio MP3 # custom"
                  cmd: '%FFMPEG% -i pipe:0 -f mp3 pipe:1'
            hls: []
        encoded:
            mp4:
                - name: Home Assistant Audio
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0?
                      -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k
                      -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000
                      -y -f mp4 pipe:1
                - name: Home Assistant Audio MP3
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0?
                      -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1
YAML
cp "$TMP_DIR/quoted-hash.yml" "$TMP_DIR/quoted-hash.before"
"$MIGRATOR" "$TMP_DIR/quoted-hash.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null
yq e '.' "$TMP_DIR/quoted-hash.yml" >/dev/null
test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Home Assistant Audio MP3")) | length' "$TMP_DIR/quoted-hash.yml")" = 1
test "$(yq e '.stream.recorded.ts.mp4 | map(select(.name == "Home Assistant Audio MP3 # custom")) | length' "$TMP_DIR/quoted-hash.yml")" = 1
cmp "$TMP_DIR/quoted-hash.before" "$TMP_DIR/quoted-hash.yml.pre-mp3-audio-profile.bak"
if cmp -s "$TMP_DIR/quoted-hash.before" "$TMP_DIR/quoted-hash.yml"; then
    echo "quoted hash scalar was incorrectly treated as the canonical profile" >&2
    exit 1
fi

awk '
    /^                - name: "Home Assistant Audio"$/ {
        sub(/"Home Assistant Audio"/, "Home Assistant Audio")
        print $0 "   "
        next
    }
    /^                - name: '\''Home Assistant Audio MP3'\''$/ {
        print $0 "  "
        next
    }
    { print }
' "$TMP_DIR/quoted.yml" > "$TMP_DIR/trailing-space.yml"
cp "$TMP_DIR/trailing-space.yml" "$TMP_DIR/trailing-space.before"
"$MIGRATOR" "$TMP_DIR/trailing-space.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null
cmp "$TMP_DIR/trailing-space.before" "$TMP_DIR/trailing-space.yml"
test ! -e "$TMP_DIR/trailing-space.yml.pre-mp3-audio-profile.bak"
assert_profiles "$TMP_DIR/trailing-space.yml"

cat > "$TMP_DIR/unknown.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio MP3
                  cmd: '%FFMPEG% -i pipe:0 -f mp3 pipe:1'
        encoded:
            mp4:
                - name: Video
                  cmd: '%FFMPEG% -ss %SS% -i %INPUT% -f mp4 pipe:1'
YAML
cp "$TMP_DIR/unknown.yml" "$TMP_DIR/unknown.before"
if "$MIGRATOR" "$TMP_DIR/unknown.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null 2>"$TMP_DIR/unknown.err"; then
    echo "unknown same-name config unexpectedly migrated" >&2
    exit 1
fi
cmp "$TMP_DIR/unknown.before" "$TMP_DIR/unknown.yml"
test ! -e "$TMP_DIR/unknown.yml.pre-mp3-audio-profile.bak"
grep -q 'unknown or conflicting command' "$TMP_DIR/unknown.err"

cat > "$TMP_DIR/conflicting.yml" <<'YAML'
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio MP3 # conflicting output options
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0?
                      -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1 -c:a aac -f mp4
                - name: Home Assistant Audio
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0?
                      -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k
                      -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000
                      -y -f mp4 pipe:1
        encoded:
            mp4:
                - name: Home Assistant Audio MP3
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0?
                      -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1
                - name: Home Assistant Audio
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0?
                      -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k
                      -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000
                      -y -f mp4 pipe:1
YAML
cp "$TMP_DIR/conflicting.yml" "$TMP_DIR/conflicting.before"
if "$MIGRATOR" "$TMP_DIR/conflicting.yml" "$AWK_SCRIPT" "$TS_PROFILE" "$ENCODED_PROFILE" \
    "$MP3_TS_PROFILE" "$MP3_ENCODED_PROFILE" >/dev/null 2>"$TMP_DIR/conflicting.err"; then
    echo "conflicting same-name config unexpectedly migrated" >&2
    exit 1
fi
cmp "$TMP_DIR/conflicting.before" "$TMP_DIR/conflicting.yml"
test ! -e "$TMP_DIR/conflicting.yml.pre-mp3-audio-profile.bak"
grep -q 'unknown or conflicting command' "$TMP_DIR/conflicting.err"

echo "recorded audio profile insertion: OK"
