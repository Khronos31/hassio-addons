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

mkdir -p "$CFG" /media/EDCB "$LIB" /run/edcb-s1ud
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

# チャンネル一覧が無いと Web UI の EPG取得は「開始できませんでした」になる。
# 地上波用 BonDriver で一度だけスキャンし、結果は Setting/ に残る。
if [ ! -f "$CFG/chscan.done" ]; then
    echo "チャンネルスキャンを開始します。記録は ${CFG}/chscan.log です。"
    setsid /chscan.sh >> "$CFG/chscan.log" 2>&1 < /dev/null &
fi

echo "EDCB を起動します。mirakc_url=${MIRAKC_URL:-空} decode=${DECODE}。チューナー本数は EpgTimerSrv.ini の Count です。"
exec /usr/local/bin/EpgTimerSrv
