#!/bin/sh
# Fixture-only runtime supervision tests. Every executable and path is
# overridden; no host service, USB device, or HA setting is touched.
set -eu

LC_ALL=C
export LC_ALL
CDPATH=
export CDPATH

script_dir=$(cd "$(dirname "$0")" && pwd)
addon_dir=$(cd "$script_dir/.." && pwd)
run_sh=$addon_dir/run.sh
effective_config_helper=$addon_dir/generate-effective-config.py
dockerfile=$addon_dir/Dockerfile
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mirakc-runtime-test.XXXXXX")
run_pid=
case_dir=

cleanup()
{
    if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then
        kill -TERM "$run_pid" 2>/dev/null || :
        wait "$run_pid" 2>/dev/null || :
    fi
    if [ "${KEEP_TEST_TMP:-0}" != 1 ]; then
        rm -rf "$tmp_dir" || :
    else
        echo "fixture directory kept: $tmp_dir" >&2
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
    grep -Fq "$needle" "$file" || fail "$description: missing [$needle]"
}

assert_production_ifd_path()
{
    production_ifd_path=$(awk -F ':-' \
        '/^PX4_IFD_LIBRARY=/{value=$2; sub(/}.*/, "", value); print value}' \
        "$run_sh")
    assert_equal 1 "$(printf '%s\n' "$production_ifd_path" | wc -l | awk '{print $1}')" \
        'production IFD default count'
    assert_equal /usr/lib/px4-userland/libpx4-userland-ifd.so \
        "$production_ifd_path" 'production IFD default path'
    case $production_ifd_path in
        /usr/lib/pcsc/drivers/*|*.bundle*)
            fail "production IFD path must not be a pcsc bundle path: $production_ifd_path"
            ;;
    esac
    assert_contains \
        'px4_ifd_library=/usr/lib/px4-userland/libpx4-userland-ifd.so' \
        "$dockerfile" 'build manifest IFD path'
    if grep -Eq '/usr/lib/pcsc/drivers/|\.bundle' "$dockerfile"; then
        fail 'Dockerfile must not create or install an IFD pcsc bundle path'
    fi
}

assert_production_ifd_path

wait_for_file()
{
    file=$1
    description=$2
    tries=0
    while [ ! -f "$file" ]; do
        tries=$((tries + 1))
        [ "$tries" -lt 300 ] || fail "$description: timed out waiting for $file"
        sleep 0.02
    done
}

wait_status()
{
    if wait "$run_pid"; then
        run_status=0
    else
        run_status=$?
    fi
    run_pid=
}

stop_run()
{
    kill -TERM "$run_pid" 2>/dev/null || :
    wait_status
}

write_stub_scripts()
{
    stub_dir=$1
    mkdir -p "$stub_dir"

    cat > "$stub_dir/detect" <<'EOF'
#!/bin/sh
set -eu
if [ "${DETECT_MODE:-valid}" = valid ]; then
    printf '%s\n' 00001205000960
else
    echo "fixture detector: no complete Q3U4 pair" >&2
    exit 1
fi
EOF

    cat > "$stub_dir/px4d" <<'EOF'
#!/bin/sh
set -eu
log=${STUB_LOG:?}
stub_dir=${STUB_DIR:?}
on_term()
{
    printf '%s\n' 'px4d-term' >> "$STUB_LOG"
    printf '%s\n' 'px4d-exit' >> "$STUB_LOG"
    exit 0
}
trap on_term TERM INT HUP
printf '%s\n' 'px4d-start' >> "$log"
tab=$(printf '\t')
argv_record=px4d-argv
for argument in "$@"; do argv_record="$argv_record${tab}$argument"; done
printf '%s\n' "$argv_record" >> "$log"
printf '%s\n' "$$" > "$stub_dir/px4d.pid"
if [ "${PX4D_STUB_MODE:-run}" = fail ]; then
    printf 'px4d-exit\n' >> "$log"
    exit 1
fi
while :; do sleep 0.02; done
EOF

    cat > "$stub_dir/pcscd" <<'EOF'
#!/bin/sh
set -eu
log=${STUB_LOG:?}
stub_dir=${STUB_DIR:?}
on_term()
{
    printf '%s\n' 'pcscd-term' >> "$STUB_LOG"
    printf '%s\n' 'pcscd-exit' >> "$STUB_LOG"
    exit 0
}
trap on_term TERM INT HUP
printf '%s\n' 'pcscd-start' >> "$log"
tab=$(printf '\t')
argv_record=pcscd-argv
for argument in "$@"; do argv_record="$argv_record${tab}$argument"; done
printf '%s\n' "$argv_record" >> "$log"
printf '%s\n' "$$" > "$stub_dir/pcscd.pid"
while :; do sleep 0.02; done
EOF

    cat > "$stub_dir/mirakc" <<'EOF'
#!/bin/sh
set -eu
log=${STUB_LOG:?}
stub_dir=${STUB_DIR:?}
on_term()
{
    printf '%s\n' 'mirakc-term' >> "$STUB_LOG"
    printf '%s\n' 'mirakc-exit' >> "$STUB_LOG"
    exit 0
}
trap on_term TERM INT HUP
printf '%s\n' 'mirakc-start' >> "$log"
tab=$(printf '\t')
env_record="mirakc-env${tab}${PX4_DEVICE-}${tab}${PX4_RUNTIME_DIR-}"
printf '%s\n' "$env_record" >> "$log"
printf '%s\n' "$$" > "$stub_dir/mirakc.pid"
while :; do sleep 0.02; done
EOF

    cat > "$stub_dir/px4ctl" <<'EOF'
#!/bin/sh
set -eu
if [ "${PX4CTL_MODE:-ready}" = ready ]; then
    printf '%s\n' 'serial=00001205000960 ready=yes usb-present-mask=0x03'
    exit 0
fi
printf '%s\n' 'serial=00001205000960 ready=no usb-present-mask=0x00' >&2
exit 5
EOF

    cat > "$stub_dir/siano-ts" <<'EOF'
#!/bin/sh
set -eu
if [ "${1-}" = --list ]; then
    printf '%s\n' "${SIANO_LIST_OUTPUT:-0 devices}"
    exit "${SIANO_LIST_STATUS:-0}"
fi
tab=$(printf '\t')
warmup_record=siano-warmup
for argument in "$@"; do warmup_record="$warmup_record${tab}$argument"; done
printf '%s\n' "$warmup_record" >> "${STUB_LOG:?}"
exit 0
EOF

    chmod 755 "$stub_dir"/*
}

new_case()
{
    name=$1
    case_dir=$tmp_dir/$name
    mkdir -p "$case_dir/template-dir" "$case_dir/app-dir" "$case_dir/data" \
        "$case_dir/runtime" "$case_dir/reader-dir" "$case_dir/ifd" "$case_dir/stubs"
    chmod 755 "$case_dir/runtime"
    cp "$addon_dir/config.yml.template" "$case_dir/template-dir/config.yml"
    python3 - "$case_dir/template-dir/config.yml" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
config["tuners"].append({
    "name": "fixture custom tuner",
    "types": ["GR"],
    "command": "/usr/local/bin/custom-tuner {{{channel}}}",
})
with open(path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(config, stream, sort_keys=False, allow_unicode=True)
PY
    printf '%s\n' 'siano fixture' > "$case_dir/siano-firmware.bin"
    printf '%s\n' 'q3u4 fixture firmware' > "$case_dir/it930x-firmware.bin"
    cat > "$case_dir/reader.conf.in" <<'EOF'
FRIENDLYNAME "fixture"
DEVICENAME px4-userland:runtime=@PX4_RUNTIME_DIR@:device=@PX4_BASE_SERIAL@:access=user
LIBPATH @PX4_IFD_LIBRARY@
CHANNELID 0
EOF
    printf '%s\n' 'fixture IFD library' > "$case_dir/ifd/libpx4-userland-ifd.so"
    write_stub_scripts "$case_dir/stubs"
    firmware_size=$(wc -c < "$case_dir/it930x-firmware.bin" | awk '{print $1}')
    firmware_hash=$(sha256sum "$case_dir/it930x-firmware.bin" | awk '{print $1}')
    printf '# comment\n\n%s\t%s\t%s\n' \
        it930x-firmware.bin "$firmware_size" "$firmware_hash" \
        > "$case_dir/allowlist.txt"
}

start_case()
{
    allowlist_mode=${1:-valid}
    detect_mode=${2:-valid}
    px4d_mode=${3:-run}
    px4ctl_mode=${4:-ready}
    siano_list_output=${5:-0 devices}
    log=$case_dir/events.log
    : > "$log"
    case $allowlist_mode in
        valid|comments) ;;
        missing-firmware) rm -f "$case_dir/it930x-firmware.bin" ;;
        missing-allowlist) rm -f "$case_dir/allowlist.txt" ;;
        size-mismatch) sed 's/[0-9][0-9]*/999999/' "$case_dir/allowlist.txt" > "$case_dir/allowlist.bad"; mv "$case_dir/allowlist.bad" "$case_dir/allowlist.txt" ;;
        hash-mismatch) sed 's/[0-9a-f][0-9a-f]*/0000000000000000000000000000000000000000000000000000000000000000/' "$case_dir/allowlist.txt" > "$case_dir/allowlist.bad"; mv "$case_dir/allowlist.bad" "$case_dir/allowlist.txt" ;;
        basename-mismatch) sed 's/it930x-firmware.bin/other-firmware.bin/' "$case_dir/allowlist.txt" > "$case_dir/allowlist.bad"; mv "$case_dir/allowlist.bad" "$case_dir/allowlist.txt" ;;
        reader-template-missing)
            printf '%s\n' 'old reader config sentinel' > "$case_dir/reader-dir/px4-userland.conf"
            rm -f "$case_dir/reader.conf.in"
            ;;
        ifd-missing)
            printf '%s\n' 'old reader config sentinel' > "$case_dir/reader-dir/px4-userland.conf"
            rm -f "$case_dir/ifd/libpx4-userland-ifd.so"
            ;;
        reader-output-failure)
            rm -rf "$case_dir/reader-dir"
            printf '%s\n' 'reader directory blocker' > "$case_dir/reader-dir"
            ;;
        *) fail "unknown allowlist mode: $allowlist_mode" ;;
    esac
    if [ "$allowlist_mode" = comments ]; then
        firmware_size=$(wc -c < "$case_dir/it930x-firmware.bin" | awk '{print $1}')
        firmware_hash=$(sha256sum "$case_dir/it930x-firmware.bin" | awk '{print $1}')
        printf '# another comment\n\n%s\t%s\t%s\n' \
            it930x-firmware.bin "$firmware_size" "$firmware_hash" \
            > "$case_dir/allowlist.txt"
    fi

    env \
        MIRAKC_USER_CONFIG="$case_dir/config.yml" \
        MIRAKC_APP_CONFIG="$case_dir/app-dir/config.yml" \
        MIRAKC_TEMPLATE="$case_dir/template-dir/config.yml" \
        MIRAKC_DATA_DIR="$case_dir/data" \
        PX_S1UD_FIRMWARE="$case_dir/siano-firmware.bin" \
        PX4_FIRMWARE="$case_dir/it930x-firmware.bin" \
        PX4_FIRMWARE_ALLOWLIST="$case_dir/allowlist.txt" \
        PX4_RUNTIME_DIR="$case_dir/runtime" \
        PX4_READER_TEMPLATE="$case_dir/reader.conf.in" \
        PX4_READER_CONFIG="$case_dir/reader-dir/px4-userland.conf" \
        PX4_DETECT_BIN="$case_dir/stubs/detect" \
        PX4D_BIN="$case_dir/stubs/px4d" \
        PX4CTL_BIN="$case_dir/stubs/px4ctl" \
        PCSC_BIN="$case_dir/stubs/pcscd" \
        MIRAKC_BIN="$case_dir/stubs/mirakc" \
        SIANO_TS_BIN="$case_dir/stubs/siano-ts" \
        MIRAKC_EFFECTIVE_CONFIG_HELPER="$effective_config_helper" \
        SIANO_LIST_OUTPUT="$siano_list_output" \
        PX4_IFD_LIBRARY="$case_dir/ifd/libpx4-userland-ifd.so" \
        PX4_READY_TIMEOUT_SECONDS=1 \
        PX4_READY_POLL_INTERVAL_SECONDS=0.02 \
        PX4_MONITOR_INTERVAL_SECONDS=0.02 \
        PX4_CHILD_STOP_TIMEOUT_SECONDS=1 \
        SIANO_WARMUP_TIMEOUT_SECONDS=0 \
        DETECT_MODE="$detect_mode" \
        PX4D_STUB_MODE="$px4d_mode" \
        PX4CTL_MODE="$px4ctl_mode" \
        STUB_DIR="$case_dir/stubs" \
        STUB_LOG="$log" \
        sh "$run_sh" > "$case_dir/stdout" 2> "$case_dir/stderr" &
    run_pid=$!
}

