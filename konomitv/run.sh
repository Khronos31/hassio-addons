#!/bin/sh
# KonomiTV を Home Assistant のアドオンとして起動する。
set -eu

# 自分のホスト名 local-konomitv / <リポジトリID>-konomitv から、
# 同じ置き方の EDCB アドオンのホスト名を決める。
self_host=$(hostname)
case "$self_host" in
    *-konomitv) edcb_host=${self_host%-konomitv}-edcb ;;
    *) edcb_host=edcb ;;
esac

if [ ! -f /config/config.yaml ]; then
    sed "s/@EDCB_HOST@/${edcb_host}/g" /code/config.default.yaml > /config/config.yaml
    echo "設定を作りました: /config/config.yaml (edcb_url のホストは ${edcb_host})"
fi
ln -sfn /config/config.yaml /code/config.yaml

# Docker 判定のとき、設定に書いたパスの先頭へ /host-rootfs が付く。
# コンテナの中のパスをそのまま使えるようにする。
ln -sfn / /host-rootfs

# SrvPipe の FIFO は EDCB の設定フォルダにできる。ホスト名の - はディレクトリ名では _。
mkdir -p /var/local
edcb_from_config=$(sed -n 's/^[[:space:]]*edcb_url:[[:space:]]*tcp:\/\/\([^:/]*\).*/\1/p' /config/config.yaml | head -n 1)
case "$edcb_from_config" in
    ""|edcb-namedpipe) ;;
    *)
        edcb_slug=$(printf '%s' "$edcb_from_config" | tr '-' '_')
        if [ -d "/addon_configs/${edcb_slug}" ]; then
            ln -sfn "/addon_configs/${edcb_slug}" /var/local/edcb
        fi
        ;;
esac

mkdir -p /media/EDCB /media/KonomiTV-Capture

PY=/code/server/.venv/bin/python
"$PY" /ingress_proxy.py --patch-assets /code/client/dist
setsid "$PY" /ingress_proxy.py >> /config/ingress-proxy.log 2>&1 < /dev/null &

cd /code/server
exec "$PY" KonomiTV.py
