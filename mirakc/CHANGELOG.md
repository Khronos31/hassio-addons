# Changelog

## 0.2.5

- px4-userland 対応機種を全16モデルに拡充（Q3U4 / Q3PE4 / Q3PE5 / W3U4 / W3PE4 / W3PE5 / MLT5PE / MLT8PE3 / MLT8PE5 / DTV02A-5TS-P / DTV02A-4TS-P / M1UR / S1UR / DTV03A-1TU / DTV02-1T1S-U / DTV02A-1T1S-U）
- 検出を px4-detect に刷新し、モデル名と識別子を出力するように変更
- `config.yml.template` に全16モデル分のチューナー定義を追加。`generate-effective-config.py` と `px4-ts-stream` を機種別の受信機割り当てに対応
- 1ブリッジ機の px4d ready 判定を `usb-present-mask=0x01` に対応（従来は 0x03 固定で MLT5 系がタイムアウトしていた）
- reader config の `@PX4_ACCESS@` プレースホルダを置換するよう修正（px4-userland v0.1.6 のテンプレート変更で Q3U4 が起動できなくなっていた）

## 0.2.4

- 同梱の siano-userland を v0.1.6（`ad9bc7361288e9c188a1d8235ab946ac8b7bd6ac`）へ更新
- 同梱の px4-userland を v0.1.6（`3477301c09578d6c0d85f381c1448a5c53157a68`）へ更新

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
