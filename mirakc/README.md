# mirakc

[mirakc](https://github.com/mirakc/mirakc) の Home Assistant アドオンです。
地上デジタル USB チューナー PX-S1UD を、同梱の [siano-ts](https://github.com/Khronos31/siano-userland) で開きます。
B-CAS 復号は [recisdb](https://github.com/kazuki0824/recisdb-rs) です。

Home Assistant OS には Siano のカーネルモジュールが無いので、ユーザ空間だけで受信します。

## 用意するもの

- PLEX PX-S1UD（USB ID `3275:0080`）1本以上。HA 機へ直結またはハブ
- 有料放送を解くなら B-CAS カードと PC/SC リーダ（SCR3310 など）

録画の予約と保存は [EPGStation アドオン](../epgstation) が担当します。

## 設定

初回起動で `/addon_configs/<リポジトリID>_mirakc/config.yml` にテンプレートがコピーされます。
チャンネルとチューナー本数はそこを編集してください。構成タブに項目はありません。

EPGStation の `mirakurunPath` は、同じ HA 上なら次です。

```
http://<HA の IP>:40772/
```

amd64 でのみ確認しています。
