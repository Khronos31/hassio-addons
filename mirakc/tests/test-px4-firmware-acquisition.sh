#!/bin/sh
# Fixture-only tests for runtime PX-Q3U4 firmware acquisition.  The ZIP and
# every payload are generated under a temporary directory; no network or USB
# device is used.
set -eu

LC_ALL=C
export LC_ALL
CDPATH=
export CDPATH

script_dir=$(cd "$(dirname "$0")" && pwd)
addon_dir=$(cd "$script_dir/.." && pwd)
helper=$addon_dir/px4-acquire-firmware
run_sh=$addon_dir/run.sh
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mirakc-firmware-test.XXXXXX")
helper_pid=

cleanup()
{
    if [ -n "$helper_pid" ] && kill -0 "$helper_pid" 2>/dev/null; then
        kill -TERM "$helper_pid" 2>/dev/null || :
        wait "$helper_pid" 2>/dev/null || :
    fi
    if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then
        echo "fixture directory kept: $tmp_dir" >&2
    else
        rm -rf "$tmp_dir" || :
    fi
}

trap cleanup EXIT HUP INT TERM

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

assert_equal()
{
    expected=$1
    actual=$2
    description=$3
    [ "$actual" = "$expected" ] || fail "$description: expected [$expected], got [$actual]"
}

assert_contains()
{
    needle=$1
    file=$2
    description=$3
    grep -Fq -- "$needle" "$file" || fail "$description: missing [$needle]"
}

assert_manifest_value()
{
    key=$1
    expected=$2
    file=$3
    description=$4
    actual=$(awk -F '\t' -v key="$key" '$1 == key { print $2 }' "$file")
    assert_equal "$expected" "$actual" "$description"
}

assert_argument_followed_by()
{
    argument=$1
    expected=$2
    file=$3
    description=$4
    actual=$(awk -v argument="$argument" '$0 == argument { if (getline) print; exit }' "$file")
    assert_equal "$expected" "$actual" "$description"
}

assert_no_temp_residue()
{
    directory=$1
    residue=$(find "$directory" -maxdepth 1 -type f -name '.px4-firmware.*' -print)
    [ -z "$residue" ] || fail "firmware temporary files remained: $residue"
}

wait_for_file()
{
    file=$1
    description=$2
    tries=0
    while [ ! -f "$file" ]; do
        tries=$((tries + 1))
        [ "$tries" -lt 200 ] || fail "$description: timed out"
        sleep 0.02
    done
}

write_manifest()
{
    path=$1
    archive_size=$2
    archive_hash=$3
    sys_size=$4
    sys_hash=$5
    output_size=$6
    output_hash=$7
    printf '%s\t%s\n' \
        manifest_version 1 \
        archive_url https://plex.invalid/fixture.zip \
        archive_size "$archive_size" \
        archive_sha256 "$archive_hash" \
        sys_entry pxw3u4_BDA_ver1x64/PXW3U4.sys \
        sys_size "$sys_size" \
        sys_sha256 "$sys_hash" \
        output_filename it930x-firmware.bin \
        output_size "$output_size" \
        output_sha256 "$output_hash" > "$path"
}

new_case()
{
    name=$1
    case_dir=$tmp_dir/$name
    mkdir -p "$case_dir/cache" "$case_dir/fwtool" "$case_dir/stubs"
    printf '%s' 'fixture PXW3U4 SYS bytes' > "$case_dir/PXW3U4.fixture"
    python3 - "$case_dir/archive.fixture" "$case_dir/PXW3U4.fixture" <<'PY'
import sys
import zipfile

archive, payload = sys.argv[1:]
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as target:
    target.write(payload, "pxw3u4_BDA_ver1x64/PXW3U4.sys")
PY
    sys_size=$(wc -c < "$case_dir/PXW3U4.fixture" | awk '{print $1}')
    sys_hash=$(sha256sum "$case_dir/PXW3U4.fixture" | awk '{print $1}')
    archive_size=$(wc -c < "$case_dir/archive.fixture" | awk '{print $1}')
    archive_hash=$(sha256sum "$case_dir/archive.fixture" | awk '{print $1}')
    write_manifest "$case_dir/manifest.tsv" "$archive_size" "$archive_hash" \
        "$sys_size" "$sys_hash" "$sys_size" "$sys_hash"
    printf '%s\n' 'fixture fwinfo' > "$case_dir/fwtool/fwinfo.tsv"

    cat > "$case_dir/fwtool/fwtool" <<'EOF'
#!/bin/sh
set -eu
case ${FWTOOL_MODE:-success} in
    success) cp "$1" "$2" ;;
    fail) exit 9 ;;
    corrupt) printf '%s' 'corrupt output' > "$2" ;;
    *) exit 10 ;;
