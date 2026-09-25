#!/bin/sh
# 地上波 BonDriver のチャンネルスキャン。EPG取得の前にチャンネル一覧が要る。
set -eu
echo "start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
/usr/local/bin/EpgDataCap_Bon -d BonDriver_S1UD.so -chscan
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