assert_no_reader_artifacts()
{
    [ ! -e "$case_dir/reader-dir/px4-userland.conf" ] || \
        fail 'reader config remained after failed generation'
    reader_artifacts=$(find "$case_dir" -type f -name '.px4-userland.conf.*' -print)
    [ -z "$reader_artifacts" ] || fail "reader temporary file remained: $reader_artifacts"
}

assert_runtime_mode_700()
{
    actual_mode=$(stat -c %a "$case_dir/runtime")
    assert_equal 700 "$actual_mode" "$1 runtime directory mode"
}

assert_cleanup_order()
{
    log=$1
    mirakc_term=$(awk '$0 == "mirakc-term" {print NR; exit}' "$log")
    mirakc_exit=$(awk '$0 == "mirakc-exit" {print NR; exit}' "$log")
    pcscd_term=$(awk '$0 == "pcscd-term" {print NR; exit}' "$log")
    pcscd_exit=$(awk '$0 == "pcscd-exit" {print NR; exit}' "$log")
    px4d_term=$(awk '$0 == "px4d-term" {print NR; exit}' "$log")
    [ -n "$mirakc_term" ] && [ -n "$mirakc_exit" ] && [ -n "$pcscd_term" ] && \
        [ -n "$pcscd_exit" ] && [ -n "$px4d_term" ] || fail "cleanup events are incomplete"
    [ "$mirakc_term" -lt "$mirakc_exit" ] || fail "mirakc did not exit after TERM"
    [ "$mirakc_exit" -lt "$pcscd_term" ] || fail "pcscd stopped before mirakc exit"
    [ "$pcscd_term" -lt "$pcscd_exit" ] || fail "pcscd did not exit after TERM"
    [ "$pcscd_exit" -lt "$px4d_term" ] || fail "px4d stopped before pcscd exit"
}

