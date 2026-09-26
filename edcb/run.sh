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
# 使えない。px4 を検出したら Px4 BonDriver を追加する。
set_tvtest() {
    ini="$CFG/EpgTimerSrv.ini"
    if [ -n "$PX4_DEVICE" ]; then
        bon_list="BonDriver_S1UD.so BonDriver_Px4_T.so BonDriver_Px4_S.so"
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

# px4-userland 対応機種が刺さっていれば px4d を起こし、
# BonDriver_Px4_T/S の本数を書き直す。受信機の取り合いは BonDriver 側の
# flock で解決するので、Count は受信機の本数でよい。
PX4_DEVICE=
PX4_MODEL=
PX4_FIRMWARE=/lib/firmware/it930x-firmware.bin
PX4_RUNTIME_DIR=/run/px4-userland
if [ -x /usr/local/bin/px4-detect ] && [ -x /usr/local/bin/px4d ] && [ -r "$PX4_FIRMWARE" ]; then
    if detection=$(/usr/local/bin/px4-detect 2>/dev/null); then
        PX4_MODEL=${detection%% *}
        PX4_DEVICE=${detection#* }
        case "$PX4_MODEL" in
            px_q3u4|px_q3pe4|px_q3pe5) T_COUNT=4; S_COUNT=4 ;;
            px_w3u4|px_w3pe4|px_w3pe5) T_COUNT=2; S_COUNT=2 ;;
            px_mlt5pe|dtv02a_5ts_p|px_mlt8pe5) T_COUNT=5; S_COUNT=5 ;;
            px_mlt8pe3) T_COUNT=3; S_COUNT=3 ;;
            dtv02a_4ts_p) T_COUNT=4; S_COUNT=4 ;;
            px_m1ur|dtv02_1t1s_u|dtv02a_1t1s_u) T_COUNT=1; S_COUNT=1 ;;
            px_s1ur|dtv03a_1tu) T_COUNT=1; S_COUNT=0 ;;
            *)
                echo "px4 の検出結果が読めません: ${detection}" >&2
                PX4_DEVICE=
                PX4_MODEL=
                ;;
        esac
        if [ -n "$PX4_DEVICE" ]; then
            echo "px4 を検出しました: ${PX4_MODEL} ${PX4_DEVICE} (T=${T_COUNT}, S=${S_COUNT})。px4d を起動します。"
            /usr/local/bin/px4d --device "$PX4_DEVICE" --firmware "$PX4_FIRMWARE" --runtime-dir "$PX4_RUNTIME_DIR" &
            set_bondriver_count "BonDriver_Px4_T.so" "$T_COUNT" 4
            set_bondriver_count "BonDriver_Px4_S.so" "$S_COUNT" 5
        fi
    fi
fi
# px4 系の内蔵カードスロットを pcscd 経由で使うための reader 設定。
# recisdb は pcscd 経由で B-CAS カードを開く。USB CCID (SCR3310 等) は
# pcscd が起動時に自動検出するので設定不要。
if [ -n "$PX4_DEVICE" ]; then
    mkdir -p /etc/reader.conf.d
    cat > /etc/reader.conf.d/px4-userland.conf <<EOF
FRIENDLYNAME "PLEX PX4 Internal Card Reader"
DEVICENAME   px4-userland:runtime=${PX4_RUNTIME_DIR}:device=${PX4_DEVICE}:access=user
LIBPATH      /usr/lib/px4-userland/libpx4-userland-ifd.so
CHANNELID    0
EOF
fi

# USB CCID リーダーも px4 内蔵スロットも無い場合、recisdb decode は即終了して
# TS が流れなくなるため decode を無効化する。
if [ "$has_ccid" -eq 0 ] && [ -z "$PX4_DEVICE" ] && [ "$DECODE" -eq 1 ]; then
    echo "カードリーダー (USB CCID / px4 内蔵) が見つからないため decode を無効化します (recisdb はカード不在で即終了するため)。"
    DECODE=0
fi

if [ -x /usr/sbin/pcscd ]; then
    /usr/sbin/pcscd --foreground >> "$CFG/pcscd.log" 2>&1 &
fi

# BS/CS の ChSet4 (サービス→物理チャンネル対応) を機種名付きで置く。
# 中身は機種によらず同じで、ファイル名だけ BonDriver のチューナー名に合わせる。
if [ -n "$PX4_MODEL" ] && [ -f "$SEED/Setting/ChSet4.bs.txt" ]; then
    case "$PX4_MODEL" in
        px_q3u4) px4_name=PX-Q3U4 ;;
        px_q3pe4) px4_name=PX-Q3PE4 ;;
        px_q3pe5) px4_name=PX-Q3PE5 ;;
        px_w3u4) px4_name=PX-W3U4 ;;
        px_w3pe4) px4_name=PX-W3PE4 ;;
        px_w3pe5) px4_name=PX-W3PE5 ;;
        px_mlt5pe) px4_name=PX-MLT5PE ;;
        dtv02a_5ts_p) px4_name=DTV02A-5TS-P ;;
        px_mlt8pe3) px4_name=PX-MLT8PE3 ;;
        px_mlt8pe5) px4_name=PX-MLT8PE5 ;;
        dtv02a_4ts_p) px4_name=DTV02A-4TS-P ;;
        px_m1ur) px4_name=PX-M1UR ;;
        px_s1ur) px4_name=PX-S1UR ;;
        dtv03a_1tu) px4_name=DTV03A-1TU ;;
        dtv02_1t1s_u) px4_name=DTV02-1T1S-U ;;
        dtv02a_1t1s_u) px4_name=DTV02A-1T1S-U ;;
        *) px4_name= ;;
    esac
    if [ -n "$px4_name" ] && [ ! -f "$CFG/Setting/BonDriver_Px4_S(${px4_name}).ChSet4.txt" ]; then
        cp "$SEED/Setting/ChSet4.bs.txt" "$CFG/Setting/BonDriver_Px4_S(${px4_name}).ChSet4.txt"
        echo "BS/CS のチャンネル対応を ${px4_name} 用に置きました。"
    fi
fi

set_tvtest
export PX4_DEVICE PX4_MODEL PX4_RUNTIME_DIR
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
