#!/bin/sh
# アドオンの保存先を環境変数に合わせ、上流 AIO の入口へ制御を渡す。
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
# px4d / px4ctl は同一シリアルの筐体を区別できないため、互換ラッパーに差し替えて
# いる。実体はここに残す (Dockerfile の参照)。
export PX4_REAL_USERLAND_DIR=/opt/px4-compat-real
# HA Ingress の接頭辞は denpa 本体が処理する。Supervisor の内部アドレスと
# 家の LAN / Tailscale を信頼するネットワークとして維持する。
export TRUSTED_NETWORKS=127.0.0.0/8,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,100.64.0.0/10
# 録画中の停止待ちはアドオンの timeout に収める。
export SHUTDOWN_WAIT=15000

# BS/CS の標準チャンネル一覧をシードする。地上波は地域で変わるので入れない
# (画面のスキャンで拾う。空きチャンネルは選局がすぐ落ちるので数分で済む)。
# channels.json が無ければそのまま置き、あれば「まだ居ない種別」だけ追記する
# (ユーザーがスキャン済みの種別は触らない)。壊れた JSON は上書きせず見送る。
if [ ! -f "$CHANNELS_FILE" ]; then
    cp /usr/share/denpa-addon/channels.bs.json "$CHANNELS_FILE"
    echo "BS/CS の標準チャンネル一覧を置きました: $CHANNELS_FILE"
elif jq -e 'type == "array"' "$CHANNELS_FILE" > /dev/null 2>&1; then
    if jq -s '.[0] as $cur | .[1] as $seed | $cur + [ $seed[] | select(.type as $t | ($cur | map(.type) | index($t) | not)) ]' \
        "$CHANNELS_FILE" /usr/share/denpa-addon/channels.bs.json > "$CHANNELS_FILE.tmp" 2>/dev/null; then
        mv "$CHANNELS_FILE.tmp" "$CHANNELS_FILE"
        echo "BS/CS の標準チャンネル一覧を追記しました: $CHANNELS_FILE"
    else
        rm -f "$CHANNELS_FILE.tmp"
        echo "BS/CS の標準チャンネル一覧を追記できませんでした: $CHANNELS_FILE"
    fi
else
    echo "channels.json を読めないので標準チャンネル一覧の追記を見送ります: $CHANNELS_FILE"
fi

echo "CapEff $(awk '/^CapEff:/ {print $2}' /proc/1/status)"
echo "上流の denpa-aio 入口で本体とチューナーエージェントを起動します"
exec /usr/local/bin/denpa-aio