assert_before()
{
    first=$1
    second=$2
    log=$3
    description=$4
    first_line=$(awk -v event="$first" '$0 == event {print NR; exit}' "$log")
    second_line=$(awk -v event="$second" '$0 == event {print NR; exit}' "$log")
    [ -n "$first_line" ] && [ -n "$second_line" ] || fail "$description: event missing"
    [ "$first_line" -lt "$second_line" ] || fail "$description: wrong order"
}

assert_failed_child_cleanup_order()
{
    target=$1
    log=$2
    case $target in
        mirakc)
            assert_before mirakc-exit pcscd-term "$log" 'mirakc failure cleanup'
            assert_before pcscd-exit px4d-term "$log" 'pcscd wait before px4d after mirakc failure'
            ;;
        pcscd)
            assert_before pcscd-exit mirakc-term "$log" 'pcscd failure observed before cleanup'
            assert_before mirakc-exit px4d-term "$log" 'mirakc cleanup after pcscd failure'
            ;;
        px4d)
            assert_before px4d-exit mirakc-term "$log" 'px4d failure observed before cleanup'
            assert_before mirakc-exit pcscd-term "$log" 'mirakc cleanup after px4d failure'
            assert_before pcscd-term pcscd-exit "$log" 'pcscd exits after mirakc on px4d failure'
            ;;
        *) fail "unknown failed child: $target" ;;
    esac
}

