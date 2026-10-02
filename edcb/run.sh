#!/bin/sh
# xtne6f 版 EDCB を Home Assistant のアドオンとして起動する。
#
# 初回の EpgTimerSrv.ini はチューナー本数 0。PX-S1UD の本数は Count に書く。
# mirakc_url が空なら BonDriver_LinuxMirakc の宛先は書かない。
set -eu

SEED=/usr/share/edcb/seed
CFG=/config
LIB=/usr/local/lib/edcb
OPTIONS=/data/options.json
PX4_DAEMON_PIDS=
pcscd_pid=
scan_pid=
srv_pid=

cleanup_children() {
    [ -z "$scan_pid" ] || kill -TERM "$scan_pid" 2>/dev/null || true
    [ -z "$srv_pid" ] || kill -TERM "$srv_pid" 2>/dev/null || true
    [ -z "$pcscd_pid" ] || kill -TERM "$pcscd_pid" 2>/dev/null || true
    for pid in $PX4_DAEMON_PIDS; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    [ -z "$scan_pid" ] || wait "$scan_pid" 2>/dev/null || true
    [ -z "$srv_pid" ] || wait "$srv_pid" 2>/dev/null || true
    [ -z "$pcscd_pid" ] || wait "$pcscd_pid" 2>/dev/null || true
    for pid in $PX4_DAEMON_PIDS; do
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup_children EXIT
trap 'exit 0' HUP TERM INT

MIRAKC_URL=
DECODE=1
if [ -f "$OPTIONS" ]; then
    MIRAKC_URL=$(jq -r '.mirakc_url // empty' "$OPTIONS")
    if [ "$(jq -r '.decode' "$OPTIONS")" = "false" ]; then
        DECODE=0
    fi
fi

# B-CAS カードリーダーの有無。PX-S1UD だけで使うときの decode 判定に使う
# (px4 系には内蔵カードスロットがあるので、そちらが検出できれば USB CCID は不要)。
has_ccid=0
for iface in /sys/bus/usb/devices/*/*/bInterfaceClass; do
    if [ -r "$iface" ] && [ "$(cat "$iface")" = "0b" ]; then
        has_ccid=1
        break
    fi
done

host_ip=
if [ -n "$MIRAKC_URL" ]; then
    case "$MIRAKC_URL" in
        http://*) ;;
        *)
            echo "mirakc_url は http://ホスト:ポート です: ${MIRAKC_URL}" >&2
            exit 1
            ;;
    esac
    rest=${MIRAKC_URL#http://}
    rest=${rest%%/*}
    host=${rest%%:*}
    if [ "$host" = "$rest" ]; then
        port=40772
    else
        port=${rest#*:}
    fi
    case "$host" in
        ""|*[!A-Za-z0-9._-]*)
            echo "mirakc のホスト名が読めません: ${MIRAKC_URL}" >&2
            exit 1
            ;;
    esac
    case "$port" in
        ""|*[!0-9]*)
            echo "mirakc のポートが読めません: ${MIRAKC_URL}" >&2
            exit 1
            ;;
    esac
    # BonDriver_LinuxMirakc は inet_addr だけを使う。ホスト名のままだと接続できない。
    case "$host" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            host_ip=$host
            ;;
        *)
            host_ip=$(getent ahostsv4 "$host" | awk 'NR==1 { print $1; exit }') || host_ip=
            ;;
    esac
    case "$host_ip" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
        *)
            echo "mirakc の IPv4 が取れないので BonDriver_LinuxMirakc の宛先は書きません: ${host}" >&2
            host_ip=
            ;;
    esac
fi

mkdir -p "$CFG" /media/DTV/EDCB "$LIB" /run/edcb-s1ud /run/edcb-px4 /run/px4-userland
# px4d はランタイムディレクトリが 0700 であることを要求する (validate_directory)。
chmod 0700 /run/px4-userland
if [ ! -f "$CFG/EpgTimerSrv.ini" ]; then
    echo "設定が無いので初期ファイルを置きます: ${CFG}"
    cp -a "$SEED"/. "$CFG"/
    cat > "$CFG/EpgTimerSrv.ini" << 'EOF'
[SET]
EnableHttpSrv=1
HttpPort=5510
SaveDebugLog=1
HttpAccessControlList=+127.0.0.0/8,+::1,+10.0.0.0/8,+172.16.0.0/12,+192.168.0.0/16,+100.64.0.0/10
EnableTCPSrv=1
TCPPort=4510
TCPIPv6=0
TCPAccessControlList=+127.0.0.0/8,+10.0.0.0/8,+172.16.0.0/12,+192.168.0.0/16,+100.64.0.0/10
CompatFlags=4095

; Count はつながっているチューナーの本数。0 のあいだはその BonDriver を開かない。
; Priority は BonDriver ごとに違う値にする。
[BonDriver_S1UD.so]
Count=0
GetEpg=1
EPGCount=1
Priority=0

; px4-userland の機材。1つの hybrid BonDriver が GR/BS/CS を持ち、
; 本数 (物理受信機数) は起動時に自動で書き直す。
[BonDriver_Px4.so]
Count=0
GetEpg=1
EPGCount=1
Priority=4

; 旧 _T / _S 分割時代の残骸。Count は起動時に 0 へ書き直す。
[BonDriver_Px4_T.so]
Count=0
GetEpg=1
EPGCount=1
Priority=4

[BonDriver_Px4_S.so]
Count=0
GetEpg=1
EPGCount=1
Priority=5

[BonDriver_LinuxMirakc_T.so]
Count=0
GetEpg=0
EPGCount=0
Priority=3

[BonDriver_LinuxMirakc_S.so]
Count=0
GetEpg=0
EPGCount=0
Priority=1

[BonDriver_LinuxMirakc.so]
Count=0
GetEpg=0
EPGCount=0
Priority=2

[TVTEST]
Num=1
0=BonDriver_S1UD.so
EOF
    if [ ! -f "$CFG/Common.ini" ]; then
        cat > "$CFG/Common.ini" << 'EOF'
[SET]
RecFolderNum=1
RecFolderPath0=/media/DTV/EDCB
EOF
    fi
fi

# BS/CS の標準チャンネル一覧を同梱シードから足す。地上波はスキャンで足す。
if [ -f "$SEED/Setting/ChSet5.bs.txt" ]; then
    mkdir -p "$CFG/Setting"
    if [ ! -f "$CFG/Setting/ChSet5.txt" ] || ! awk -F'\t' '$3 == 4 || $3 == 6 || $3 == 7 { found = 1 } END { exit found ? 0 : 1 }' "$CFG/Setting/ChSet5.txt"; then
        cat "$SEED/Setting/ChSet5.bs.txt" >> "$CFG/Setting/ChSet5.txt"
        echo "BS/CS の標準チャンネル一覧を ChSet5.txt に足しました。"
    fi
fi

rm -rf /var/local/edcb
ln -s "$CFG" /var/local/edcb

# KonomiTV の SrvPipe は IP 1（0.0.0.1）・ポート 0 を FIFO の宛先にする。
if [ -f "$CFG/EpgDataCap_Bon.ini" ] && grep -q '^\[SET_TCP\]' "$CFG/EpgDataCap_Bon.ini"; then
    :
else
    cat >> "$CFG/EpgDataCap_Bon.ini" << 'EOF'
[SET_TCP]
Count=1
IP0=1
Port0=0
EOF
fi

write_bon_ini() {
    cat > "$1" << EOF
[GLOBAL]
SERVER_HOST="${host_ip}"
SERVER_PORT=${port}
SERVER_TYPE="http"
DECODE_B25=${DECODE}
PRIORITY=10
SERVICE_SPLIT=0
EOF
}
if [ -n "$host_ip" ]; then
    write_bon_ini "$LIB/BonDriver_LinuxMirakc.so.ini"
    write_bon_ini "$LIB/BonDriver_LinuxMirakc_T.so.ini"
    write_bon_ini "$LIB/BonDriver_LinuxMirakc_S.so.ini"
fi

# EpgTimerSrv.ini の [section] の Count を書き換える。無ければ末尾に足す。
set_bondriver_count() {
    section=$1
    count=$2
    priority=$3
    ini="$CFG/EpgTimerSrv.ini"
    awk -v section="$section" -v count="$count" -v priority="$priority" '
        index($0, "[" section "]") == 1 { in_sec = 1; found = 1; print; next }
        in_sec && /^\[/ { in_sec = 0 }
        in_sec && /^Count=/ { print "Count=" count; next }
        { print }
        END {
            if (!found) {
                printf "\n[%s]\nCount=%d\nGetEpg=1\nEPGCount=1\nPriority=%d\n", section, count, priority
            }
        }
    ' "$ini" > "$ini.tmp" && mv "$ini.tmp" "$ini"
}

# KonomiTV の NWTV (ライブ視聴) は [TVTEST] に列挙された BonDriver しか
# 使えない。px4 の受信機が1基でもあれば hybrid な Px4 BonDriver を追加する。
set_tvtest() {
    ini="$CFG/EpgTimerSrv.ini"
    if [ "$PX4_SLOT_COUNT" -gt 0 ]; then
        bon_list="BonDriver_S1UD.so BonDriver_Px4.so"
    else
        bon_list="BonDriver_S1UD.so"
    fi
    awk -v bon_list="$bon_list" '
        BEGIN { n = split(bon_list, b, " ") }
        index($0, "[TVTEST]") == 1 { in_sec = 1; found = 1; print; print "Num=" n; for (i = 1; i <= n; i++) print (i - 1) "=" b[i]; next }
        in_sec && /^\[/ { in_sec = 0 }
        in_sec && (/^Num=/ || /^[0-9]+=/) { next }
        { print }
        END {
            if (!found) {
                print "\n[TVTEST]"
                print "Num=" n
                for (i = 1; i <= n; i++) print (i - 1) "=" b[i]
            }
        }
    ' "$ini" > "$ini.tmp" && mv "$ini.tmp" "$ini"
}

# px4d --list-json を列挙の唯一の根拠にする。筐体ごとの instance と
# `--usb-path`、受信機ごとの system を検証して plan に落とし、EDCB の
# hybrid BonDriver へ EDCB_PX4_SLOTS で渡す。M1UR/S1UR は別 model かつ各1
# candidate の duplicate として返るため、USB path を指定して個別起動できる。
# 同一機種・同一 serial の複数候補、incomplete/invalid な筐体、未割当の USB は拒否する。
PX4_FIRMWARE=/lib/firmware/it930x-firmware.bin
PX4_RUNTIME_DIR=/run/px4-userland
PX4_JSON=/run/edcb-px4/list.json
PX4_PLAN=/run/edcb-px4/plan
PX4_SLOTS=
PX4_SLOT_COUNT=0
PX4_PLAN_AVAILABLE=0
: > "$PX4_PLAN"

collect_px4_plan()
{
    if [ ! -x /usr/local/bin/px4d ]; then
        echo "PX4: px4d が無いため使いません" >&2
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "PX4: jq が無いため列挙を検証できません" >&2
        return 1
    fi
    if ! /usr/local/bin/px4d --list-json > "$PX4_JSON" 2> /run/edcb-px4/list.err; then
        if [ -s /run/edcb-px4/list.err ]; then
            cat /run/edcb-px4/list.err >&2
        fi
        echo "PX4: px4d --list-json に失敗しました" >&2
        return 1
    fi
    if [ -s /run/edcb-px4/list.err ]; then
        cat /run/edcb-px4/list.err >&2
    fi

    if ! jq -e '
        def bridge_count:
            if (.model == "PX-Q3U4" or .model == "PX-Q3PE4" or .model == "PX-Q3PE5")
            then 2 else 1 end;
        def receiver_count:
            if (.model == "PX-Q3U4" or .model == "PX-Q3PE4" or .model == "PX-Q3PE5") then 8
            elif (.model == "PX-W3U4" or .model == "PX-W3PE4" or .model == "PX-W3PE5") then 4
            elif (.model == "PX-MLT5PE" or .model == "DTV02A-5TS-P" or .model == "PX-MLT8PE5") then 5
            elif .model == "PX-MLT8PE3" then 3
            elif .model == "DTV02A-4TS-P" then 4
            else 1 end;
        def selected_devices:
            if .status == "ready" then .devices
            elif .status == "duplicate" then .candidates
            else [] end;
        def usbpath:
            if (.port | type) == "string" and (.port | length) > 0 then .port
            else "\(.bus):\(.address)" end;
        (.enclosures | type == "array") and
        (.ungrouped_usb_devices | type == "array") and
        (.ungrouped_usb_devices | length == 0) and
        (all(.enclosures[];
            (.serial as $serial |
            (.model | type == "string") and
            (.serial | type == "string") and
            (.status != "duplicate" or
             ([.enclosures[] | select(.serial == $serial)] as $groups |
              ($groups | length) == 2 and
              ($groups | map(.model) | unique | length) == 2 and
              all($groups[]; .status == "duplicate"))) and
            (.receivers | type == "array") and
            ((.receivers | length) == receiver_count) and
            (([.receivers[].receiver] | sort) == [range(0; receiver_count)]) and
            (all(.receivers[]; (.receiver | type == "number") and
                 (.system == "ISDB-T" or .system == "ISDB-S" or .system == "ISDB-T/S"))) and
            (.devices | type == "array") and
            (.candidates | type == "array") and
            ((.status == "ready" and (.candidates | length == 0)) or
             (.status == "duplicate" and (.devices | length == 0))) and
            ((selected_devices | length) == bridge_count) and
            (([selected_devices[] | usbpath] | unique | length) == bridge_count) and
            (all(selected_devices[];
                ((.port | type == "string" and length > 0) or
                 ((.bus | type == "number") and (.address | type == "number"))))))))
    ' "$PX4_JSON" >/dev/null 2>&1; then
        echo "PX4: 未確定または不完全な筐体、もしくは未割当の USB があるため使いません" >&2
        return 1
    fi

    if ! jq -r '
        def selected_devices:
            if .status == "ready" then .devices else .candidates end;
        def usbpath:
            if (.port | type) == "string" and (.port | length) > 0 then .port
            else "\(.bus):\(.address)" end;
        .enclosures[] |
        [ .model, .serial, (selected_devices | length),
          ([selected_devices[] | .device] | sort | join(",")),
          ([selected_devices | sort_by(.device)[] | usbpath] | join(",")),
          ([.receivers[] | (.receiver | tostring) + ":" + .system] | join(",")) ] |
        @tsv
    ' "$PX4_JSON" > /run/edcb-px4/enclosures.tsv; then
        echo "PX4: 列挙の整形に失敗しました" >&2
        return 1
    fi

    : > "$PX4_PLAN"
    PX4_SLOTS=
    PX4_SLOT_COUNT=0
    seen=
    seen_usb_paths=

    while IFS="$(printf '\t')" read -r model serial devcount devlist portlist recvlist; do
        [ -n "$model" ] || continue
        case $model in
            PX-Q3U4|PX-Q3PE4|PX-Q3PE5) bridges=2 ;;
            PX-W3U4|PX-W3PE4|PX-W3PE5|PX-MLT5PE|DTV02A-5TS-P|PX-MLT8PE3|PX-MLT8PE5|DTV02A-4TS-P|PX-M1UR|PX-S1UR|DTV03A-1TU|DTV02-1T1S-U|DTV02A-1T1S-U) bridges=1 ;;
            *) echo "PX4: 未対応の機種です: $model" >&2; return 1 ;;
        esac
        case $seen in
            *"|$model/$serial|"*)
                echo "PX4: 同じ機種と serial の筐体が複数あり選択できません: $model $serial" >&2
                return 1
                ;;
        esac
        seen="$seen|$model/$serial|"
        if [ "$bridges" = 2 ]; then
            case $serial in
                [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
                *) echo "PX4: serial が14桁ではありません: $serial" >&2; return 1 ;;
            esac
            expected_devs=1,2
        else
            case $serial in
                [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
                *) echo "PX4: serial が15桁ではありません: $serial" >&2; return 1 ;;
            esac
            expected_devs=1
        fi
        if [ "$devcount" != "$bridges" ] || [ "$devlist" != "$expected_devs" ]; then
            echo "PX4: USB デバイス構成が不正です: $model $serial (devices=$devlist)" >&2
            return 1
        fi

        old_ifs=$IFS
        IFS=,
        # shellcheck disable=SC2086
        set -- $portlist
        IFS=$old_ifs
        if [ "$#" -ne "$bridges" ]; then
            echo "PX4: USB パス数が不正です: $model $serial ($portlist)" >&2
            return 1
        fi
        p1=$1
        p2=${2:-}
        if [ -z "$p1" ]; then
            echo "PX4: USB パスが空です: $model $serial" >&2
            return 1
        fi
        if [ "$bridges" = 2 ] && [ -z "$p2" ]; then
            echo "PX4: 2つ目の USB パスが空です: $model $serial" >&2
            return 1
        fi
        case $seen_usb_paths in
            *"|$p1|"*)
                echo "PX4: 同じ USB パスが複数の筐体候補に割り当てられています: $p1" >&2
                return 1
                ;;
        esac
        seen_usb_paths="$seen_usb_paths|$p1|"
        if [ -n "$p2" ]; then
            case $seen_usb_paths in
                *"|$p2|"*)
                    echo "PX4: 同じ USB パスが複数の筐体候補に割り当てられています: $p2" >&2
                    return 1
                    ;;
            esac
            seen_usb_paths="$seen_usb_paths|$p2|"
        fi

        key=$(printf '%s' "$model" | tr 'A-Z-' 'a-z_')
        instance="px4-$key-$serial"
        printf '%s %s %s %s %s %s %s\n' "$model" "$key" "$instance" "$serial" "$bridges" "$p1" "$p2" >> "$PX4_PLAN"

        old_ifs=$IFS
        IFS=,
        for record in $recvlist; do
            receiver=${record%%:*}
            system=${record#*:}
            case $receiver in
                ''|*[!0-9]*) echo "PX4: 受信機番号が不正です: $record" >&2; IFS=$old_ifs; return 1 ;;
            esac
            case $system in
                ISDB-T) systems=T ;;
                ISDB-S) systems=S ;;
                ISDB-T/S) systems=TS ;;
                *) echo "PX4: 不明な system です: $record" >&2; IFS=$old_ifs; return 1 ;;
            esac
            PX4_SLOTS="${PX4_SLOTS}${PX4_SLOTS:+;}$key:$instance:$serial:$receiver:$systems"
            PX4_SLOT_COUNT=$((PX4_SLOT_COUNT + 1))
        done
        IFS=$old_ifs
    done < /run/edcb-px4/enclosures.tsv

    if [ "$PX4_SLOT_COUNT" -gt 0 ]; then
        PX4_PLAN_AVAILABLE=1
    fi
    return 0
}

# 筐体ごとに1つの px4d を instance 付きで起こし、px4ctl で ready を確認する。
start_px4d_enclosures()
{
    while read -r model key instance serial bridges p1 p2; do
        [ -n "$instance" ] || continue
        echo "PX4: px4d を起動します instance=$instance device=$serial usb-path=$p1${p2:+ $p2}" >&2
        if [ "$bridges" = 2 ]; then
            /usr/local/bin/px4d \
                --device "$serial" \
                --usb-path "$p1" \
                --usb-path "$p2" \
                --instance "$instance" \
                --firmware "$PX4_FIRMWARE" \
                --runtime-dir "$PX4_RUNTIME_DIR" &
        else
            /usr/local/bin/px4d \
                --device "$serial" \
                --usb-path "$p1" \
                --instance "$instance" \
                --firmware "$PX4_FIRMWARE" \
                --runtime-dir "$PX4_RUNTIME_DIR" &
        fi
        px4d_pid=$!
        PX4_DAEMON_PIDS="$PX4_DAEMON_PIDS $px4d_pid"
        if ! wait_px4_instance_ready "$instance" "$bridges" "$px4d_pid"; then
            return 1
        fi
    done < "$PX4_PLAN"
    return 0
}

wait_px4_instance_ready()
{
    instance=$1
    bridges=$2
    pid=$3
    if [ "$bridges" = 2 ]; then
        px4_usb_mask=0x03
    else
        px4_usb_mask=0x01
    fi
    wait_deadline=$(( $(date +%s) + 10 ))
    while :; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "PX4: px4d が ready 前に終了しました instance=$instance" >&2
            return 1
        fi
        if output=$(/usr/local/bin/px4ctl --instance "$instance" --runtime-dir "$PX4_RUNTIME_DIR" list 2>/dev/null); then
            if printf '%s\n' "$output" | awk -v mask="$px4_usb_mask" '
                /(^|[[:space:]])ready=yes([[:space:]]|$)/ &&
                $0 ~ ("(^|[[:space:]])usb-present-mask=" mask "([[:space:]]|$)") { found = 1 }
                END { exit found ? 0 : 1 }
            '; then
                echo "PX4: px4d ready instance=$instance" >&2
                return 0
            fi
        fi
        now=$(date +%s)
        [ "$now" -ge "$wait_deadline" ] && break
        sleep 1
    done
    echo "PX4: px4d が ready になりません instance=$instance" >&2
    return 1
}

stop_px4d_enclosures()
{
    for pid in $PX4_DAEMON_PIDS; do
        kill -TERM "$pid" 2>/dev/null || :
    done
    for pid in $PX4_DAEMON_PIDS; do
        wait "$pid" 2>/dev/null || :
    done
    PX4_DAEMON_PIDS=
}

# px4 系の内蔵カードスロットを pcscd 経由で使うための reader 設定。
# recisdb は pcscd 経由で B-CAS カードを開く。USB CCID (SCR3310 等) は
# pcscd が起動時に自動検出するので設定不要。serial が同じ M1UR と S1UR も
# instance で区別する。
write_reader_configs()
{
    mkdir -p /etc/reader.conf.d
    rm -f /etc/reader.conf.d/px4-userland*.conf
    while read -r model key instance serial bridges p1 p2; do
        [ -n "$instance" ] || continue
        cat > "/etc/reader.conf.d/px4-userland-$instance.conf" <<EOF
FRIENDLYNAME "PLEX $model Internal Card Reader"
DEVICENAME   px4-userland:runtime=${PX4_RUNTIME_DIR}:instance=${instance}:access=user
LIBPATH      /usr/lib/px4-userland/libpx4-userland-ifd.so
CHANNELID    0
EOF
    done < "$PX4_PLAN"
}

if ! collect_px4_plan; then
    echo "PX4: 安全に全筐体を特定できないため EDCB を起動しません" >&2
    exit 1
fi

# siano-ts --list はデバイスを開かずに対応 RIO チューナーを列挙する。
# libusb の順番ではなく USB port path を BonDriver に渡し、抜き差しで
# 列挙順が変わっても別の筐体を選ばない。Count に加える前に各機器を開き、
# カーネルドライバー等で使えない状態では起動を止める。
SIANO_LIST=/run/edcb-s1ud/list.txt
SIANO_DEVICES_FILE=/run/edcb-s1ud/devices.txt
SIANO_DEVICES=
SIANO_SLOT_COUNT=0
collect_siano_devices()
{
    if ! /usr/local/bin/siano-ts --list > "$SIANO_LIST" 2> /run/edcb-s1ud/list.err; then
        if [ -s /run/edcb-s1ud/list.err ]; then
            cat /run/edcb-s1ud/list.err >&2
        fi
        echo "Siano: siano-ts --list に失敗しました" >&2
        return 1
    fi
    if [ -s /run/edcb-s1ud/list.err ]; then
        cat /run/edcb-s1ud/list.err >&2
    fi
    if ! awk '
        /^model=/ {
            model = port = bus = address = status = receivers = ""
            for (i = 1; i <= NF; i++) {
                separator = index($i, "=")
                if (!separator) continue
                key = substr($i, 1, separator - 1)
                value = substr($i, separator + 1)
                if (key == "model") model = value
                else if (key == "port") port = value
                else if (key == "bus") bus = value
                else if (key == "address") address = value
                else if (key == "status") status = value
                else if (key == "receivers") receivers = value
            }
            if (status != "ready") next
            if (model != "PX-S1UD" && model != "Siano-Rio-0600" &&
                model != "Siano-Rio-0302") { invalid = 1; next }
            if (receivers != "1") { invalid = 1; next }
            if (port != "" && port != "-") selector = port
            else { invalid = 1; next }
            if (selector !~ /^[0-9]+([-.:][0-9]+)*$/ || seen[selector]++) {
                invalid = 1
                next
            }
            print selector
        }
        END { if (invalid) exit 1 }
    ' "$SIANO_LIST" > "$SIANO_DEVICES_FILE"; then
        echo "Siano: 安全に選択できない列挙結果があるため EDCB を起動しません" >&2
        return 1
    fi
    SIANO_SLOT_COUNT=$(awk 'END { print NR + 0 }' "$SIANO_DEVICES_FILE")
    SIANO_DEVICES=$(paste -sd, "$SIANO_DEVICES_FILE")
    if [ "$SIANO_SLOT_COUNT" -gt 0 ]; then
        if [ ! -r /lib/firmware/isdbt_rio.inp ]; then
            echo "Siano: ファームウェアがありません: /lib/firmware/isdbt_rio.inp" >&2
            return 1
        fi
        printf 'quit\n' > /run/edcb-s1ud/probe.input
        while IFS= read -r device; do
            if ! /usr/local/bin/siano-ts --control --device "$device" \
                --firmware /lib/firmware/isdbt_rio.inp \
                < /run/edcb-s1ud/probe.input > /dev/null 2> /run/edcb-s1ud/probe.err; then
                cat /run/edcb-s1ud/probe.err >&2
                echo "Siano: USB チューナーを初期化できません: $device" >&2
                return 1
            fi
        done < "$SIANO_DEVICES_FILE"
    fi
    echo "Siano enabled: adapters=$SIANO_SLOT_COUNT" >&2
    return 0
}

if ! collect_siano_devices; then
    exit 1
fi

if [ "$PX4_PLAN_AVAILABLE" -eq 1 ]; then
    if [ ! -r "$PX4_FIRMWARE" ]; then
        echo "PX4: ファームウェアがありません: $PX4_FIRMWARE" >&2
        exit 1
    fi
    write_reader_configs
    if ! start_px4d_enclosures; then
        echo "PX4: すべての筐体を起動できなかったため EDCB を起動しません" >&2
        stop_px4d_enclosures
        rm -f /etc/reader.conf.d/px4-userland*.conf
        exit 1
    fi
    echo "PX4 enabled: enclosures=$(awk '$1 == "enclosure" { n++ } END { print n + 0 }' "$PX4_PLAN") slots=$PX4_SLOT_COUNT" >&2
else
    rm -f /etc/reader.conf.d/px4-userland*.conf
fi

# USB CCID リーダーも px4 内蔵スロットも無い場合、recisdb decode は即終了して
# TS が流れなくなるため decode を無効化する。
if [ "$has_ccid" -eq 0 ] && [ "$PX4_SLOT_COUNT" -eq 0 ] && [ "$DECODE" -eq 1 ]; then
    echo "カードリーダー (USB CCID / px4 内蔵) が見つからないため decode を無効化します (recisdb はカード不在で即終了するため)。"
    DECODE=0
fi

if [ -x /usr/sbin/pcscd ]; then
    /usr/sbin/pcscd --foreground >> "$CFG/pcscd.log" 2>&1 &
    pcscd_pid=$!
fi

# Hybrid BonDriver は1つの名前で GR/BS/CS を扱う。
if [ "$PX4_SLOT_COUNT" -gt 0 ] && [ -f "$SEED/Setting/ChSet4.bs.txt" ]; then
    mkdir -p "$CFG/Setting"
    if [ ! -f "$CFG/Setting/BonDriver_Px4.ChSet4.txt" ]; then
        cp "$SEED/Setting/ChSet4.bs.txt" "$CFG/Setting/BonDriver_Px4.ChSet4.txt"
        echo "BS/CS のチャンネル対応を BonDriver_Px4 用に置きました。"
    fi
fi

# 起動ごとに実機の物理受信機数へ合わせる。古い分割ドライバー設定が
# 残っていても起動対象にならないよう Count=0 にする。
set_bondriver_count "BonDriver_Px4.so" "$PX4_SLOT_COUNT" 4
set_bondriver_count "BonDriver_Px4_T.so" 0 4
set_bondriver_count "BonDriver_Px4_S.so" 0 5
set_bondriver_count "BonDriver_S1UD.so" "$SIANO_SLOT_COUNT" 0

set_tvtest
export PX4_RUNTIME_DIR
export EDCB_PX4_SLOTS="$PX4_SLOTS"
export EDCB_S1UD_DEVICES="$SIANO_DEVICES"
# BonDriver_S1UD / _Px4 が recisdb を通すかどうか。decode=false なら素通し。
export EDCB_DECODE=${DECODE}

# チャンネル一覧が無いと Web UI の EPG取得は「開始できませんでした」になる。
# 地上波用 BonDriver で一度だけスキャンし、結果は Setting/ に残る。
# EpgTimerSrv は起動時にしか ChSet5.txt を読み込まないため、初回はスキャン完了後に
# サーバーを再起動してチャンネル一覧を読み込ませる。
scan_pid=
if [ ! -f "$CFG/chscan.done" ]; then
    echo "チャンネルスキャンを開始します。記録は ${CFG}/chscan.log です。"
    /chscan.sh >> "$CFG/chscan.log" 2>&1 < /dev/null &
    scan_pid=$!
fi

echo "EDCB を起動します。mirakc_url=${MIRAKC_URL:-空} decode=${DECODE}。チューナー本数は EpgTimerSrv.ini の Count です。"
/usr/local/bin/EpgTimerSrv &
srv_pid=$!

terminate() {
    kill -TERM "$srv_pid" 2>/dev/null || true
}
trap terminate TERM INT

if [ -n "$scan_pid" ]; then
    wait "$scan_pid" || true
    scan_pid=
    if [ -f "$CFG/chscan.done" ]; then
        echo "チャンネルスキャンが完了したので、EDCB を再起動してチャンネル一覧を読み込みます。"
        terminate
        wait "$srv_pid" 2>/dev/null || true
        /usr/local/bin/EpgTimerSrv &
        srv_pid=$!
    else
        echo "チャンネルスキャンが失敗しました。EDCB はチャンネル一覧なしで起動したままです。" >&2
    fi
fi

wait "$srv_pid"
