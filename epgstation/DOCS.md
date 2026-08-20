# EPGStation

[EPGStation](https://github.com/l3tnun/EPGStation) を Home Assistant のアドオンとして動かします。

## これは何をしないか

**チューナーには触りません。** Home Assistant OS のカーネルには地デジチューナーの
ドライバとファームウェアが揃っていないため、受信は別のマシンに任せます。
このアドオンは **mirakc** か **Mirakurun** に HTTP で問い合わせるだけです。

```
別のマシン       mirakc / Mirakurun ＋ チューナー ＋ B-CAS カードリーダー
Home Assistant   このアドオン（番組表・予約・録画・視聴）
```

## 設定

| 項目 | 説明 |
|---|---|
| `mirakurun_url` | mirakc / Mirakurun の URL。例 `http://192.168.1.10:40772` |
| `recorded_path` | 録画物の置き場。既定は `/media/EPGStation` |

データベース（SQLite）とサムネイルはアドオンの `/data` に置かれるので、更新しても消えません。

### 録画物の置き場について

`/media` の下に置くと Home Assistant のメディアブラウザからも見えます。
外付けディスクへ録画したい場合、**Home Assistant OS は任意の USB ディスクを直接
マウントできません。** 実際に動く道はこうです。

1. ディスクにラベルを付ける（例 `TV_RECORDINGS`）
2. Samba NAS アドオン（`automount` を有効に）がラベル名の共有を作る
3. **設定 → システム → ストレージ** で、その共有を `cifs` として追加する
   （サーバーは `172.30.32.1`、用途は「メディア」）

`/media/<名前>` に出るので、`recorded_path` をそこへ向けます。

## 二通りの開き方

- **サイドバー / アプリ画面（ingress）** — Home Assistant のログインの後ろに入ります。
  Home Assistant Cloud 経由でもそのまま開けます
- **`http://<Home Assistant の IP>:8888`** — ポートを直接開いた形。**認証はありません。**
  Android TV のクライアント（[epcltvapp](https://github.com/daig0rian/epcltvapp) など）は
  ingress を使えないので、こちらが要ります。不要なら構成タブでポートを空欄にすれば閉じられます

⚠️ **ingress はブラウザのセッションを見ます。** スクリプトから API を叩きたい場合、
Bearer トークンでは 401 になります。開いたポートを使うか、Home Assistant 本体から
`http://<アドオンのホスト名>:8888/api/...` を叩いてください。

## 上流に手を入れている点

上流の EPGStation は 2024 年から更新が止まっています。動きますが直りません。
このアドオンは起動時に次の手当てをします。理由もコードのコメントに書いてあります。

1. **ffmpeg を足す** — 上流のイメージには入っておらず、変換が全部 500 で落ちます。
   無変換のライブ視聴だけは通るので気づきにくい問題です
2. **配信されるフロントエンドを書き換えて、socket.io を同一オリジンへ繋がせる** —
   同梱のフロントは接続先のポートだけを静的な設定値から作るため、ingress の下では
   経路によって食い違います（宅内 8123 / Home Assistant Cloud 443）。
   書き換えのパターンが見つからなければ警告を出して素通しします
3. **`clientSocketioPort` を置く** — HTTPS で来た要求に対して EPGStation が
   `httpsConfigError` で 500 を返すのを止めるためだけのものです。値は 2 の書き換えにより
   使われません
4. **設定はテンプレを土台にする** — 手書きで最小化すると `stream:` ブロックが落ち、
   「放映中」タブが消えます

## 確認済みの範囲

- Home Assistant OS 18.2 / amd64
- EPGStation v2.10.0、mirakc 3.4.81
- ingress（宅内・Home Assistant Cloud 経由の両方）で socket.io が繋がることを実測
- arm64 は**未確認**です
