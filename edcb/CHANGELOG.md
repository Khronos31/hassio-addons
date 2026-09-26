# Changelog

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
