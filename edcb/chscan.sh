#!/bin/sh
# 地上波 BonDriver のチャンネルスキャン。EPG取得の前にチャンネル一覧が要る。
# px4-userland 対応機器があれば hybrid BonDriver_Px4.so、無ければ BonDriver_S1UD.so。
# BS/CS は起動時に同梱の標準一覧を ChSet5.txt へ足してあるのでスキャンしない。
set -eu

driver=BonDriver_S1UD.so
if [ -n "${EDCB_PX4_SLOTS:-}" ]; then
    driver=BonDriver_Px4.so
    EDCB_PX4_GR_ONLY=1
    export EDCB_PX4_GR_ONLY
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