esac
EOF
    cat > "$case_dir/stubs/curl" <<'EOF'
#!/bin/sh
set -eu
: "${CURL_LOG:?}"
: "${ARCHIVE_FIXTURE:?}"
printf '%s\n' curl-call >> "$CURL_LOG"
output=
previous=
for argument in "$@"; do
    printf '%s\n' "$argument" >> "$CURL_LOG"
    if [ "$previous" = --output ]; then output=$argument; fi
    previous=$argument
done
case ${CURL_MODE:-success} in
    success) cp "$ARCHIVE_FIXTURE" "$output" ;;
    fail) exit 22 ;;
    block)
        trap 'printf "%s\n" curl-term >> "$CURL_LOG"; exit 143' TERM INT HUP
        printf '%s\n' curl-started >> "$CURL_LOG"
        while :; do sleep 0.02; done
        ;;
    *) exit 23 ;;
esac
EOF
    chmod 755 "$case_dir/fwtool/fwtool" "$case_dir/stubs/curl"
    : > "$case_dir/curl.log"
}

run_helper()
{
    stdout=$case_dir/helper.stdout
    stderr=$case_dir/helper.stderr
    env \
        PX4_FW_TARGET="$case_dir/cache/it930x-firmware.bin" \
        PX4_FW_SOURCE_MANIFEST="$case_dir/manifest.tsv" \
        PX4_FWTOOL_DIR="$case_dir/fwtool" \
        PX4_FW_CURL_BIN="$case_dir/stubs/curl" \
        PX4_FW_CONNECT_TIMEOUT_SECONDS=7 \
        PX4_FW_TOTAL_TIMEOUT_SECONDS=19 \
        CURL_LOG="$case_dir/curl.log" \
        ARCHIVE_FIXTURE="$case_dir/archive.fixture" \
        CURL_MODE="${CURL_MODE:-success}" \
        FWTOOL_MODE="${FWTOOL_MODE:-success}" \
        sh "$helper" > "$stdout" 2> "$stderr"
}

assert_old_target_unchanged()
{
    target=$case_dir/cache/it930x-firmware.bin
    actual=$(cat "$target")
    assert_equal 'old firmware sentinel' "$actual" "$1 old target preservation"
    assert_no_temp_residue "$case_dir/cache"
}

new_case valid_cache
cp "$case_dir/PXW3U4.fixture" "$case_dir/cache/it930x-firmware.bin"
CURL_MODE=fail run_helper || fail 'valid cache was not reused'
assert_equal 0 "$(grep -c '^curl-call$' "$case_dir/curl.log" || :)" 'valid cache curl calls'
assert_no_temp_residue "$case_dir/cache"

new_case fetch_and_reuse
run_helper || fail 'valid acquisition failed'
cmp "$case_dir/PXW3U4.fixture" "$case_dir/cache/it930x-firmware.bin" || \
    fail 'installed firmware differs from fixture output'
assert_equal 644 "$(stat -c %a "$case_dir/cache/it930x-firmware.bin")" 'installed mode'
assert_equal 1 "$(grep -c '^curl-call$' "$case_dir/curl.log")" 'initial curl calls'
CURL_MODE=fail run_helper || fail 'offline cache reuse failed'
assert_equal 1 "$(grep -c '^curl-call$' "$case_dir/curl.log")" 'offline reuse curl calls'
assert_no_temp_residue "$case_dir/cache"

new_case archive_failure
printf '%s' 'old firmware sentinel' > "$case_dir/cache/it930x-firmware.bin"
write_manifest "$case_dir/manifest.tsv" "$archive_size" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    "$sys_size" "$sys_hash" "$sys_size" "$sys_hash"
if run_helper; then fail 'archive SHA failure unexpectedly succeeded'; fi
assert_contains 'archive failed size or SHA-256' "$case_dir/helper.stderr" 'archive failure diagnostic'
assert_old_target_unchanged 'archive failure'

new_case archive_size_failure
printf '%s' 'old firmware sentinel' > "$case_dir/cache/it930x-firmware.bin"
write_manifest "$case_dir/manifest.tsv" 999999 "$archive_hash" \
    "$sys_size" "$sys_hash" "$sys_size" "$sys_hash"
