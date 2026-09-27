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

