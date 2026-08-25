# EPGStation

Mirakurun を使用した録画管理ソフト [EPGStation](https://github.com/l3tnun/EPGStation) の
Home Assistant アドオンです。

## 用意するもの

チューナーを持つ **mirakc** または **Mirakurun** が要ります。同じリポジトリの
[mirakc アドオン](../mirakc) を HAOS 上で動かしてもよいです。
カーネルモジュールが要る構成では、別の機械に置いて HTTP で問い合わせます。

## 設定

EPGStation の `config.yml` を直接編集します。置き場所は

```
/addon_configs/<リポジトリID>_epgstation/config.yml
```

初回起動時にテンプレートから作られるので、`mirakurunPath` を自分の mirakc / Mirakurun へ
向けてください。書式と全キーの説明は
[上流のマニュアル](https://github.com/l3tnun/EPGStation/blob/master/doc/conf-manual.md)
がそのまま使えます。

**構成タブに設定項目はありません。** EPGStation の設定は深さ6まで入れ子になっており、
アドオンの `schema` が扱える上限（深さ2）に収まらないためです。

### アドオンが固定するもの

`port` / `clientSocketioPort` / `subDirectory` の3つは、起動のたびに書き戻します。
変えると ingress の下で socket.io が繋がらなくなり、**画面は出るのに動かない**という
分かりにくい壊れ方をするためです。書き換えても、アドオンを再起動すれば元に戻ります。

### 置き場所

録画先は `recorded` に書きます。複数指定できます。`/media` か `/share` の下にしてください。
データベースとサムネイルはアドオンの `/data` に置かれるので、更新しても残ります。
`dropLog` や `recordedTmp` を使う場合も `/data` の下にすると更新後も残ります。

設定を壊すと EPGStation は起動しません。上流をそのまま使ったときと同じです。
ファイルを消せばテンプレートから作り直されます。

## 開き方

- **サイドバー** — Home Assistant のログインを通ります。Home Assistant Cloud 経由でも開けます
- **`http://<Home Assistant の IP>:8888`** — 認証はありません。ingress を使えない
  Android TV のクライアントなどはこちらから。要らなければ構成タブでポートを空欄にしてください

## 上流との違い

- **ffmpeg を同梱しています。** 上流のイメージには入っておらず、変換が失敗します。
  上流の既定値に合わせて `/usr/local/bin` からも引けるようにしてあるので、`ffmpeg` /
  `ffprobe` を設定で書き換える必要はありません
- **ingress の下で socket.io が繋がるよう、フロントエンドを起動時に書き換えます。**
  同梱のものは接続先のポートを設定値から作るため、経路によって食い違います

amd64 でのみ確認しています。
