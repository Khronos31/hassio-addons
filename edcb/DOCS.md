# EDCB

xtne6f 版 EDCB の Unix 版です。PX-S1UD は同梱の BonDriver_S1UD が直接開きます。siano-userland、px4-userland、recisdb も同梱です。mirakc アドオンと同時に USB チューナーは開きません。

画面はサイドバーの EDCB から開きます。Ingress が `/api/hassio_ingress/…` を剥がしてから 5510 へ渡します。ポート 5510 も残してあり、LAN から `http://<Home Assistant のアドレス>:5510/` でも開けます。どちらも認証はありません。

## 初期状態

`EpgTimerSrv.ini` の `Count` は 0 です。つながっている PX-S1UD の本数を `[BonDriver_S1UD.so]` の `Count` に書いて再起動すると、その本数だけ開きます。`Priority` は BonDriver ごとに違う値のままにしてください。

設定の置き場所は `/addon_configs/<リポジトリID>_edcb/` です。コンテナの中では `/config/` です。

チャンネル一覧が無いと、画面の「EPG取得」は開始できません。そのときは起動のついでに BonDriver_S1UD で地上波のチャンネルスキャンを一度だけ行います。進行は `chscan.log`、終わった印は `chscan.done` です。やり直すときはその2つを消して再起動します。

録画ファイルの初期の置き場所は `/media/EDCB` です。KonomiTV から使う TCP は 4510 です。

## 構成タブ

`mirakc_url` は空が既定です。空のあいだ BonDriver_LinuxMirakc は使いません。mirakc 経由にするときだけ `http://<リポジトリID>-mirakc:40772` のように書きます。`decode` をオンにすると、そのストリーム URL に `decode=1` を付けます。