if run_helper; then fail 'archive size failure unexpectedly succeeded'; fi
assert_contains 'archive failed size or SHA-256' "$case_dir/helper.stderr" 'archive size failure diagnostic'
assert_old_target_unchanged 'archive size failure'

new_case sys_failure
printf '%s' 'old firmware sentinel' > "$case_dir/cache/it930x-firmware.bin"
write_manifest "$case_dir/manifest.tsv" "$archive_size" "$archive_hash" \
    "$sys_size" 0000000000000000000000000000000000000000000000000000000000000000 \
    "$sys_size" "$sys_hash"
if run_helper; then fail 'SYS SHA failure unexpectedly succeeded'; fi
assert_contains 'extracted SYS failed size or SHA-256' "$case_dir/helper.stderr" 'SYS failure diagnostic'
assert_old_target_unchanged 'SYS failure'

new_case fwtool_failure
printf '%s' 'old firmware sentinel' > "$case_dir/cache/it930x-firmware.bin"
if FWTOOL_MODE=fail run_helper; then fail 'fwtool failure unexpectedly succeeded'; fi
assert_contains 'fwtool failed' "$case_dir/helper.stderr" 'fwtool failure diagnostic'
assert_old_target_unchanged 'fwtool failure'

new_case output_failure
printf '%s' 'old firmware sentinel' > "$case_dir/cache/it930x-firmware.bin"
if FWTOOL_MODE=corrupt run_helper; then fail 'output failure unexpectedly succeeded'; fi
assert_contains 'generated firmware failed' "$case_dir/helper.stderr" 'output failure diagnostic'
assert_old_target_unchanged 'output failure'

new_case download_failure
printf '%s' 'old firmware sentinel' > "$case_dir/cache/it930x-firmware.bin"
if CURL_MODE=fail run_helper; then fail 'download failure unexpectedly succeeded'; fi
assert_contains 'download failed' "$case_dir/helper.stderr" 'download failure diagnostic'
assert_argument_followed_by --connect-timeout 7 "$case_dir/curl.log" 'curl connect timeout'
assert_argument_followed_by --max-time 19 "$case_dir/curl.log" 'curl total timeout'
assert_argument_followed_by --retry 0 "$case_dir/curl.log" 'curl bounded retry count'
assert_argument_followed_by --proto '=https' "$case_dir/curl.log" 'curl HTTPS protocol restriction'
assert_old_target_unchanged 'download failure'

new_case duplicate_manifest
printf '%s\t%s\n' archive_size "$archive_size" >> "$case_dir/manifest.tsv"
if run_helper; then fail 'duplicate manifest unexpectedly succeeded'; fi
assert_contains 'duplicate' "$case_dir/helper.stderr" 'duplicate manifest diagnostic'
assert_equal 0 "$(grep -c '^curl-call$' "$case_dir/curl.log" || :)" 'duplicate manifest curl calls'

new_case malformed_manifest
printf '%s\n' 'not-a-tab-delimited-record' > "$case_dir/manifest.tsv"
if run_helper; then fail 'malformed manifest unexpectedly succeeded'; fi
assert_contains 'malformed' "$case_dir/helper.stderr" 'malformed manifest diagnostic'
assert_equal 0 "$(grep -c '^curl-call$' "$case_dir/curl.log" || :)" 'malformed manifest curl calls'

# Exercise the run.sh signal path while the real acquisition helper waits on
# its fixture downloader.  No supervised child has started yet.
new_case run_signal
printf '%s' 'old firmware sentinel' > "$case_dir/cache/it930x-firmware.bin"
printf '%s\n' 'siano fixture' > "$case_dir/siano.bin"
printf '%s\n' 'server: {}' > "$case_dir/config.yml"
printf '%s\n' 'server: {}' > "$case_dir/template.yml"
printf '%s\t%s\t%s\n' it930x-firmware.bin "$sys_size" "$sys_hash" > "$case_dir/allowlist.tsv"
mkdir -p "$case_dir/app" "$case_dir/data" "$case_dir/runtime" "$case_dir/reader"
cat > "$case_dir/stubs/detect" <<'EOF'
#!/bin/sh
printf '%s\n' 00001205000960
EOF
chmod 755 "$case_dir/stubs/detect"
env \
    MIRAKC_USER_CONFIG="$case_dir/config.yml" \
    MIRAKC_APP_CONFIG="$case_dir/app/config.yml" \
    MIRAKC_TEMPLATE="$case_dir/template.yml" \
    MIRAKC_DATA_DIR="$case_dir/data" \
    PX_S1UD_FIRMWARE="$case_dir/siano.bin" \
    PX4_FIRMWARE="$case_dir/cache/it930x-firmware.bin" \
    PX4_FIRMWARE_ALLOWLIST="$case_dir/allowlist.tsv" \
    PX4_FIRMWARE_SOURCE_MANIFEST="$case_dir/manifest.tsv" \
    PX4_FIRMWARE_FETCH_BIN="$helper" \
    PX4_FWTOOL_DIR="$case_dir/fwtool" \
    PX4_FW_CURL_BIN="$case_dir/stubs/curl" \
    CURL_LOG="$case_dir/curl.log" \
    ARCHIVE_FIXTURE="$case_dir/archive.fixture" \
    CURL_MODE=block \
    PX4_DETECT_BIN="$case_dir/stubs/detect" \
    PX4_RUNTIME_DIR="$case_dir/runtime" \
    PX4_READER_CONFIG="$case_dir/reader/px4-userland.conf" \
    sh "$run_sh" > "$case_dir/run.stdout" 2> "$case_dir/run.stderr" &