assert_disabled_cleanup_order()
{
    log=$1
    mirakc_term=$(awk '$0 == "mirakc-term" {print NR; exit}' "$log")
    mirakc_exit=$(awk '$0 == "mirakc-exit" {print NR; exit}' "$log")
    pcscd_term=$(awk '$0 == "pcscd-term" {print NR; exit}' "$log")
    pcscd_exit=$(awk '$0 == "pcscd-exit" {print NR; exit}' "$log")
    [ -n "$mirakc_term" ] && [ -n "$mirakc_exit" ] && [ -n "$pcscd_term" ] && \
        [ -n "$pcscd_exit" ] || fail "disabled cleanup events are incomplete"
    [ "$mirakc_term" -lt "$mirakc_exit" ] || fail "mirakc did not exit after TERM"
    [ "$mirakc_exit" -lt "$pcscd_term" ] || fail "pcscd stopped before mirakc exit"
    [ "$pcscd_term" -lt "$pcscd_exit" ] || fail "pcscd did not exit after TERM"
}

assert_stopped_cleanly()
{
    stop_run
    assert_equal 0 "$run_status" "SIGTERM status"
    assert_cleanup_order "$case_dir/events.log"
}

run_disabled_case()
{
    name=$1
    allowlist_mode=$2
    detect_mode=$3
    new_case "$name"
    start_case "$allowlist_mode" "$detect_mode"
    wait_for_file "$case_dir/stubs/pcscd.pid" "$name pcscd start"
    wait_for_file "$case_dir/stubs/mirakc.pid" "$name mirakc start"
    assert_runtime_mode_700 "$name"
    sleep 0.1
    [ ! -f "$case_dir/stubs/px4d.pid" ] || fail "$name: px4d must not start"
    assert_contains 'Q3U4 disabled' "$case_dir/stderr" "$name diagnostic"
    stop_run
    assert_equal 0 "$run_status" "disabled SIGTERM status"
    assert_disabled_cleanup_order "$case_dir/events.log"
}

