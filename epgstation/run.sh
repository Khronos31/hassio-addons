#!/bin/sh
# EPGStation を Home Assistant のアドオンとして起動する。
#
# チューナーは Home Assistant OS では扱えないので、mirakc / Mirakurun は別のマシンに
# 置き、ここからは HTTP で問い合わせるだけにする。EPGStation 自身はチューナーに触らない。
set -eu

OPTIONS=/data/options.json
mirakurun=$(jq -r '.mirakurun_url // ""' "$OPTIONS")
recorded=$(jq -r '.recorded_path // "/media/EPGStation"' "$OPTIONS")

if [ -z "$mirakurun" ]; then
    echo "mirakurun_url が空です。構成タブで mirakc / Mirakurun の URL を入れてください。"
    echo "  例: http://192.168.1.10:40772"
    exit 1
fi

# 録画物・サムネイル・データベースは /media と /data へ置く。
# コンテナは更新のたびに作り直されるので、/app の下に残すと消える。
mkdir -p "$recorded" /data/epgstation /data/thumbnail
if [ ! -L /app/data ]; then
    rm -rf /app/data
    ln -s /data/epgstation /app/data
fi

# ⚠️ 同梱のフロントエンドは socket.io の接続先を
#      location.protocol + "//" + location.hostname + ":" + socketIOPort
#    と組み立てる。パスは location.pathname から導くのに、ポートだけ静的な設定値を使う。
#    ingress の下ではブラウザから見えるポートが経路で変わる（宅内は Home Assistant の
#    8123、Home Assistant Cloud 経由なら 443）ので、設定値ひとつでは両立しない。
#    同一オリジンへ繋ぐよう配信バンドルを書き換える。ポートを直接開いて使う場合も
#    同一オリジンになるだけなので、害はない。
patch_client_socketio() {
    target=$(find / -maxdepth 6 -name 'app.*.js' -path '*/js/*' 2>/dev/null | head -1)
    [ -n "$target" ] || { echo "client bundle not found; socket.io left as shipped"; return; }
    grep -q 'location.protocol+"//"+location.hostname+":"+' "$target" || {
        echo "socket.io origin pattern not found in $(basename "$target"); left as shipped"
        return
    }
    sed -i 's|location.protocol+"//"+location.hostname+":"+e.socketIOPort|location.origin|g' "$target"
    echo "patched $(basename "$target") to use the page origin for socket.io"
}
patch_client_socketio

# ⚠️ 設定は同梱テンプレを土台にして、必要な所だけ差し替える。
#    最小構成を手書きすると stream: ブロックごと落ちて、/api/config の
#    isEnableTSLiveStream が false になり「放映中」タブが消える。
#    どこが効いているか分からない塊は、削るより残す方が安い。
sed \
    -e "s|^mirakurunPath: .*|mirakurunPath: ${mirakurun}/|" \
    -e "s|^ffmpeg: .*|ffmpeg: /usr/bin/ffmpeg|" \
    -e "s|^ffprobe: .*|ffprobe: /usr/bin/ffprobe|" \
    -e "s|%ROOT%/recorded|${recorded}|g" \
    -e "s|%ROOT%/thumbnail|/data/thumbnail|g" \
    /app/config/config.yml.template > /app/config/config.yml

# ⚠️ この値は使われない。上の patch_client_socketio でクライアントを
#    location.origin へ繋ぐよう書き換えているため。
#    それでも書くのは、EPGStation が HTTPS で来た要求に対して「自前の https 設定が
#    無い」と 500 (httpsConfigError) を投げるのを止めるため。Home Assistant Cloud
#    経由は HTTPS で届くので、これが無いと /api/config が落ち、画面は出るのに
#    socket.io だけ初期化できず IOIsNull になる。
sed -i "/^port: 8888/a clientSocketioPort: 8888" /app/config/config.yml

# ⚠️ subDirectory は設定しない。
#    ingress は /api/hassio_ingress/<token>/ を剥がしてから転送するので、
#    アプリから見えるパスは / から始まる。ここで接頭辞を足すと socket.io の
#    待受パスがずれて繋がらなくなる。
#    ブラウザ側の接頭辞は location.pathname から自動で導かれる。

# ログ設定と変換スクリプトはテンプレから。無いと起動しない。
for name in operatorLogConfig epgUpdaterLogConfig serviceLogConfig; do
    [ -f "/app/config/${name}.yml" ] || cp "/app/config/${name}.sample.yml" "/app/config/${name}.yml" 2>/dev/null || true
done
[ -f /app/config/enc.js ] || cp /app/config/enc.js.template /app/config/enc.js 2>/dev/null || true

echo "mirakurun: ${mirakurun} / recorded: ${recorded}"
cd /app
exec node dist/index.js
