# KonomiTV

視聴画面です。番組表・予約・放送波は EDCB から取ります。

サイドバーの KonomiTV から開きます。Ingress は内部の HTTP（7011）へ中継し、画面の `/assets` に Ingress のパスを足します。7000 番の HTTPS はコンテナの中だけで、ホストには開いていません。

## 録画ファイル

`/media` は読み書きで入っています。どのディレクトリに置くかは `/addon_configs/<リポジトリID>_konomitv/config.yaml` の `video.recorded_folders` です。初期値は `/media/EDCB` です。

Docker の中だと、書いたパスの先頭に `/host-rootfs` が付きます。`/host-rootfs` はコンテナ自身へのリンクなので、`/media/EDCB` とそのまま同じ場所です。

## EDCB

初回起動時、`config.yaml` の `edcb_url` は自分のホスト名から作ります。このアドオンが `local-konomitv` なら `tcp://local-edcb:4510/`、リポジトリから入れた `<リポジトリID>-konomitv` なら `tcp://<リポジトリID>-edcb:4510/` です。別の場所の EDCB を使うときは、この行を書き換えます。

EDCB の SrvPipe FIFO は、そのホスト名の `-` を `_` にした設定フォルダを `/var/local/edcb` として見ます。

放送波を mirakc から受けるときは、`always_receive_tv_from_mirakurun` を true にし、`mirakurun_url` に `http://<リポジトリID>-mirakc:40772/` を書きます。