run_disabled_case q3u4_missing_firmware missing-firmware valid
run_disabled_case q3u4_missing_allowlist missing-allowlist valid
run_disabled_case q3u4_size_mismatch size-mismatch valid
run_disabled_case q3u4_hash_mismatch hash-mismatch valid
run_disabled_case q3u4_basename_mismatch basename-mismatch valid
run_disabled_case q3u4_not_detected valid absent

run_reader_failure_case()
{
    name=$1
    mode=$2
    new_case "$name"
    start_case "$mode" valid
    wait_status
    [ "$run_status" -ne 0 ] || fail "$name: reader preparation failure must be fatal"
    for child in px4d pcscd mirakc; do
        [ ! -e "$case_dir/stubs/$child.pid" ] || fail "$name: $child must not start"
    done
    assert_no_reader_artifacts
    assert_contains 'Q3U4 setup failed' "$case_dir/stderr" "$name fatal diagnostic"
}

run_reader_failure_case reader_template_missing reader-template-missing
run_reader_failure_case ifd_library_missing ifd-missing
run_reader_failure_case reader_output_directory_failure reader-output-failure

new_case q3u4_allowlist_comments
start_case comments valid
wait_for_file "$case_dir/stubs/px4d.pid" 'commented allowlist px4d start'
wait_for_file "$case_dir/stubs/pcscd.pid" 'commented allowlist pcscd start'
wait_for_file "$case_dir/stubs/mirakc.pid" 'commented allowlist mirakc start'
stop_run
assert_equal 0 "$run_status" 'commented allowlist SIGTERM status'
assert_cleanup_order "$case_dir/events.log"

new_case q3u4_valid
start_case valid valid
wait_for_file "$case_dir/stubs/px4d.pid" 'valid px4d start'
wait_for_file "$case_dir/stubs/pcscd.pid" 'valid pcscd start'
wait_for_file "$case_dir/stubs/mirakc.pid" 'valid mirakc start'
wait_for_file "$case_dir/reader-dir/px4-userland.conf" 'reader config generation'
assert_runtime_mode_700 'valid Q3U4'
[ -f "$case_dir/app-dir/config.yml" ] && [ ! -L "$case_dir/app-dir/config.yml" ] || \
    fail 'effective config must be a regular file, not a symlink'
assert_contains '/usr/local/bin/custom-tuner {{{channel}}}' "$case_dir/app-dir/config.yml" \
    'custom tuner in effective config'
assert_contains "runtime=$case_dir/runtime" "$case_dir/reader-dir/px4-userland.conf" 'reader runtime placeholder'
assert_contains 'device=00001205000960' "$case_dir/reader-dir/px4-userland.conf" 'reader serial placeholder'
assert_contains "LIBPATH $case_dir/ifd/libpx4-userland-ifd.so" "$case_dir/reader-dir/px4-userland.conf" 'reader library placeholder'
if grep -Eq '@PX4_[A-Z_]+@' "$case_dir/reader-dir/px4-userland.conf"; then
    fail 'reader config has an unreplaced placeholder'
