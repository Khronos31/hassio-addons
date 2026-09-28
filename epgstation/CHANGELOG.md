# Changelog

## 2.10.0.2

- `stream.live.ts.mp4` へライブ音声プロファイル `Home Assistant Live Audio MP3` を追加（`/api/streams/live/{channelId}/mp4?mode=2` で MP3 / 48kHz / 2ch / 192kbps を配信）
- 初回設定・既存設定の両方へ冪等追加。不正な設定は元ファイルを変更せず警告して起動を継続

## 2.10.0.1

- バージョン表記を「上流バージョン + アドオン改訂」（`2.10.0.1`）に変更
- コード変更なし。同梱の EPGStation は 2.10.0（最新）のまま

## 0.2.3

- 録画先の初期値を `/media/DTV/EPGStation` に変更

## 0.2.2

- mirakurunPath を `.local.hass.io` 名（IPv4 のみ）に修正。短いホスト名は IPv6 を先に返すため、
  Node.js の EPGStation が mirakc へ接続できず「check mirakurun」が無限ループする問題を修正
- 末尾スラッシュを除去（mirakurun ライブラリが `//api/...` を発行して 404 になるため）

## 0.2.1

- `mirakurunPath` を初回起動時に兄弟の mirakc アドオンへ自動設定（ホスト名導出）

# 変更履歴

## 0.2.0

- TS／encoded の両方に、互換用の既存AACプロファイルと別名のMP3プロファイルを追加
- MP3移行前のconfigを同一ディレクトリへ一度だけ即時バックアップし、予約名を厳密検証した冪等・atomic移行を実施
- YAML形式が自動移行に対応しない場合は警告して音声移行をスキップするが、EPGStationの起動・録画は妨げない
- MP3レスポンスのメディア型を扱うHome Assistant統合側と協調して更新する

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
