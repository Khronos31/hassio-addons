#!/bin/sh
# mirakc を Home Assistant のアドオンとして起動する。
# チューナーは siano-ts / px4-ts がユーザー空間から開く。B-CAS は
# recisdb が PC/SC 経由で読むため、pcscd も同じプロセス監督下に置く。
set -eu

LC_ALL=C
export LC_ALL
CDPATH=
export CDPATH

USER_CFG=${MIRAKC_USER_CONFIG:-/config/config.yml}
APP_CFG=${MIRAKC_APP_CONFIG:-/etc/mirakc/config.yml}
TEMPLATE=${MIRAKC_TEMPLATE:-/usr/share/mirakc-addon/config.yml.template}
DATA_DIR=${MIRAKC_DATA_DIR:-/data/epg}
SIANO_FIRMWARE=${PX_S1UD_FIRMWARE:-/lib/firmware/isdbt_rio.inp}
Q3U4_FIRMWARE=${PX4_FIRMWARE:-/config/it930x-firmware.bin}
FIRMWARE_ALLOWLIST=${PX4_FIRMWARE_ALLOWLIST:-/usr/share/mirakc-addon/firmware-allowlist.txt}
FIRMWARE_SOURCE_MANIFEST=${PX4_FIRMWARE_SOURCE_MANIFEST:-/usr/share/mirakc-addon/px4-firmware-source.tsv}
FIRMWARE_FETCH_BIN=${PX4_FIRMWARE_FETCH_BIN:-/usr/local/bin/px4-acquire-firmware}
PX4_RUNTIME_DIR=${PX4_RUNTIME_DIR:-/run/px4-userland}
READER_TEMPLATE=${PX4_READER_TEMPLATE:-/usr/share/mirakc-addon/pcsc/reader.conf.d/px4-userland.conf.in}
READER_CONFIG=${PX4_READER_CONFIG:-/etc/reader.conf.d/px4-userland.conf}
PX4_IFD_LIBRARY=${PX4_IFD_LIBRARY:-/usr/lib/px4-userland/libpx4-userland-ifd.so}
DETECT_BIN=${PX4_DETECT_BIN:-/usr/local/bin/px4-detect-q3u4}
PX4D_BIN=${PX4D_BIN:-/usr/local/bin/px4d}
PX4CTL_BIN=${PX4CTL_BIN:-/usr/local/bin/px4ctl}
PCSC_BIN=${PCSC_BIN:-/usr/sbin/pcscd}
MIRAKC_BIN=${MIRAKC_BIN:-mirakc}
SIANO_TS_BIN=${SIANO_TS_BIN:-siano-ts}
EFFECTIVE_CONFIG_HELPER=${MIRAKC_EFFECTIVE_CONFIG_HELPER:-/usr/local/bin/generate-effective-config.py}
PROC_ROOT=${PROC_ROOT:-/proc}
PX4_READY_TIMEOUT_SECONDS=${PX4_READY_TIMEOUT_SECONDS:-10}
PX4_READY_POLL_INTERVAL_SECONDS=${PX4_READY_POLL_INTERVAL_SECONDS:-1}
PX4_MONITOR_INTERVAL_SECONDS=${PX4_MONITOR_INTERVAL_SECONDS:-1}
PX4_CHILD_STOP_TIMEOUT_SECONDS=${PX4_CHILD_STOP_TIMEOUT_SECONDS:-2}
SIANO_WARMUP_TIMEOUT_SECONDS=${SIANO_WARMUP_TIMEOUT_SECONDS:-3}

case $PX4_READY_TIMEOUT_SECONDS in ''|*[!0-9]*) echo "PX4_READY_TIMEOUT_SECONDS must be a non-negative integer" >&2; exit 2 ;; esac
case $PX4_CHILD_STOP_TIMEOUT_SECONDS in ''|*[!0-9]*) echo "PX4_CHILD_STOP_TIMEOUT_SECONDS must be a non-negative integer" >&2; exit 2 ;; esac
case $SIANO_WARMUP_TIMEOUT_SECONDS in ''|*[!0-9]*) echo "SIANO_WARMUP_TIMEOUT_SECONDS must be a non-negative integer" >&2; exit 2 ;; esac

