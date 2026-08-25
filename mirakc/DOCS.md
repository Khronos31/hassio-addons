# mirakc

[mirakc](https://github.com/mirakc/mirakc) に、PX-S1UD 用のユーザ空間ドライバ
[siano-ts](https://github.com/Khronos31/siano-userland) と
[recisdb](https://github.com/kazuki0824/recisdb-rs) を同梱したアドオンです。

## 用意するもの

- PX-S1UD（`3275:0080`）。HAOS に Siano のカーネルドライバは入りません
- 復号するなら B-CAS カードと IC カードリーダ

録画は [EPGStation](../epgstation) アドオンが HTTP で引きます。

## 設定

```
/addon_configs/<リポジトリID>_mirakc/config.yml
```

初回起動時にテンプレート（関東の主な地デジ）から作られます。チャンネルの増減と
`PX-S1UD #0` / `#1` の本数は、このファイルを編集してアドオンを再起動してください。

`{{{channel}}}` は mirakc が `T27` のような値に展開します。ラッパが物理チャンネル番号に直して
`siano-ts --channel` へ渡します。

構成タブに設定項目はありません。mirakc の YAML が schema の深さ制限に収まりません。

## ファームウェア

`isdbt_rio.inp` は linux-firmware の再配布可能なバイナリです。イメージに同梱し、
著作権表示は `LICENCE.siano` をイメージ内へ入れています。ソースリポジトリの git には入れていません。

## 開き方

**`http://<Home Assistant の IP>:40772`** — 認証はありません。EPGStation と
Android TV のクライアントはこちら。要らなければ構成タブでポートを空欄にしてください。
Ingress はありません。画面は EPGStation アドオンです。

## 上流との違い

- **siano-ts を同梱**し、`/dev/bus/usb` から libusb で PX-S1UD を開きます
- **recisdb decode** を tuner command の後ろに置き、B-CAS で解いた TS を mirakc へ渡します
- **pcscd** を起動時に起こします
- 録画機能は使いません。EPG キャッシュは `/data/epg` に残します

amd64 でのみ確認しています。
