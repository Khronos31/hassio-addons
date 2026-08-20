# EPGStation

Mirakurun を使用した録画管理ソフト [EPGStation](https://github.com/l3tnun/EPGStation) の
Home Assistant アドオンです。

## 用意するもの

チューナーを持つ **mirakc** または **Mirakurun** を別の機械に用意してください。
Home Assistant OS には地上デジタルチューナーのドライバとファームウェアが入っていません。

## 設定

| 項目 | 説明 |
|---|---|
| `mirakurun_url` | mirakc / Mirakurun の URL。例 `http://192.168.1.10:40772` |
| `recorded_path` | 録画物の置き場。`/media` か `/share` の下。既定は `/media/EPGStation` |

データベースとサムネイルはアドオンの `/data` に置かれるので、更新しても残ります。

## 開き方

- **サイドバー** — Home Assistant のログインを通ります。Home Assistant Cloud 経由でも開けます
- **`http://<Home Assistant の IP>:8888`** — 認証はありません。ingress を使えない
  Android TV のクライアントなどはこちらから。要らなければ構成タブでポートを空欄にしてください

## 上流との違い

- **ffmpeg を同梱しています。** 上流のイメージには入っておらず、変換が失敗します
- **ingress の下で socket.io が繋がるよう、フロントエンドを起動時に書き換えます。**
  同梱のものは接続先のポートを設定値から作るため、経路によって食い違います

amd64 でのみ確認しています。
