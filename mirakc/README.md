# mirakc

[mirakc](https://github.com/mirakc/mirakc) の Home Assistant アドオンです。
地上デジタル USB チューナー PX-S1UD と、地上/BS/CS チューナー PX-Q3U4 を、同梱の
[siano-userland](https://github.com/Khronos31/siano-userland) と
[px4-userland](https://github.com/Khronos31/px4-userland) で開きます。
B-CAS 復号は [recisdb](https://github.com/kazuki0824/recisdb-rs) です。

Home Assistant OS のカーネルドライバに依存せず、ユーザ空間だけで受信します。

## 用意するもの

- PLEX PX-S1UD（USB ID `3275:0080`）1本以上。HA 機へ直結またはハブ
- PLEX PX-Q3U4（USB ID `0511:084a` の2台1組、任意）
- 復号には B-CAS カードが必要です。PX-Q3U4 は本体カードスロットを利用でき、PX-S1UD のみなら外付け PC/SC リーダ（SCR3310 など）が必要です

録画の予約と保存は [EPGStation アドオン](../epgstation) が担当します。

## 設定

初回起動で `/addon_configs/<リポジトリID>_mirakc/config.yml` にテンプレートがコピーされます。
同梱テンプレートは関東の地デジと最小限のBS/CSだけを載せた例です。受信地域と受信環境に
合わせて `channels` を編集してください。構成タブに項目はありません。

mirakc の `jobs.scan-services` は、`channels` に記載済みの物理チャンネル内からサービスを
見つける機能であり、受信可能なRFチャンネル自体を探索する機能ではありません。このアドオンの
同梱ラッパーが受け付ける表記は、地デジが `T13`〜`T62`、BSが奇数トランスポンダを
`BS01_0` のように表す形式、CSが偶数の `CS2`〜`CS24` です。表記として有効でも、その地域や
受信設備で放送中・受信可能とは限りません。手作業で受信可能な一覧を設定すれば、mirakcは
その各項目に対してサービスとEPGをスキャンします。詳細は
[upstream mirakcのchannels設定](https://github.com/mirakc/mirakc/blob/main/docs/config.md#channels)を参照してください。

PX-Q3U4 を検出し、`it930x-firmware.bin` の有効なキャッシュがない場合だけ、PLEX の
Web サイトへ HTTPS 接続して公式ドライバZIPを取得します。ZIP、内部のSYS、生成物を固定の
サイズと SHA-256 で検証し、固定版 `fwtool` で生成したファームウェアだけを
`/addon_configs/<リポジトリID>_mirakc/it930x-firmware.bin` に永続キャッシュします。
以後、有効なキャッシュがあればネットワークへ接続しません。PLEX サイトへの接続、取得、
展開、検証のいずれかが失敗した場合は fail-closed で PX-Q3U4 を無効化し、PX-S1UD だけで
起動を続けます。公式ZIP、SYS、生成ファームウェアはアドオンイメージに同梱していません。

EPGStation の `mirakurunPath` は、同じ HA 上なら次です。

```
http://<HA の IP>:40772/
```

amd64 で、PX-Q3U4 の地デジ・BS/CS受信、B-CAS復号、8受信系の列挙・割当、
地デジ4系統同時受信、BS/CS 4系統同時受信、終了処理、および PX-S1UD 2台との併用を確認済みです。
