#!/bin/sh
# 地上波 BonDriver のチャンネルスキャン。EPG取得の前にチャンネル一覧が要る。
# px4 (Q3U4/MLT5 系) が検出済みなら BonDriver_Px4_T.so、無ければ BonDriver_S1UD.so。
set -eu

driver=BonDriver_S1UD.so
if [ -n "${PX4_DEVICE:-}" ]; then
    driver=BonDriver_Px4_T.so
    runtime_dir=${PX4_RUNTIME_DIR:-/run/px4-userland}
    i=0
    while [ "$i" -lt 60 ]; do
        if /usr/local/bin/px4ctl --device "$PX4_DEVICE" --runtime-dir "$runtime_dir" list >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
        i=$((i + 1))
    done
fi

echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ) driver=$driver"
set +e
/usr/local/bin/EpgDataCap_Bon -d "$driver" -chscan
code=$?
set -e
echo "exit ${code} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$code" -eq 0 ] && ls /config/Setting/*ChSet* >/dev/null 2>&1; then
    touch /config/chscan.done
else
    echo "チャンネル一覧はできていません" >&2
    code=1
fi
exit "$code"
