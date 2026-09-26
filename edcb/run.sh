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

MIRAKC_URL=
DECODE=1
if [ -f "$OPTIONS" ]; then
    MIRAKC_URL=$(jq -r '.mirakc_url // empty' "$OPTIONS")
    if [ "$(jq -r '.decode' "$OPTIONS")" = "false" ]; then
        DECODE=0
    fi
fi

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

if [ -x /usr/sbin/pcscd ]; then
    /usr/sbin/pcscd --foreground >> "$CFG/pcscd.log" 2>&1 &
fi

mkdir -p "$CFG" /media/EDCB "$LIB" /run/edcb-s1ud /run/edcb-px4 /run/px4-userland
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

; px4-userland の機材 (PX-Q3U4 / PX-MLT5PE 系)。本数は起動時に自動で書き直す。
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
RecFolderPath0=/media/EDCB
EOF
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

# PX-Q3U4 / PX-MLT5PE 系 (px4-userland) が刺さっていれば px4d を起こし、
# BonDriver_Px4_T/S の本数を書き直す。受信機の取り合いは BonDriver 側の
# flock で解決するので、Count は受信機の本数でよい。
PX4_DEVICE=
PX4_FIRMWARE=/lib/firmware/it930x-firmware.bin
PX4_RUNTIME_DIR=/run/px4-userland
if [ -x /usr/local/bin/px4-detect-q3u4 ] && [ -x /usr/local/bin/px4d ] && [ -r "$PX4_FIRMWARE" ]; then
    if PX4_DEVICE=$(/usr/local/bin/px4-detect-q3u4 2>/dev/null); then
        case "$PX4_DEVICE" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
                T_COUNT=4; S_COUNT=4 ;;  # Q3U4: 地上波 4 / BS・CS 4
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
                T_COUNT=5; S_COUNT=5 ;;  # MLT5 系: 5 受信機が地上波/衛星を兼ねる
            *)
                echo "px4 の検出結果が読めません: ${PX4_DEVICE}" >&2
                PX4_DEVICE=
                ;;
        esac
        if [ -n "$PX4_DEVICE" ]; then
            echo "px4 を検出しました: ${PX4_DEVICE} (T=${T_COUNT}, S=${S_COUNT})。px4d を起動します。"
            /usr/local/bin/px4d --device "$PX4_DEVICE" --firmware "$PX4_FIRMWARE" --runtime-dir "$PX4_RUNTIME_DIR" &
            set_bondriver_count "BonDriver_Px4_T.so" "$T_COUNT" 4
            set_bondriver_count "BonDriver_Px4_S.so" "$S_COUNT" 5
        fi
    fi
fi
export PX4_DEVICE PX4_RUNTIME_DIR
# BonDriver_S1UD / _Px4 が recisdb を通すかどうか。decode=false なら素通し。
export EDCB_DECODE=${DECODE}

# チャンネル一覧が無いと Web UI の EPG取得は「開始できませんでした」になる。
# 地上波用 BonDriver で一度だけスキャンし、結果は Setting/ に残る。
if [ ! -f "$CFG/chscan.done" ]; then
    echo "チャンネルスキャンを開始します。記録は ${CFG}/chscan.log です。"
    setsid /chscan.sh >> "$CFG/chscan.log" 2>&1 < /dev/null &
fi

echo "EDCB を起動します。mirakc_url=${MIRAKC_URL:-空} decode=${DECODE}。チューナー本数は EpgTimerSrv.ini の Count です。"
exec /usr/local/bin/EpgTimerSrv
