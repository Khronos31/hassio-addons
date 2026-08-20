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
| `recorded_path` | 録画物の置き場。既定は `/media/EPGStation` |

データベースとサムネイルはアドオンの `/data` に置かれるので、更新しても残ります。

## 開き方

- **サイドバー** — Home Assistant のログインを通ります。Home Assistant Cloud 経由でも開けます
- **`http://<Home Assistant の IP>:8888`** — 認証はありません。ingress を使えない
  Android TV のクライアントなどはこちらから。要らなければ構成タブでポートを空欄にしてください

## 外付けディスクへ録画する

Home Assistant OS は USB ディスクを直接マウントできません。

1. ディスクにラベルを付ける
2. Samba NAS アドオンの `automount` を有効にする（ラベル名の共有ができます）
3. **設定 → システム → ストレージ** で、その共有を cifs として追加する
   （サーバー `172.30.32.1`、用途「メディア」）
4. `recorded_path` を `/media/<ラベル>` に向ける

## 上流との違い

- **ffmpeg を同梱しています。** 上流のイメージには入っておらず、変換が失敗します
- **ingress の下で socket.io が繋がるよう、フロントエンドを起動時に書き換えます。**
  同梱のものは接続先のポートを設定値から作るため、経路によって食い違います

amd64 でのみ確認しています。