fi
px4d_argv=$(grep '^px4d-argv' "$case_dir/events.log")
expected_px4d_argv=$(printf 'px4d-argv\t--device\t00001205000960\t--firmware\t%s\t--runtime-dir\t%s' \
    "$case_dir/it930x-firmware.bin" "$case_dir/runtime")
assert_equal "$expected_px4d_argv" "$px4d_argv" 'px4d argv'
pcscd_argv=$(grep '^pcscd-argv' "$case_dir/events.log")
expected_pcscd_argv=$(printf 'pcscd-argv\t--foreground\t--disable-polkit')
assert_equal "$expected_pcscd_argv" "$pcscd_argv" 'pcscd foreground argv'
expected_mirakc_env=$(printf 'mirakc-env\t%s\t%s' 00001205000960 "$case_dir/runtime")
actual_mirakc_env=$(grep '^mirakc-env' "$case_dir/events.log")
assert_equal "$expected_mirakc_env" "$actual_mirakc_env" 'mirakc PX4 environment'
assert_contains "$case_dir/it930x-firmware.bin" "$case_dir/events.log" 'px4d firmware argv'
assert_contains "$case_dir/runtime" "$case_dir/events.log" 'px4d runtime argv'
if grep -Fq -- '--allow-lnb-power' "$case_dir/events.log"; then
    fail 'px4d must not receive --allow-lnb-power'
fi
assert_stopped_cleanly

two_siano_list=$(printf '%s\n' \
    '0: 3275:0080 supported' \
    '1: 3275:0080 supported' \
    '2 supported RIO device(s), 2 known Siano device(s)')
new_case q3u4_absent_two_siano
start_case valid absent run ready "$two_siano_list"
wait_for_file "$case_dir/stubs/pcscd.pid" 'two Siano pcscd start'
wait_for_file "$case_dir/stubs/mirakc.pid" 'two Siano mirakc start'
assert_equal 2 "$(grep -c 'PX-S1UD #' "$case_dir/app-dir/config.yml")" 'two Siano retained count'
assert_equal 0 "$(grep -c 'PX-Q3U4 #' "$case_dir/app-dir/config.yml" || :)" 'Q3U4 removed count'
assert_equal 11 "$(grep -c '^  type: GR$' "$case_dir/app-dir/config.yml")" 'two Siano retained GR channels'
assert_equal 0 "$(grep -c '^  type: BS$' "$case_dir/app-dir/config.yml" || :)" 'two Siano removed BS channels'
assert_equal 0 "$(grep -c '^  type: CS$' "$case_dir/app-dir/config.yml" || :)" 'two Siano removed CS channels'
actual_warmup_devices=$(awk -F '\t' '$1 == "siano-warmup" && $4 == "--device" {print $5}' "$case_dir/events.log")
expected_warmup_devices=$(printf '0\n1')
assert_equal "$expected_warmup_devices" "$actual_warmup_devices" 'two Siano warmup adapters'
stop_run
assert_equal 0 "$run_status" 'two Siano SIGTERM status'
assert_disabled_cleanup_order "$case_dir/events.log"

one_siano_list=$(printf '%s\n' \
    '0: 3275:0080 supported' \
    '-: 187f:0010 Siano Stellar ROM (unsupported)' \
    '1 supported RIO device(s), 2 known Siano device(s)')
new_case q3u4_present_one_siano
start_case valid valid run ready "$one_siano_list"
wait_for_file "$case_dir/stubs/px4d.pid" 'one Siano px4d start'
wait_for_file "$case_dir/stubs/pcscd.pid" 'one Siano pcscd start'
wait_for_file "$case_dir/stubs/mirakc.pid" 'one Siano mirakc start'
assert_equal 1 "$(grep -c 'PX-S1UD #' "$case_dir/app-dir/config.yml")" 'one Siano retained count'
assert_equal 8 "$(grep -c 'PX-Q3U4 #' "$case_dir/app-dir/config.yml")" 'one Siano Q3U4 retained count'
actual_warmup_devices=$(awk -F '\t' '$1 == "siano-warmup" && $4 == "--device" {print $5}' "$case_dir/events.log")
assert_equal 0 "$actual_warmup_devices" 'one Siano warmup adapter'
stop_run
assert_equal 0 "$run_status" 'one Siano SIGTERM status'
assert_cleanup_order "$case_dir/events.log"

