#!/bin/sh
# denpa 本体とチューナーエージェントを同じコンテナで起動する。
set -eu

mkdir -p \
    /media/DTV/denpa/recorded \
    /media/DTV/denpa/library \
    /config \
    /data \
    /run/px4-userland \
    /run/pcscd \
    /etc/reader.conf.d

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
# 画面の Host は Home Assistant 側のものを使う。書き換えないと Ingress の POST が弾かれる。
export HOST_HEADER=x-forwarded-host
# 録画中の停止待ちはアドオンの timeout に収める。
export SHUTDOWN_WAIT=15000

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
