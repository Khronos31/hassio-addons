# EDCB

[xtne6f/EDCB](https://github.com/xtne6f/EDCB) の Unix 版です。PX-S1UD は同梱の
`BonDriver_S1UD` が、px4-userland 対応機種（全16モデル）は同梱の
`BonDriver_Px4_T` / `BonDriver_Px4_S` が直接開きます。siano-userland、
px4-userland、recisdb も同梱です。

mirakc アドオンと同時に USB チューナーは開きません。どちらかを止めてください。

## 画面とポート

- サイドバーの EDCB から Ingress で開けます（内部は 5510）
- `5510/tcp` — EDCB の Web UI。LAN から `http://<Home Assistant のアドレス>:5510/`
- `4510/tcp` — EpgTimerSrv の TCP API。KonomiTV や TVTest が使います

いずれも認証はありません。不要なら構成タブのポート欄を空欄にすれば閉じられます。

## 設定ファイル

置き場所は `/addon_configs/<リポジトリID>_edcb/`（コンテナ内では `/config/`）です。

- `EpgTimerSrv.ini` — サーバーと BonDriver の設定
- `EpgDataCap_Bon.ini` — チューナー起動の設定
- `BonCtrl.ini` — スキャン・EPG 取得の設定
- `Setting/ChSet5.txt` — チャンネル一覧

それぞれの項目の意味は、本家 EDCB のドキュメントを参照してください。
`EpgTimerSrv.ini` は起動のたびに一部の値（`Count`、`[TVTEST]`）を自動で書き換えます。

## 起動時の動作

- USB チューナーを検出し、`EpgTimerSrv.ini` の `Count` と `[TVTEST]` を機種に応じて書きます
- px4-userland 対応機種の内蔵カードスロットを pcscd に登録します（recisdb の B-CAS 復号用）
- B-CAS カードを読む手段が無いときは `decode` を自動で無効化します
- 初回起動時に地上波のチャンネルスキャンを一度だけ行います（進行は `chscan.log`、
  完了の印は `chscan.done`。やり直すときはこの2つを消して再起動）
- BS/CS のチャンネル一覧は標準リストを同梱しており、スキャンはしません

録画ファイルの置き場所は `/media/EDCB` です。

## 構成タブ

- `mirakc_url` — mirakc 経由でチューナーを使うときだけ設定します（例:
  `http://<リポジトリID>-mirakc:40772`）。空のあいだ `BonDriver_LinuxMirakc` は使いません
- `decode` — 既定はオンです。カードリーダーが無い場合は起動時に自動でオフになります
