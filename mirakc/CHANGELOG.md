# Changelog

## 0.1.2

- 起動時に PX-S1UD へファームを入れてから mirakc を起こす（スキャン 10 秒窓に間に合わせる）

## 0.1.1

- siano-ts が MPEG-TS を 188 バイト境界で出す（URB 端数でスキャンが空になるのを止める）
- recisdb は tuner command ではなく decode-filter。EPG ジョブは生 TS を読む

## 0.1.0

- 初版。mirakc 3.4.82-debian に siano-ts と recisdb 1.2.4 を同梱
