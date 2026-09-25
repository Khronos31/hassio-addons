# Changelog

## 0.2.3

- PX-MLT5PE（`0511:024e`）と DTV02A-5TS-P（`0511:924e`）を 1 台として検出する。識別子は 15 桁の USB serial
- 新しい `config.yml` には受信機 0–4 の兼用チューナーを入れる。既存の `config.yml` は書き換えない
- Q3U4 と MLT5 系が同時に見えるときは、どちらも起動しない

## 0.2.2

- 同梱の px4-userland を v0.1.4（`7ec828578db47db4ed2a1b247d4c24fb722aedde`）へ更新
- 自動検出して開くのは、これまでどおり PX-Q3U4 の 1 組。PX-MLT5PE と DTV02A-5TS-P は同梱バイナリには含まれるが、このアドオンはまだ選ばない

## 0.2.1

- 物理チャンネルは地域・受信環境に合わせて手動設定し、`jobs.scan-services` は設定済みチャンネル内のサービスだけをスキャンすることを明記
- テンプレート内の関東地デジと最小限のBS/CS項目が設定例であることをコメントに明記

## 0.2.0

- siano-userland と px4-userland を固定ソース付きで同梱
- PX-Q3U4 検出時に、PLEX の公式ドライバから固定ハッシュ検証付きでファームウェアを生成し、アドオン設定領域へ永続キャッシュ
- 取得または検証に失敗した場合は、既存キャッシュを保護し PX-S1UD のみで継続
- nns779/px4_drv v0.2.1 の fwtool、fwinfo.tsv、固定ソース、GPL-2.0 ライセンスを同梱

## 0.1.3

- Ingress とサイドバーを外した。UI は EPGStation。mirakc はホストの 40772 だけ

## 0.1.2

- 起動時に PX-S1UD へファームを入れてから mirakc を起こす（スキャン 10 秒窓に間に合わせる）

## 0.1.1

- siano-ts が MPEG-TS を 188 バイト境界で出す（URB 端数でスキャンが空になるのを止める）
- recisdb は tuner command ではなく decode-filter。EPG ジョブは生 TS を読む

## 0.1.0

- 初版。mirakc 3.4.82-debian に siano-ts と recisdb 1.2.4 を同梱