new_case ready_timeout
start_case valid valid run timeout
wait_status
[ "$run_status" -ne 0 ] || fail 'ready timeout must be fatal'
assert_contains 'px4d ready timeout' "$case_dir/stderr" 'ready timeout diagnostic'
[ ! -f "$case_dir/stubs/pcscd.pid" ] || fail 'pcscd started after ready timeout'

new_case px4d_start_failure
start_case valid valid fail timeout
wait_status
[ "$run_status" -ne 0 ] || fail 'px4d startup failure must be fatal'
assert_contains 'px4d failed to start or become ready' "$case_dir/stderr" 'px4d startup diagnostic'
[ ! -f "$case_dir/stubs/pcscd.pid" ] || fail 'pcscd started after px4d startup failure'

run_child_failure_case()
{
    name=$1
    target=$2
    new_case "$name"
    start_case valid valid
    wait_for_file "$case_dir/stubs/$target.pid" "$name target start"
    wait_for_file "$case_dir/stubs/mirakc.pid" "$name mirakc start"
    wait_for_file "$case_dir/stubs/pcscd.pid" "$name pcscd start"
    target_pid=$(cat "$case_dir/stubs/$target.pid")
    kill -TERM "$target_pid"
    wait_status
    [ "$run_status" -ne 0 ] || fail "$name: parent must be non-zero"
    assert_failed_child_cleanup_order "$target" "$case_dir/events.log"
}

run_child_failure_case mirakc_exit mirakc
run_child_failure_case pcscd_exit pcscd
run_child_failure_case px4d_exit px4d

run_effective_config_failure_case()
{
    name=$1
    config_content=$2
    new_case "$name"
    printf '%s\n' "$config_content" > "$case_dir/config.yml"
    printf '%s\n' 'stale effective config' > "$case_dir/app-dir/config.yml"
    start_case valid absent
    wait_status
    [ "$run_status" -ne 0 ] || fail "$name: config generation failure must be fatal"
    for child in px4d pcscd mirakc; do
        [ ! -e "$case_dir/stubs/$child.pid" ] || fail "$name: $child must not start"
    done
    [ ! -e "$case_dir/app-dir/config.yml" ] || fail "$name: stale effective config remained"
    assert_contains 'effective config generation failed' "$case_dir/stderr" "$name diagnostic"
}

run_effective_config_failure_case malformed_user_yaml 'tuners: [this is not valid YAML'
run_effective_config_failure_case no_effective_tuners 'server: {}'

template=$addon_dir/config.yml.template
assert_equal 8 "$(grep -c 'name: \"PX-Q3U4 #' "$template")" 'Q3U4 tuner count'
assert_equal 2 "$(grep -c 'name: \"PX-S1UD #' "$template")" 'Siano tuner count'
assert_contains 'channel: BS15_0' "$template" 'BS satellite channel'
assert_contains 'channel: CS8' "$template" 'CS satellite channel'
assert_contains 'name: ショップチャンネル' "$template" 'CS free service name'
assert_contains 'services: [55]' "$template" 'CS free service ID'
if grep -Fq -- '--allow-lnb-power' "$template"; then
    fail 'template must not opt in to LNB power'
fi
for receiver in 0 1 4 5; do
    block=$(grep -A5 "name: \"PX-Q3U4 #$receiver\"" "$template")
    printf '%s\n' "$block" | grep -Fq -- '- BS' || fail "receiver $receiver missing BS"
    printf '%s\n' "$block" | grep -Fq -- '- CS' || fail "receiver $receiver missing CS"
done
for receiver in 2 3 6 7; do
    block=$(grep -A5 "name: \"PX-Q3U4 #$receiver\"" "$template")
    printf '%s\n' "$block" | grep -Fq -- '- GR' || fail "receiver $receiver missing GR"
done
grep -Fq 'env PX4_RECEIVER=7 /usr/local/bin/px4-ts-stream {{{channel}}}' "$template" || \
    fail 'receiver 7 command missing'

expected_allowlist=$(printf 'it930x-firmware.bin\t2169\t5213a5a38872661277a2cc1b2dfdfe88faf06f41205f460f3b51857f0568b484')
actual_allowlist=$(awk 'NF == 3 && $1 !~ /^#/ {print; exit}' "$addon_dir/firmware-allowlist.txt")
assert_equal "$expected_allowlist" "$actual_allowlist" 'production firmware allowlist'

echo 'PASS: mirakc runtime fixtures'
