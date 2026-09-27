#!/bin/sh
# denpa 本体とチューナーエージェントを同じコンテナで起動する。
set -eu

mkdir -p \
    /media/DTV/denpa/recorded \
    /media/DTV/denpa/library \
    /config \
    /data \
    /run/px4-userland

export TZ=Asia/Tokyo
export TUNERS_FILE=/config/tuners.json
export CHANNELS_FILE=/config/channels.json
export RECORDED_DIR=/media/DTV/denpa/recorded
export LIBRARY_DIR=/media/DTV/denpa/library
export DENPA_DB=/data/denpa.db
export TUNER_AGENT_URL=http://127.0.0.1:25252
export PX4_USERLAND_DIR=/opt/px4-userland
export PX4_RUNTIME_DIR=/run/px4-userland
# Ingress 中継は同じコンテナの 127.0.0.1 から届く。家の LAN と Tailscale も通す。
export TRUSTED_NETWORKS=127.0.0.0/8,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,100.64.0.0/10
# 録画中の停止待ちはアドオンの timeout に収める。
export SHUTDOWN_WAIT=15000

# BS/CS の標準チャンネル一覧をシードする。地上波は地域で変わるので入れない
# (画面のスキャンで拾う。空きチャンネルは選局がすぐ落ちるので数分で済む)。
# channels.json が無ければそのまま置き、あれば「まだ居ない種別」だけ追記する
# (ユーザーがスキャン済みの種別は触らない)。
if [ ! -f "$CHANNELS_FILE" ]; then
    cp /usr/share/denpa-addon/channels.bs.json "$CHANNELS_FILE"
    echo "BS/CS の標準チャンネル一覧を置きました: $CHANNELS_FILE"
else
    jq -s '.[0] as $cur | .[1] as $seed | $cur + [ $seed[] | select(.type as $t | ($cur | map(.type) | index($t) | not)) ]' \
        "$CHANNELS_FILE" /usr/share/denpa-addon/channels.bs.json > "$CHANNELS_FILE.tmp" \
        && mv "$CHANNELS_FILE.tmp" "$CHANNELS_FILE"
    echo "BS/CS の標準チャンネル一覧を追記しました: $CHANNELS_FILE"
fi

echo "CapEff $(awk '/^CapEff:/ {print $2}' /proc/1/status)"
echo "チューナーエージェントを起動します"
/usr/local/bin/denpa-agent >> /config/agent.log 2>&1 &
agent_pid=$!

echo "Ingress 中継を起動します"
bun /ingress.js >> /config/ingress.log 2>&1 &
ingress_pid=$!

echo "denpa を起動します"
bun ./server.js >> /config/denpa.log 2>&1 &
denpa_pid=$!

stop() {
    kill "$denpa_pid" "$agent_pid" "$ingress_pid" 2>/dev/null || true
    wait "$denpa_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
    wait "$ingress_pid" 2>/dev/null || true
}
trap stop TERM INT
wait "$denpa_pid"