px4d_pid=
pcscd_pid=
mirakc_pid=
firmware_helper_pid=
PX4_DEVICE=
q3u4_enabled=0
q3_firmware_error=
reader_tmp=
shutdown_requested=0
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mirakc-runtime.XXXXXX")

discard_reader_tmp()
{
    [ -n "$reader_tmp" ] || return 0
    if ! rm -f "$reader_tmp"; then
        echo "could not remove temporary reader config: $reader_tmp" >&2
        return 1
    fi
    reader_tmp=
}

cleanup_tmp()
{
    if [ -n "$reader_tmp" ]; then
        discard_reader_tmp || :
    fi
    rm -rf "$tmp_dir" || :
}

trap cleanup_tmp EXIT

pid_is_alive()
{
    pid=$1
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    # kill -0 also succeeds for a child which has become a zombie. Inspecting
    # procfs lets the monitor notice that exit without wait -n (not POSIX).
    if [ -r "$PROC_ROOT/$pid/stat" ]; then
        state=$(awk '{print $3}' "$PROC_ROOT/$pid/stat" 2>/dev/null || printf '?')
        [ "$state" != Z ] || return 1
    fi
    return 0
}

verify_firmware()
{
    firmware=$1
    allowlist=$2

    if [ ! -r "$firmware" ]; then
        echo "firmware is missing or unreadable: $firmware"
        return 1
    fi
    if [ ! -r "$allowlist" ]; then
        echo "firmware allowlist is missing or unreadable: $allowlist"
        return 1
    fi

    firmware_name=${firmware##*/}
    firmware_size=$(wc -c < "$firmware" | awk '{print $1}')
    firmware_hash=$(sha256sum -- "$firmware" 2>/dev/null | awk '{print $1}') || {
        echo "could not calculate SHA-256: $firmware"
        return 1
    }
    case $firmware_size in ''|*[!0-9]*)
        echo "could not determine firmware byte size: $firmware"
        return 1
        ;;
    esac
    case $firmware_hash in
        ''|*[!0-9a-f]*)
            echo "SHA-256 has an unexpected format for $firmware"
            return 1
            ;;
    esac
    firmware_hash_length=$(printf '%s' "$firmware_hash" | awk '{print length}')
    [ "$firmware_hash_length" -eq 64 ] || {
        echo "SHA-256 has an unexpected length for $firmware"
        return 1
    }

    if awk -F '\t' -v wanted_name="$firmware_name" \
        -v wanted_size="$firmware_size" -v wanted_hash="$firmware_hash" '
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        NF == 3 && $1 == wanted_name && $2 == wanted_size && $3 == wanted_hash {
            found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$allowlist"; then
        return 0
    fi
    echo "firmware is not an exact allowlist match: filename=$firmware_name size=$firmware_size sha256=$firmware_hash"
    return 1
}

