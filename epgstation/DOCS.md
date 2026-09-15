# EPGStation

Mirakurun を使用した録画管理ソフト [EPGStation](https://github.com/l3tnun/EPGStation) の
Home Assistant アドオンです。

## 用意するもの

チューナーを持つ **mirakc** または **Mirakurun** が要ります。同じリポジトリの
[mirakc アドオン](../mirakc) を HAOS 上で動かしてもよいです。
カーネルモジュールが要る構成では、別の機械に置いて HTTP で問い合わせます。

## 設定

EPGStation の `config.yml` を直接編集します。置き場所は

```
/addon_configs/<リポジトリID>_epgstation/config.yml
```

初回起動時にテンプレートから作られるので、`mirakurunPath` を自分の mirakc / Mirakurun へ
向けてください。書式と全キーの説明は
[上流のマニュアル](https://github.com/l3tnun/EPGStation/blob/master/doc/conf-manual.md)
がそのまま使えます。

**構成タブに設定項目はありません。** EPGStation の設定は深さ6まで入れ子になっており、
アドオンの `schema` が扱える上限（深さ2）に収まらないためです。

### アドオンが固定するもの

`port` / `clientSocketioPort` / `subDirectory` の3つは、起動のたびに書き戻します。
変えると ingress の下で socket.io が繋がらなくなり、**画面は出るのに動かない**という
分かりにくい壊れ方をするためです。書き換えても、アドオンを再起動すれば元に戻ります。

### 置き場所

録画先は `recorded` に書きます。複数指定できます。`/media` か `/share` の下にしてください。
データベースとサムネイルはアドオンの `/data` に置かれるので、更新しても残ります。
`dropLog` や `recordedTmp` を使う場合も `/data` の下にすると更新後も残ります。

設定を壊すと EPGStation は起動しません。上流をそのまま使ったときと同じです。
ファイルを消せばテンプレートから作り直されます。アドオン更新後の起動時には、既存の
`config.yml` にも下記プロファイルを冪等に追記します。設定に問題がある場合は音声プロファイル移行で
元ファイルを変更せず、移行をスキップします。移行がスキップされてもEPGStationの
録画・通常起動は妨げませんが、Home Assistant向け音声プロファイルは利用できないため、
ログの警告を確認して対応形式の設定へ手動追記してください。

MP3プロファイルへ移行するときは、変更前の完全なバックアップを同じディレクトリへ
`config.yml.pre-mp3-audio-profile.bak` として保存します。既にバックアップがある場合は上書きしません。
以前のAACプロファイル移行で作られた `config.yml.pre-audio-profile.bak` があっても、そのファイルは保持します。
移行後に戻す場合は、まずアドオンを停止して移行前のアドオン版へ戻してください。新しい版を
先に起動すると、バックアップを戻しても音声プロファイルが再び移行されます。旧版へ戻した後、
停止したまま次を実行してMP3移行前のバックアップを config.yml へ戻し、その旧版を起動してください。

```sh
cp /addon_configs/<リポジトリID>_epgstation/config.yml.pre-mp3-audio-profile.bak \
   /addon_configs/<リポジトリID>_epgstation/config.yml
```

### Home Assistant Media Source の音声再生

初回起動時に作られる設定には、完成済み録画を音声専用で配信する2つのプロファイルが、
次の2か所へ自動で入ります。既存設定にも起動時に同じ2つを冪等移行します。

```yaml
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0?
                      -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k
                      -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000
                      -y -f mp4 pipe:1
        encoded:
            mp4:
                - name: Home Assistant Audio
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0?
                      -c:a aac -profile:a aac_low -ar 48000 -ac 2 -b:a 128k
                      -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000
                      -y -f mp4 pipe:1
```

互換用のAACプロファイルを残したまま、正本の音声プロファイルとしてMP3も追加します。
EPGStationの録画MP4 APIはMP3プロファイルを選んだ場合も `/mp4` の経路と
`Content-Type: video/mp4` ヘッダーを使います。実体はMP3なので、Home Assistantの統合側が
そのレスポンスを `audio/mpeg` として扱います。つまりAPIのパス／ヘッダーとメディア型が
一致しないのはアドオン側だけでは解消できません。
アドオン側のMP3移行と、音声メディアを受ける統合側の更新は同じリリース計画で行ってください。

```yaml
stream:
    recorded:
        ts:
            mp4:
                - name: Home Assistant Audio MP3
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -i pipe:0 -vn -sn -map 0:a:0?
                      -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1
        encoded:
            mp4:
                - name: Home Assistant Audio MP3
                  cmd: >-
                      %FFMPEG% -dual_mono_mode main -ss %SS% -i %INPUT% -vn -sn -map 0:a:0?
                      -c:a libmp3lame -ar 48000 -ac 2 -b:a 192k -f mp3 pipe:1
```

既存の `config.yml` も起動時に自動移行され、既存の映像プロファイルや他の設定は保持されます。
各プロファイルの断片ファイルは、構造上の理由で自動移行できない環境で手動確認・追記するときの
再利用用です。`mp4:` の配列内に追加し、EPGStation の置換規則により、TS 録画では
`pipe:0`（`%SS%` は空文字）、エンコード済み録画では `%INPUT%` と `%SS%`（再生位置秒）を使います。
AACプロファイルの `-frag_duration 1000000` は 1 秒の短い fMP4 fragment を指定し、映像キーフレームに
依存せず音声だけを連続出力します。MP3プロファイルは raw MP3 の連続出力なので、fMP4 fragment や
`-frag_duration` は使いません。

## 開き方

- **サイドバー** — Home Assistant のログインを通ります。Home Assistant Cloud 経由でも開けます
- **`http://<Home Assistant の IP>:8888`** — 認証はありません。ingress を使えない
  Android TV のクライアントなどはこちらから。要らなければ構成タブでポートを空欄にしてください

## 上流との違い

- **ffmpeg を同梱しています。** 上流のイメージには入っておらず、変換が失敗します。
  上流の既定値に合わせて `/usr/local/bin` からも引けるようにしてあるので、`ffmpeg` /
  `ffprobe` を設定で書き換える必要はありません
- **ingress の下で socket.io が繋がるよう、フロントエンドを起動時に書き換えます。**
  同梱のものは接続先のポートを設定値から作るため、経路によって食い違います

amd64 でのみ確認しています。
