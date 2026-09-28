# Changelog

## 0.14.1.3

- 7002/tcp に録画 HLS ファサード（`/api/recorded/{録画ID}/video.m3u8?quality=720p`）を追加。プレイリストとセグメントをサイドカー経由で配信し、上流セッションの Keep-Alive（約3秒間隔）と無通信約8秒後の解放を代行
- 7002/tcp に録画一覧 API の透過プロキシ（`/api/videos`）とライブ映像（`/api/streams/live/{チャンネルID}/video.ts?quality=720p`）を追加
- ライブ映像の raw TS が Cast で再生できなかったため、ライブ HLS（`/api/streams/live/{チャンネルID}/video.m3u8?quality=720p`）を追加。同梱 FFmpeg の stream copy で MPEG-TS セグメントを生成
- サイドカーの上流 API 接続先を `http://127.0.0.77:7010` に修正（7000 は Akebi の HTTPS リダイレクトのため）

## 0.14.1.2

- 音声だけ配信サイドカー（`audio_sidecar.py`）を追加。7002/tcp で録画・ライブの MP3 ストリームを配信（Home Assistant Media Source 用）
- 同梱 FFmpeg（`/code/server/thirdparty/FFmpeg/ffmpeg.elf`）で変換する。KonomiTV 本体は無改修

## 0.14.1.1

- バージョン表記を「上流バージョン + アドオン改訂」（`0.14.1.1`）に変更
- コード変更なし。同梱の KonomiTV は 0.14.1（最新）のまま

## 0.1.2

- `recorded_folders` の初期値を `/media/DTV/EDCB` と `/media/DTV/KonomiTV-Capture` に変更

## 0.1.1

- 7000/tcp を公開（LAN から直接 KonomiTV を開ける）
- `mirakurun_url` のホストを初回起動時に自動で入れる（EDCB と同じホスト名導出）
- DOCS を「設定ファイルはここ、内容は本家ドキュメント参照」の構成に書き直し

## 0.1.0

- initial release
