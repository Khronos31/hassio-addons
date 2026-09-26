# Changelog

## 0.1.7

- Q3U4 系の内蔵カードスロットを pcscd に登録（recisdb の B-CAS 復号が動くように）
- `[TVTEST]` へ Px4 BonDriver を自動登録（KonomiTV のライブ視聴で Q3U4 系を使えるように）
- BS/CS の標準チャンネル一覧を同梱し、地上波スキャンとマージするようにした
- TCP 4510 を公開（KonomiTV / TVTest が LAN から接続できる）
- DOCS を「設定ファイルはここ、内容は本家ドキュメント参照」の構成に書き直し

## 0.1.6

- px4-userland 対応機種を全16モデルに拡充（Q3U4 / Q3PE4 / Q3PE5 / W3U4 / W3PE4 / W3PE5 / MLT5PE / MLT8PE3 / MLT8PE5 / DTV02A-5TS-P / DTV02A-4TS-P / M1UR / S1UR / DTV03A-1TU / DTV02-1T1S-U / DTV02A-1T1S-U）
- 検出を px4-detect に刷新し、機種名と識別子を出力するように変更
- BonDriver_Px4 と px4-ts-stream を機種別の受信機割り当てに対応
- 初回チャンネルスキャン完了後に EpgTimerSrv を再起動してチャンネル一覧を読み込むよう修正（初回の EPG 取得が失敗する問題）

## 0.1.5

- USB に CCID カードリーダーが無いときは decode を自動で無効化
  （B-CAS カード不在で recisdb が即終了し、スキャンが0局になるのを防ぐ）

## 0.1.4

- decode=false のとき BonDriver_S1UD / _Px4 が recisdb を通さず TS を素通しするよう修正
  （B-CAS カード不在時は recisdb が即終了し、チャンネルスキャンが0局になっていた）

## 0.1.3

- px4d のランタイムディレクトリを 0700 に設定（px4d が起動しない問題の修正）

## 0.1.2

- PX-Q3U4 / PX-MLT5PE 系を直接開く BonDriver_Px4_T / _S を追加
- 起動時に px4 機材を検出して px4d を起動し、EpgTimerSrv.ini の本数を自動設定
- チャンネルスキャンは px4 検出時に BonDriver_Px4_T を使うように変更

## 0.1.1

- 同梱の siano-userland を v0.1.6 へ更新
- 同梱の px4-userland を v0.1.6 へ更新

## 0.1.0

- initial release
