# mirakc

[mirakc](https://github.com/mirakc/mirakc) に、PX-S1UD / PX-Q3U4 用のユーザ空間ドライバ
[siano-ts](https://github.com/Khronos31/siano-userland) と
[px4-userland](https://github.com/Khronos31/px4-userland)、
[recisdb](https://github.com/kazuki0824/recisdb-rs) を同梱したアドオンです。

## 用意するもの

- PX-S1UD（`3275:0080`）。HAOS に Siano のカーネルドライバは入りません
- PX-Q3U4（`0511:084a` の2台1組、任意）
- PX-MLT5PE（`0511:024e`）または DTV02A-5TS-P（`0511:924e`）1台。Q3U4 とは同時に使わない
- 復号には B-CAS カードが必要です。PX-Q3U4 は本体カードスロットを利用でき、PX-S1UD のみなら外付け PC/SC リーダが必要です

録画は [EPGStation](../epgstation) アドオンが HTTP で引きます。

## 設定

```
/addon_configs/<リポジトリID>_mirakc/config.yml
```

初回起動時にテンプレート（関東の主な地デジと無料のBS/CS試験チャンネル）から作られます。
チャンネルや独自チューナー設定は、このファイルを編集してアドオンを再起動してください。
同梱チューナー定義は、起動時に検出・検証できたデバイスだけが実効設定へ残ります。

`{{{channel}}}` は mirakc が `T27` のような値に展開します。ラッパが物理チャンネル番号に直して
`siano-ts --channel` へ渡します。

構成タブに設定項目はありません。mirakc の YAML が schema の深さ制限に収まりません。

## ファームウェア

`isdbt_rio.inp` は linux-firmware の再配布可能なバイナリです。イメージに同梱し、
著作権表示は `LICENCE.siano` をイメージ内へ入れています。ソースリポジトリの git には入れていません。

PX-Q3U4 の `it930x-firmware.bin` はイメージに同梱しません。Q3U4 を検出した起動で有効な
キャッシュがない場合、アドオンは PLEX の Web サイトから公式ドライバZIPを HTTPS で取得します。
固定マニフェストにより、ZIP（サイズ/SHA-256）、ZIP内の完全一致するSYSエントリ
（サイズ/SHA-256）、`fwtool` の出力（ファイル名/サイズ/SHA-256）を順番に検証します。
ZIP内のディレクトリを展開せず、完全一致したSYSエントリだけを一時ファイルへストリームし、
検証済み候補だけを同一ディレクトリで atomic rename します。

生成物は次へ永続キャッシュされます。

```
/addon_configs/<リポジトリID>_mirakc/it930x-firmware.bin
```

有効なキャッシュはオフラインで再利用します。PLEX サイトに到達できない場合や検証に失敗した場合、
既存キャッシュを上書きせず、PX-Q3U4 を無効化して PX-S1UD だけで起動を続けます。
公式ZIP、SYS、生成ファームウェアはいずれもリポジトリとアドオンイメージへ含めません。

生成には [nns779/px4_drv](https://github.com/nns779/px4_drv) v0.2.1
（commit `2b3f79b5bc5db56e8556bb28397f7d8f74b2adeb`）の `fwtool` と `fwinfo.tsv` を使います。
対応する固定ソースは `/usr/share/src/px4_drv-0.2.1`、GPL-2.0 ライセンスは
`/usr/share/doc/px4_drv-fwtool/LICENSE` に収録しています。siano-userland と px4-userland も
固定したソースを `/usr/share/src` に収録しています。

## 開き方

**`http://<Home Assistant の IP>:40772`** — 認証はありません。EPGStation と
Android TV のクライアントはこちら。要らなければ構成タブでポートを空欄にしてください。
Ingress はありません。画面は EPGStation アドオンです。

## 上流との違い

- **siano-ts を同梱**し、`/dev/bus/usb` から libusb で PX-S1UD を開きます
- **px4-userland を同梱**し、Q3U4 の8受信系とカード経路をユーザ空間で開きます
- Q3U4 検出時だけ、PLEX 配布物からファームウェアを検証付きで生成・永続キャッシュします
- **recisdb decode** を tuner command の後ろに置き、B-CAS で解いた TS を mirakc へ渡します
- **pcscd** を起動時に起こします
- 録画機能は使いません。EPG キャッシュは `/data/epg` に残します

amd64 で、PX-Q3U4 の地デジ・BS/CS受信、B-CAS復号、8受信系の列挙・割当、
地デジ4系統同時受信、BS/CS 4系統同時受信、終了処理、および PX-S1UD 2台との併用を確認済みです。
