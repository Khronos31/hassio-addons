#!/bin/sh
# mirakc を Home Assistant のアドオンとして起動する。
# チューナーは siano-ts（libusb）が /dev/bus/usb から開く。HAOS に smsusb は無い。
# B-CAS は recisdb が PC/SC 経由で読む。
set -eu

USER_CFG=/config/config.yml
APP_CFG=/etc/mirakc/config.yml
FIRMWARE=${PX_S1UD_FIRMWARE:-/lib/firmware/isdbt_rio.inp}

mkdir -p /data/epg /run/pcscd "$(dirname "$APP_CFG")"

if [ ! -f "$USER_CFG" ]; then
    echo "config.yml がないのでテンプレートから作ります: ${USER_CFG}" >&2
    cp /usr/share/mirakc-addon/config.yml.template "$USER_CFG"
fi

if [ -d "$APP_CFG" ]; then
    rmdir "$APP_CFG" 2>/dev/null || rm -rf "$APP_CFG"
fi
ln -sfn "$USER_CFG" "$APP_CFG"

if [ ! -r "$FIRMWARE" ]; then
    echo "firmware がありません: ${FIRMWARE}" >&2
    echo "イメージに isdbt_rio.inp が入っているはずです。再ビルドしてください。" >&2
    exit 1
fi

if [ -x /usr/sbin/pcscd ]; then
    # アドオンに polkit は居ない。
    /usr/sbin/pcscd --disable-polkit || /usr/sbin/pcscd || true
fi

echo "設定: ${USER_CFG}" >&2
echo "firmware: ${FIRMWARE}" >&2
if command -v siano-ts >/dev/null 2>&1; then
    siano-ts --list || true
    # スキャンは約10秒で打ち切られる。ファーム未投入だとその窓にTSが間に合わない。
    echo "firmware warmup..." >&2
    d=0
    while [ "$d" -le 1 ]; do
        siano-ts --channel 27 --device "$d" --firmware "$FIRMWARE" -t 3 -o /dev/null || true
        d=$((d + 1))
    done
fi
# 公式イメージの既定は /etc/mirakc/config.yml。上でそこにリンクを張ってある。
exec mirakc