ensure_q3u4_firmware()
{
    if verify_output=$(verify_firmware "$Q3U4_FIRMWARE" "$FIRMWARE_ALLOWLIST" 2>&1); then
        return 0
    fi

    if [ ! -x "$FIRMWARE_FETCH_BIN" ]; then
        q3_firmware_error="firmware cache is invalid and acquisition helper is unavailable"
        return 1
    fi

    acquire_stderr=$tmp_dir/q3u4-firmware-acquire.err
    echo "Q3U4 firmware cache is missing or invalid; attempting verified acquisition" >&2
    PX4_FW_TARGET="$Q3U4_FIRMWARE" \
    PX4_FW_SOURCE_MANIFEST="$FIRMWARE_SOURCE_MANIFEST" \
        "$FIRMWARE_FETCH_BIN" 2>"$acquire_stderr" &
    firmware_helper_pid=$!
    acquire_status=0
    wait "$firmware_helper_pid" || acquire_status=$?
    if [ "$shutdown_requested" -ne 0 ]; then
        # A trapped signal can interrupt wait before the helper has finished
        # forwarding TERM and removing its exact temporary files.
        kill -TERM "$firmware_helper_pid" 2>/dev/null || :
        wait "$firmware_helper_pid" 2>/dev/null || :
    fi
    firmware_helper_pid=

    if [ "$shutdown_requested" -ne 0 ]; then
        q3_firmware_error="firmware acquisition interrupted by shutdown"
        return 1
    fi
    if [ "$acquire_status" -ne 0 ]; then
        acquire_reason=$(tail -n 1 "$acquire_stderr" 2>/dev/null | cut -c 1-400)
        [ -n "$acquire_reason" ] || acquire_reason="helper exited with status $acquire_status"
        q3_firmware_error="firmware acquisition failed: $acquire_reason"
        return 1
    fi
    if ! verify_output=$(verify_firmware "$Q3U4_FIRMWARE" "$FIRMWARE_ALLOWLIST" 2>&1); then
        q3_firmware_error="acquired firmware failed the runtime allowlist: $(printf '%s' "$verify_output" | cut -c 1-300)"
        return 1
    fi
    if [ -s "$acquire_stderr" ]; then
        tail -n 2 "$acquire_stderr" >&2
    fi
    return 0
}

detect_q3u4()
{
    detector_stderr=$tmp_dir/q3u4-detector.err
    if base_serial=$("$DETECT_BIN" 2>"$detector_stderr"); then
        if [ -s "$detector_stderr" ]; then
            cat "$detector_stderr" >&2
        fi
    else
        if [ -s "$detector_stderr" ]; then
            cat "$detector_stderr" >&2
        fi
        echo "Q3U4 disabled: serial detection failed" >&2
        return 1
    fi
    case $base_serial in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *)
            echo "Q3U4 disabled: detector returned an invalid base serial: $base_serial" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$base_serial"
}

