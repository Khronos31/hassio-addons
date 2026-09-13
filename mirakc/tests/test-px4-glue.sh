#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

LC_ALL=C
export LC_ALL
CDPATH=
export CDPATH

script_dir=$(cd "$(dirname "$0")" && pwd)
detector=$script_dir/../px4-detect-q3u4
wrapper=$script_dir/../px4-ts-stream
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mirakc-px4-test.XXXXXX")

cleanup()
{
    rm -rf "$tmp_dir" || :
}

cleanup_on_exit()
{
    status=$?
    trap - EXIT HUP INT TERM
    cleanup
    exit "$status"
}

cleanup_on_signal()
{
    trap - EXIT HUP INT TERM
    cleanup
    exit 1
}

trap cleanup_on_exit EXIT
trap cleanup_on_signal HUP INT TERM

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

assert_nonempty_file()
{
    file=$1
    description=$2
    [ -s "$file" ] || fail "$description: expected diagnostic on stderr"
}

assert_no_argument()
{
    actual=$1
    argument=$2
    description=$3
    case $actual in
        *"$argument"*) fail "$description: unexpected [$argument] argument" ;;
    esac
}

assert_argument_followed_by()
{
    actual=$1
    argument=$2
    expected_value=$3
    description=$4
    previous=
    found=
    while IFS= read -r value; do
        if [ "$previous" = "$argument" ]; then
            assert_equal "$expected_value" "$value" "$description"
            found=1
        fi
        previous=$value
    done <<EOF
$actual
EOF
    [ "$found" = 1 ] || fail "$description: missing [$argument] argument"
}

usb_device()
{
    name=$1
    vendor=$2
    product=$3
    serial=$4
    path=$sysfs_root/$name
    mkdir -p "$path"
    printf '%s\n' "$vendor" > "$path/idVendor"
    printf '%s\n' "$product" > "$path/idProduct"
    if [ "$serial" != - ]; then
        printf '%s\n' "$serial" > "$path/serial"
    fi
}

reset_sysfs()
{
    rm -rf "$sysfs_root"
    mkdir -p "$sysfs_root"
}

expect_detector_success()
{
    expected=$1
    description=$2
    if ! actual=$(PX4_SYSFS_ROOT=$sysfs_root "$detector" 2>"$tmp_dir/detector.err"); then
        fail "$description: detector unexpectedly failed"
    fi
    assert_equal "$expected" "$actual" "$description"
}

expect_detector_failure()
{
    description=$1
    if PX4_SYSFS_ROOT=$sysfs_root "$detector" >"$tmp_dir/detector.out" 2>"$tmp_dir/detector.err"; then
        fail "$description: detector unexpectedly succeeded"
    fi
    assert_nonempty_file "$tmp_dir/detector.err" "$description"
}

sysfs_root=$tmp_dir/sysfs
mkdir -p "$sysfs_root"

reset_sysfs
usb_device 1-1 0511 084a 000012050009601
usb_device 1-2 0511 084a 000012050009602
usb_device 1-3 1234 5678 unrelated
expect_detector_success 00001205000960 "normal serial order and unrelated USB"

reset_sysfs
usb_device 2-a 0511 084a 000012050009602
usb_device 2-b 0511 084a 000012050009601
expect_detector_success 00001205000960 "reverse serial order"

reset_sysfs
usb_device 3-1 1234 5678 unrelated
expect_detector_failure "no Q3U4 devices"

reset_sysfs
usb_device 4-1 0511 084a 000012050009601
expect_detector_failure "one-sided serial pair"

reset_sysfs
usb_device 4-2 0511 084a -
expect_detector_failure "Q3U4 device without serial file"

reset_sysfs
usb_device 5-1 0511 084a 00001205000960X
expect_detector_failure "invalid non-digit serial"

reset_sysfs
usb_device 5-2 0511 084a 000012050009603
expect_detector_failure "invalid serial suffix"

reset_sysfs
usb_device 6-1 0511 084a 000012050009601
usb_device 6-2 0511 084a 000012050009601
usb_device 6-3 0511 084a 000012050009602
expect_detector_failure "duplicate serial suffix"

reset_sysfs
usb_device 7-1 0511 084a 000012050009601
usb_device 7-2 0511 084a 000012050009612
expect_detector_failure "different serial prefixes"

reset_sysfs
usb_device 8-1 0511 084a 000012050009601
usb_device 8-2 0511 084a 000012050009602
usb_device 8-3 0511 084a 000012050009701
expect_detector_failure "complete pair plus another base one-sided"

