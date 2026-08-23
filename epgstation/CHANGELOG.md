# 変更履歴

## 0.1.8

**設定の持ち方を変えました。** 構成タブの項目を廃止し、EPGStation の `config.yml` を
`/addon_configs/<リポジトリID>_epgstation/config.yml` で直接編集する形にしました。
上流の全キーがそのまま使え、マニュアルも上流のものが通用します。

- `/app/config/config.yml` はこのファイルへのシンボリックリンクなので、上流の再読込がそのまま効く
- `port` / `clientSocketioPort` / `subDirectory` は起動のたびに書き戻す。壊しても再起動で直る
- `ffmpeg` / `ffprobe` を `/usr/local/bin` からも引けるようにし、上流の既定値を正解にした。
  設定での上書きをやめた
- 構成タブの `mirakurun_url` / `recorded_path` を削除。録画先は `config.yml` の `recorded` で
  指定する（複数可）
- 構成タブの読み取りに使っていた `jq` を同梱から外した

**更新後、初回起動時に現在の設定からファイルは作られません。** テンプレートから作られるので、
`mirakurunPath` と `recorded` を設定し直してください。

## 0.1.7

最初の公開。

- EPGStation v2.10.0 を Home Assistant のアドオンとして動かす
- ingress に対応（Home Assistant のログインの後ろに入り、Home Assistant Cloud 経由でも開ける）
- 上流のイメージに無い ffmpeg を足す
- socket.io を同一オリジンへ繋ぐようフロントエンドを書き換える
- ホストポート 8888 を開く（Android TV のクライアント向け。認証なし）
