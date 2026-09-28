# KonomiTV

視聴画面です。番組表・予約・放送波は EDCB から取ります。

## 画面とポート

- サイドバーの KonomiTV から Ingress で開けます（内部は 7011）
- `7000/tcp` — KonomiTV サーバー。LAN から `http://<Home Assistant のアドレス>:7000/` でも開けます
- 不要なら構成タブのポート欄を空欄にすれば閉じられます

## 設定ファイル

置き場所は `/addon_configs/<リポジトリID>_konomitv/config.yaml` です。
それぞれの項目の意味は [KonomiTV のドキュメント](https://github.com/tsukumijima/KonomiTV) を参照してください。

初回起動時に `config.default.yaml` から `config.yaml` を作ります。
そのとき `edcb_url` と `mirakurun_url` のホストは自分のホスト名から自動で入れます。

- このアドオンが `local-konomitv` なら `tcp://local-edcb:4510/` と `http://local-mirakc:40772/`
- リポジトリから入れた `<リポジトリID>-konomitv` なら `tcp://<リポジトリID>-edcb:4510/` と `http://<リポジトリID>-mirakc:40772/`

別の場所の EDCB / mirakc を使うときは、この行を書き換えます。
放送波を mirakc から受けるときは `always_receive_tv_from_mirakurun` を true にします。

## 録画ファイル

`/media` は読み書きで入っています。どのディレクトリに置くかは `config.yaml` の
`video.recorded_folders` です。初期値は `/media/DTV/EDCB` です。

Docker の中だと、書いたパスの先頭に `/host-rootfs` が付きます。`/host-rootfs` はコンテナ自身への
リンクなので、`/media/DTV/EDCB` とそのまま同じ場所です。

## 音声だけ配信（7002/tcp）

Home Assistant の Media Source から「音声だけ」で再生するためのサイドカーが動いています。
KonomiTV 本体は無改修で、同梱 FFmpeg が録画ファイル / ライブストリームを MP3 に変換して流します。

- `GET http://<このアドオンのホスト>:7002/api/recorded/{録画ID}/audio.mp3`
- `GET http://<このアドオンのホスト>:7002/api/streams/live/{チャンネルID}/audio.mp3?quality=720p`
- 状態確認: `GET /healthz` → `ok`

録画IDは KonomiTV の録画番組 API（`/api/videos`）の `id` です。チャンネルIDは `gr011` のような
表示用チャンネル ID です。ログは `/config/audio-sidecar.log` に書かれます。

## 録画映像配信（7002/tcp）

Google Cast 向けに、録画の HLS プレイリストとセグメントをサイドカー経由で配信します。

- `GET http://<このアドオンのホスト>:7002/api/recorded/{録画ID}/video.m3u8?quality=720p`
- 対応品質: `720p`、`720p-hevc`
- 録画 ID は KonomiTV の録画番組 API（`/api/videos`）の `id` です
- HLS セグメント URL は再生ごとの不透明なセッショントークンを含み、同じ 7002 番ポートへ相対パスでアクセスします
- KonomiTV の視聴セッションは再生アクセス中に約3秒間隔で Keep-Alive され、アクセスが約8秒途絶えると破棄されます
- 未完了録画は `409`、存在しない ID またはファイルは `404`、KonomiTV 接続エラーは `502` を返します

再生 URL には LAN から到達できるアドオンのホスト名または IP アドレスを指定してください。

## KonomiTV 録画一覧・ライブ映像（7002/tcp）

録画一覧 API はクエリを KonomiTV へ転送し、JSON をそのまま返します。

- `GET http://<このアドオンのホスト>:7002/api/videos?order=desc&page=1&ids=1,2`
- 上流へ接続できない場合は `502` を返します

ライブ映像は KonomiTV の MPEG-TS をそのまま中継する経路と、同梱 FFmpeg で HLS に変換する経路があります。Google Cast 向けには HLS を使います。

- `GET http://<このアドオンのホスト>:7002/api/streams/live/{チャンネルID}/video.ts?quality=720p`
- `GET http://<このアドオンのホスト>:7002/api/streams/live/{チャンネルID}/video.m3u8?quality=720p`
- 対応品質: `720p`、`720p-hevc`
- TS の MIME は `video/mp2t`、HLS プレイリストの MIME は `application/vnd.apple.mpegurl` です。チャンネルが存在しない場合は `404`、不正な品質は `400`、上流へ接続できない場合は `502` を返します
- HLS は再エンコードせず、FFmpeg の `-c copy` で約3秒の MPEG-TS セグメントを生成します。playlist の初回生成には最大60秒待ちます
- HLS セッションはクライアント・チャンネル・品質ごとに分離され、playlist の再取得では既存セッションを再利用します。無通信が約8秒続くと FFmpeg と一時ファイルを解放し、セグメント配信中にクライアントが切断した場合も解放します

Cast からアクセスする場合は、LAN から到達できるアドオンのホスト名または IP アドレスを指定してください。