escape_sed_replacement()
{
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

write_reader_config()
{
    if ! reader_config_dir=$(dirname "$READER_CONFIG"); then
        echo "could not determine reader config directory: $READER_CONFIG" >&2
        return 1
    fi

    # Do not leave a stale configuration active if any later preparation step
    # fails. This also removes a prior configuration when the parent directory
    # is currently unusable, as far as the filesystem permits.
    if ! rm -f "$READER_CONFIG"; then
        echo "could not remove existing reader config: $READER_CONFIG" >&2
        return 1
    fi

    if [ ! -f "$READER_TEMPLATE" ] || [ ! -r "$READER_TEMPLATE" ]; then
        echo "reader template is missing or unreadable: $READER_TEMPLATE" >&2
        return 1
    fi
    if [ ! -f "$PX4_IFD_LIBRARY" ] || [ ! -r "$PX4_IFD_LIBRARY" ]; then
        echo "IFD library is missing or unreadable: $PX4_IFD_LIBRARY" >&2
        return 1
    fi

    # The temporary file is created beside the destination so rename is atomic
    # on the same filesystem.
    if ! mkdir -p "$reader_config_dir"; then
        echo "could not create reader config directory: $reader_config_dir" >&2
        return 1
    fi
    if ! reader_tmp=$(mktemp "$reader_config_dir/.px4-userland.conf.XXXXXX"); then
        echo "could not create temporary reader config in: $reader_config_dir" >&2
        return 1
    fi

    if ! runtime_escaped=$(escape_sed_replacement "$PX4_RUNTIME_DIR"); then
        echo "could not escape PX4 runtime directory for reader config" >&2
        discard_reader_tmp || :
        return 1
    fi
    if ! serial_escaped=$(escape_sed_replacement "$PX4_DEVICE"); then
        echo "could not escape PX4 device serial for reader config" >&2
        discard_reader_tmp || :
        return 1
    fi
    if ! library_escaped=$(escape_sed_replacement "$PX4_IFD_LIBRARY"); then
        echo "could not escape IFD library path for reader config" >&2
        discard_reader_tmp || :
        return 1
    fi
    if ! sed \
        -e "s|@PX4_RUNTIME_DIR@|$runtime_escaped|g" \
        -e "s|@PX4_BASE_SERIAL@|$serial_escaped|g" \
        -e "s|@PX4_IFD_LIBRARY@|$library_escaped|g" \
        "$READER_TEMPLATE" > "$reader_tmp"; then
        echo "could not generate reader config from template: $READER_TEMPLATE" >&2
        discard_reader_tmp || :
        return 1
    fi
    if [ ! -s "$reader_tmp" ]; then
        echo "generated reader config is empty: $READER_TEMPLATE" >&2
        discard_reader_tmp || :
        return 1
    fi

    grep_status=0
    grep -Eq '@PX4_[A-Z_]+@' "$reader_tmp" || grep_status=$?
    if [ "$grep_status" -eq 0 ]; then
        echo "reader config contains an unreplaced PX4 placeholder: $READER_TEMPLATE" >&2
        discard_reader_tmp || :
        return 1
    fi
    if [ "$grep_status" -ne 1 ]; then
        echo "could not validate generated reader config: $reader_tmp" >&2
        discard_reader_tmp || :
        return 1
    fi
    for reader_value in "$PX4_RUNTIME_DIR" "$PX4_DEVICE" "$PX4_IFD_LIBRARY"; do
        grep_status=0
        grep -Fq -- "$reader_value" "$reader_tmp" || grep_status=$?
        if [ "$grep_status" -ne 0 ]; then
            echo "reader config is missing a substituted value: $reader_value" >&2
            discard_reader_tmp || :
            return 1
        fi
    done
    if ! mv "$reader_tmp" "$READER_CONFIG"; then
        echo "could not install generated reader config: $READER_CONFIG" >&2
        discard_reader_tmp || :
        return 1
    fi
    reader_tmp=
}

start_px4d()
{
    echo "starting px4d: device=$PX4_DEVICE firmware=$Q3U4_FIRMWARE runtime=$PX4_RUNTIME_DIR" >&2
    "$PX4D_BIN" \
        --device "$PX4_DEVICE" \
        --firmware "$Q3U4_FIRMWARE" \
        --runtime-dir "$PX4_RUNTIME_DIR" &
    px4d_pid=$!
}

wait_px4_ready()
{
    ready_deadline=$(($(date +%s) + PX4_READY_TIMEOUT_SECONDS))
    while :; do
        if ! pid_is_alive "$px4d_pid"; then
            echo "px4d exited before becoming ready" >&2
            return 1
        fi

        probe_status=0
        probe_output=$("$PX4CTL_BIN" \
            --device "$PX4_DEVICE" \
            --runtime-dir "$PX4_RUNTIME_DIR" list 2>&1) || probe_status=$?
        if [ -n "$probe_output" ]; then
            printf '%s\n' "$probe_output" >&2
        fi
        if [ "$probe_status" -eq 0 ] && printf '%s\n' "$probe_output" | awk '
            /(^|[[:space:]])ready=yes([[:space:]]|$)/ &&
            /(^|[[:space:]])usb-present-mask=0x03([[:space:]]|$)/ { found = 1 }
            END { exit found ? 0 : 1 }
        '; then
            echo "px4d ready: device=$PX4_DEVICE" >&2
            return 0
        fi

        now=$(date +%s)
        [ "$now" -ge "$ready_deadline" ] && break
        sleep "$PX4_READY_POLL_INTERVAL_SECONDS" || :
    done
    echo "px4d ready timeout after ${PX4_READY_TIMEOUT_SECONDS}s: device=$PX4_DEVICE" >&2
    return 1
}

start_pcscd()
{
    if [ ! -x "$PCSC_BIN" ]; then
        echo "pcscd executable is missing: $PCSC_BIN" >&2
        return 1
    fi
    echo "starting pcscd in foreground: $PCSC_BIN" >&2
    "$PCSC_BIN" --foreground --disable-polkit &
    pcscd_pid=$!
}

start_mirakc()
{
    echo "starting mirakc: $MIRAKC_BIN" >&2
    "$MIRAKC_BIN" &
    mirakc_pid=$!
}

stop_child()
{
    pid=$1
    name=$2
    [ -n "$pid" ] || return 0

    if pid_is_alive "$pid"; then
        echo "stopping $name (pid=$pid)" >&2
        kill -TERM "$pid" 2>/dev/null || :
    fi
    stop_deadline=$(($(date +%s) + PX4_CHILD_STOP_TIMEOUT_SECONDS))
    while pid_is_alive "$pid"; do
        now=$(date +%s)
        [ "$now" -ge "$stop_deadline" ] && break
        sleep "$PX4_MONITOR_INTERVAL_SECONDS" || :
    done
    if pid_is_alive "$pid"; then
        echo "$name did not stop gracefully; sending SIGKILL (pid=$pid)" >&2
        kill -KILL "$pid" 2>/dev/null || :
    fi
    while pid_is_alive "$pid"; do
        sleep "$PX4_MONITOR_INTERVAL_SECONDS" || :
    done
    # Reap the child, in particular pcscd, before the next sibling is stopped.
    wait "$pid" 2>/dev/null || :
}

remove_effective_config()
{
    if [ "$APP_CFG" = "$USER_CFG" ]; then
        echo "effective config path must differ from user config path: $APP_CFG" >&2
        return 1
    fi
    if [ -L "$APP_CFG" ] || [ -f "$APP_CFG" ]; then
        if ! rm -f "$APP_CFG"; then
            echo "could not remove prior effective config: $APP_CFG" >&2
            return 1
        fi
    elif [ -e "$APP_CFG" ]; then
        echo "effective config path is not a regular file or symlink: $APP_CFG" >&2
        return 1
    fi
}

collect_siano_list()
{
    siano_list_file=$tmp_dir/siano-list.txt
    siano_list_stderr=$tmp_dir/siano-list.stderr
    if ! command -v "$SIANO_TS_BIN" >/dev/null 2>&1; then
        printf '%s\n' '0 devices' > "$siano_list_file"
        : > "$siano_list_stderr"
        echo "siano-ts is unavailable; detected Siano adapters: none" >&2
        return 0
    fi
    if ! "$SIANO_TS_BIN" --list >"$siano_list_file" 2>"$siano_list_stderr"; then
        if [ -s "$siano_list_stderr" ]; then
            cat "$siano_list_stderr" >&2
        fi
        echo "Siano adapter detection failed" >&2
        return 1
    fi
    if [ -s "$siano_list_stderr" ]; then
        cat "$siano_list_stderr" >&2
    fi
}

generate_effective_config()
{
    if [ ! -r "$EFFECTIVE_CONFIG_HELPER" ]; then
        echo "effective config helper is missing or unreadable: $EFFECTIVE_CONFIG_HELPER" >&2
        return 1
    fi
    if ! python3 "$EFFECTIVE_CONFIG_HELPER" \
        --input "$USER_CFG" \
        --output "$APP_CFG" \
        --siano-list "$tmp_dir/siano-list.txt" \
        --warmup-file "$tmp_dir/siano-warmup.txt" \
        --q3u4-enabled "$q3u4_enabled"; then
        return 1
    fi
}

warmup_siano_adapters()
{
    if [ ! -s "$tmp_dir/siano-warmup.txt" ]; then
        echo "Siano warmup: no retained adapters" >&2
        return 0
    fi
    echo "Siano warmup: retained adapters" >&2
    while IFS= read -r adapter; do
        [ -n "$adapter" ] || continue
        "$SIANO_TS_BIN" --channel 27 --device "$adapter" --firmware "$SIANO_FIRMWARE" \
            -t "$SIANO_WARMUP_TIMEOUT_SECONDS" -o /dev/null || true
    done < "$tmp_dir/siano-warmup.txt"
}

cleanup_children()
{
    status=$1
    trap - EXIT HUP INT TERM
    # This order is intentional: the IFD must disappear before px4d releases
    # the Q3U4 card transport.
    stop_child "$mirakc_pid" mirakc
    stop_child "$pcscd_pid" pcscd
    stop_child "$px4d_pid" px4d
    cleanup_tmp
    exit "$status"
}

on_signal()
{
    shutdown_requested=1
    if [ -n "$firmware_helper_pid" ]; then
        kill -TERM "$firmware_helper_pid" 2>/dev/null || :
    fi
}

trap 'cleanup_children "$?"' EXIT
trap on_signal HUP INT TERM

if ! remove_effective_config; then
    exit 1
fi
mkdir -p "$DATA_DIR" "$PX4_RUNTIME_DIR" "$(dirname "$APP_CFG")"
if ! chmod 0700 "$PX4_RUNTIME_DIR"; then
    echo "could not set PX4 runtime directory mode to 0700: $PX4_RUNTIME_DIR" >&2
    exit 1
fi

if [ ! -f "$USER_CFG" ]; then
    echo "config.yml がないのでテンプレートから作ります: ${USER_CFG}" >&2
    mkdir -p "$(dirname "$USER_CFG")"
    cp "$TEMPLATE" "$USER_CFG"
fi

if [ ! -r "$SIANO_FIRMWARE" ]; then
    echo "Siano firmware がありません: ${SIANO_FIRMWARE}" >&2
    exit 1
fi

if q3_base_serial=$(detect_q3u4); then
    if ensure_q3u4_firmware; then
        PX4_DEVICE=$q3_base_serial
        export PX4_DEVICE PX4_RUNTIME_DIR
        if ! write_reader_config; then
            echo "Q3U4 setup failed: reader config/IFD preparation is fatal" >&2
            exit 1
        fi
        echo "Q3U4 enabled: device=$PX4_DEVICE firmware=$Q3U4_FIRMWARE" >&2
        start_px4d
        if ! wait_px4_ready; then
            echo "px4d failed to start or become ready" >&2
            exit 1
        fi
        q3u4_enabled=1
    else
        if [ "$shutdown_requested" -ne 0 ]; then
            exit 0
        fi
        echo "Q3U4 disabled: $q3_firmware_error" >&2
        PX4_DEVICE=
        export PX4_DEVICE PX4_RUNTIME_DIR
        rm -f "$READER_CONFIG"
    fi
else
    PX4_DEVICE=
    export PX4_DEVICE PX4_RUNTIME_DIR
    rm -f "$READER_CONFIG"
fi

echo "設定: ${USER_CFG}" >&2
echo "Siano firmware: ${SIANO_FIRMWARE}" >&2
if ! collect_siano_list; then
    exit 1
fi
if ! generate_effective_config; then
    echo "mirakc effective config generation failed" >&2
    exit 1
fi
if ! warmup_siano_adapters; then
    exit 1
fi

if ! start_pcscd; then
    echo "pcscd failed to start" >&2
    exit 1
fi
if ! start_mirakc; then
    echo "mirakc failed to start" >&2
    exit 1
fi

while :; do
    if [ "$shutdown_requested" -ne 0 ]; then
        exit 0
    fi
    if [ -n "$mirakc_pid" ] && ! pid_is_alive "$mirakc_pid"; then
        echo "mirakc exited unexpectedly" >&2
        exit 1
    fi
    if [ -n "$pcscd_pid" ] && ! pid_is_alive "$pcscd_pid"; then
        echo "pcscd exited unexpectedly" >&2
        exit 1
    fi
    if [ -n "$px4d_pid" ] && ! pid_is_alive "$px4d_pid"; then
        echo "px4d exited unexpectedly" >&2
        exit 1
    fi
    sleep "$PX4_MONITOR_INTERVAL_SECONDS" || :
done
