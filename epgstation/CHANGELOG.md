# 変更履歴

## 0.1.7

最初の公開。

- EPGStation v2.10.0 を Home Assistant のアドオンとして動かす
- ingress に対応（Home Assistant のログインの後ろに入り、Home Assistant Cloud 経由でも開ける）
- 上流のイメージに無い ffmpeg を足す
- socket.io を同一オリジンへ繋ぐようフロントエンドを書き換える
- ホストポート 8888 を開く（Android TV のクライアント向け。認証なし）