reset_sysfs
usb_device 9-1 0511 084a 000012050009601
usb_device 9-2 0511 084a 000012050009602
usb_device 9-3 0511 084a 000012050009701
usb_device 9-4 0511 084a 000012050009702
expect_detector_failure "two complete serial pairs"

stub=$tmp_dir/px4-ts-stub
argv_log=$tmp_dir/argv.log
cat > "$stub" <<'EOF'
#!/bin/sh
set -eu
: "${ARGV_LOG:?ARGV_LOG is required}"
printf '%s\n' "$@" > "$ARGV_LOG"
EOF
chmod +x "$stub"

expect_wrapper_argv()
{
    receiver=$1
    channel=$2
    expected_frequency=$3
    expected_slot=$4
    description=$5
    : > "$argv_log"
    if ! PX4_DEVICE=00001205000960 PX4_RECEIVER=$receiver PX4_RUNTIME_DIR=/run/test-px4 PX4_TS_BIN=$stub ARGV_LOG=$argv_log "$wrapper" "$channel"; then
        fail "$description: wrapper unexpectedly failed"
    fi
    if [ "$expected_slot" = - ]; then
        expected=$(printf '%s\n' \
            --device 00001205000960 \
            --receiver "$receiver" \
            --system isdb-t \
            --frequency-khz "$expected_frequency" \
            --runtime-dir /run/test-px4 \
            --output -)
    else
        expected=$(printf '%s\n' \
            --device 00001205000960 \
            --receiver "$receiver" \
            --system isdb-s \
            --frequency-khz "$expected_frequency" \
            --slot "$expected_slot" \
            --lnb-voltage 0 \
            --runtime-dir /run/test-px4 \
            --output -)
    fi
    actual=$(cat "$argv_log")
    assert_equal "$expected" "$actual" "$description"
    if [ "$channel" = T27 ]; then
        assert_no_argument "$actual" --lnb-voltage "$description"
    fi
    case $channel in
        BS15_2|CS2)
            assert_argument_followed_by "$actual" --lnb-voltage 0 "$description"
            ;;
    esac
}

expect_wrapper_failure()
{
    description=$1
    channel=$2
    shift 2
    if env PX4_DEVICE=00001205000960 "$@" PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" "$channel" >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
        fail "$description: wrapper unexpectedly succeeded"
    fi
    assert_nonempty_file "$tmp_dir/wrapper.err" "$description"
}

expect_wrapper_argv 2 T13 473142 - "T13 lower terrestrial boundary"
expect_wrapper_argv 3 T27 557142 - "T27 terrestrial representative"
expect_wrapper_argv 7 T62 767142 - "T62 upper terrestrial boundary"
expect_wrapper_argv 0 BS01_0 1049480 0 "BS01_0 lower satellite boundary"
expect_wrapper_argv 4 BS15_2 1318000 2 "BS15_2 satellite representative"
expect_wrapper_argv 5 BS23_11 1471440 11 "BS23_11 upper satellite boundary"
expect_wrapper_argv 1 CS2 1613000 0 "CS2 lower CS boundary"
expect_wrapper_argv 4 CS24 2053000 0 "CS24 upper CS boundary"

expect_wrapper_failure "terrestrial receiver type mismatch" T13 PX4_RECEIVER=0
expect_wrapper_failure "satellite receiver type mismatch" BS01_0 PX4_RECEIVER=2
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=2 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" CS2 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "CS receiver type mismatch: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "CS receiver type mismatch"
expect_wrapper_failure "invalid terrestrial channel" T12 PX4_RECEIVER=2
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=0 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" BS02_0 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "invalid BS channel: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "invalid BS channel"
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=0 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" CS25 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "invalid CS channel: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "invalid CS channel"
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=2 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" T013 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "leading-zero terrestrial channel: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "leading-zero terrestrial channel"
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=0 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" BS001_0 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "leading-zero BS channel: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "leading-zero BS channel"
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=0 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" CS02 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "leading-zero CS channel: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "leading-zero CS channel"
if env PX4_DEVICE=0000120500096 PX4_RECEIVER=2 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" T13 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "invalid device: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "invalid device"
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=08 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" T13 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "leading-zero receiver: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "leading-zero receiver"
if env PX4_DEVICE=00001205000960 PX4_RECEIVER=8 PX4_TS_BIN="$stub" ARGV_LOG="$argv_log" "$wrapper" T13 >"$tmp_dir/wrapper.out" 2>"$tmp_dir/wrapper.err"; then
    fail "out-of-range receiver: wrapper unexpectedly succeeded"
fi
assert_nonempty_file "$tmp_dir/wrapper.err" "out-of-range receiver"

echo "PASS: PX4 mirakc glue fixtures"