helper_pid=$!
wait_for_file "$case_dir/curl.log" 'run.sh acquisition curl log'
tries=0
until grep -Fq curl-started "$case_dir/curl.log"; do
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] || fail 'run.sh downloader did not enter blocking fixture'
    sleep 0.02
done
started_at=$(date +%s)
kill -TERM "$helper_pid"
signal_status=0
wait "$helper_pid" || signal_status=$?
helper_pid=
elapsed=$(($(date +%s) - started_at))
assert_equal 0 "$signal_status" 'run.sh TERM status during acquisition'
[ "$elapsed" -le 2 ] || fail "run.sh did not terminate downloader promptly: ${elapsed}s"
assert_contains curl-term "$case_dir/curl.log" 'downloader TERM forwarding'
assert_old_target_unchanged 'signal interruption'

production_manifest=$addon_dir/px4-firmware-source.tsv
assert_manifest_value archive_url https://plex-net.co.jp/plex/pxw3u4/pxw3u4_BDA_ver1x64.zip \
    "$production_manifest" 'production archive URL'
assert_manifest_value archive_size 213410 "$production_manifest" 'production archive size'
assert_manifest_value archive_sha256 bdf3b4eb84b69ccbacb4ba3df2f59c93c803ef6d3f61e7a90a531c22c301a200 \
    "$production_manifest" 'production archive SHA-256'
assert_manifest_value sys_entry pxw3u4_BDA_ver1x64/PXW3U4.sys \
    "$production_manifest" 'production SYS entry'
assert_manifest_value sys_size 189440 "$production_manifest" 'production SYS size'
assert_manifest_value sys_sha256 8c7b526e2c92f9b42440b55b99b309c33f2011f4e11de310acf0c1da58038722 \
    "$production_manifest" 'production SYS SHA-256'
assert_manifest_value output_filename it930x-firmware.bin \
    "$production_manifest" 'production output filename'
assert_manifest_value output_size 2169 "$production_manifest" 'production output size'
assert_manifest_value output_sha256 5213a5a38872661277a2cc1b2dfdfe88faf06f41205f460f3b51857f0568b484 \
    "$production_manifest" 'production output SHA-256'

payload_paths=$(git -C "$addon_dir/.." ls-files --cached --others --exclude-standard | \
    awk '{ path = tolower($0) } path ~ /(^|\/)(pxw3u4[^/]*\.zip|pxw3u4\.sys|it930x-firmware\.bin)$/ { print }')
[ -z "$payload_paths" ] || fail "PLEX-derived payload is present in the repository: $payload_paths"

dockerfile=$addon_dir/Dockerfile
assert_contains "fwtool_commit='2b3f79b5bc5db56e8556bb28397f7d8f74b2adeb'" \
    "$dockerfile" 'pinned fwtool commit'
assert_contains 'source_fwtool=/usr/share/src/px4_drv-0.2.1' "$dockerfile" 'pinned fwtool source path'
assert_contains 'fwtool_license=/usr/share/doc/px4_drv-fwtool/LICENSE' "$dockerfile" 'fwtool license path'
assert_contains 'q3u4_firmware_payload=excluded' "$dockerfile" 'firmware payload exclusion manifest'
if grep -Eq 'COPY .*(pxw3u4[^ ]*\.zip|PXW3U4\.sys|it930x-firmware\.bin)' "$dockerfile"; then
    fail 'Dockerfile copies a PLEX-derived payload into the image'
fi

echo 'PASS: PX-Q3U4 firmware acquisition fixtures'
