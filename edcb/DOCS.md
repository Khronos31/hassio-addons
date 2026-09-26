# EDCB

xtne6f 版 EDCB の Unix 版です。PX-S1UD は同梱の BonDriver_S1UD が、PX-Q3U4 / PX-MLT5PE 系は同梱の BonDriver_Px4_T / _S が直接開きます。siano-userland、px4-userland、recisdb も同梱です。mirakc アドオンと同時に USB チューナーは開きません。

画面はサイドバーの EDCB から開きます。Ingress が `/api/hassio_ingress/…` を剥がしてから 5510 へ渡します。ポート 5510 も残してあり、LAN から `http://<Home Assistant のアドレス>:5510/` でも開けます。どちらも認証はありません。

## 初期状態

`EpgTimerSrv.ini` の `Count` は 0 です。つながっている PX-S1UD の本数を `[BonDriver_S1UD.so]` の `Count` に書いて再起動すると、その本数だけ開きます。`Priority` は BonDriver ごとに違う値のままにしてください。

PX-Q3U4 / PX-MLT5PE 系が刺さっていれば、起動時に検出して px4d を起こし、`[BonDriver_Px4_T.so]`（地上波）と `[BonDriver_Px4_S.so]`（BS/CS）の `Count` を自動で書きます。Q3U4 は地上波 4 / BS・CS 4、MLT5 系は 5 / 5 です。

設定の置き場所は `/addon_configs/<リポジトリID>_edcb/` です。コンテナの中では `/config/` です。

チャンネル一覧が無いと、画面の「EPG取得」は開始できません。そのときは起動のついでに地上波のチャンネルスキャンを一度だけ行います（px4 が刺さっていれば BonDriver_Px4_T、無ければ BonDriver_S1UD）。進行は `chscan.log`、終わった印は `chscan.done` です。やり直すときはその2つを消して再起動します。BS/CS のチャンネルは画面から設定してください。

録画ファイルの初期の置き場所は `/media/EDCB` です。KonomiTV から使う TCP は 4510 です。

## 構成タブ

`mirakc_url` は空が既定です。空のあいだ BonDriver_LinuxMirakc は使いません。mirakc 経由にするときだけ `http://<リポジトリID>-mirakc:40772` のように書きます。`decode` をオンにすると、そのストリーム URL に `decode=1` を付けます。
