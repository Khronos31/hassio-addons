#!/bin/sh
# EPGStation を Home Assistant のアドオンとして起動する。
#
# チューナーは Home Assistant OS では扱えないので、mirakc / Mirakurun は別のマシンに
# 置き、ここからは HTTP で問い合わせるだけにする。EPGStation 自身はチューナーに触らない。
#
# 設定は上流と同じく config.yml をそのまま書いてもらう。置き場所は
#   /addon_configs/<リポジトリID>_epgstation/config.yml
# EPGStation が読む /app/config/config.yml はここへのシンボリックリンクなので、
# 上流の fs.watchFile による再読込もそのまま効く。
#
# ⚠️ ingress のための3キーだけは、起動のたびにこのファイルへ書き戻す。壊しても
#    アドオンを再起動すれば直る。
set -eu

USER_CFG=/config/config.yml        # addon_config マウント。設定の正本
APP_CFG=/app/config/config.yml     # 上流がハードコードしている読み込み先

# ---------------------------------------------------------------- 初回だけ生成
# ⚠️ 土台は同梱テンプレを丸ごと使う。最小構成を手書きすると stream: ブロックごと
#    落ちて、/api/config の isEnableTSLiveStream が false になり「放映中」タブが
#    消える。どこが効いているか分からない塊は、削るより残す方が安い。
if [ ! -f "$USER_CFG" ]; then
    echo "config.yml がないのでテンプレートから作ります: ${USER_CFG}"
    {
        cat <<'HEADER'
# EPGStation の設定。全キーの説明は上流のマニュアルを参照:
#   https://github.com/l3tnun/EPGStation/blob/v2.10.0/doc/conf-manual.md
#
# port / clientSocketioPort / subDirectory はアドオンが起動のたびに固定します。
# mirakurunPath を自分の mirakc / Mirakurun へ向けてください。
HEADER
        sed -e "s|%ROOT%/recorded|/media/EPGStation|g" \
            -e "s|%ROOT%/thumbnail|/data/thumbnail|g" \
            /app/config/config.yml.template
    } > "$USER_CFG"
fi

ln -sfn "$USER_CFG" "$APP_CFG"

# ------------------------------------------------------- ingress のための3キー
# ⚠️ 書き換えは USER_CFG を直接指す。sed -i をシンボリックリンクに当てると、
#    リンクを実ファイルで置き換えてしまう（GNU sed の既定動作）。
#
# ⚠️ clientSocketioPort の値自体は使われない。下の patch_client_socketio が
#    クライアントを location.origin へ繋ぐよう書き換えているため。それでも書くのは、
#    EPGStation が HTTPS で来た要求に「自前の https 設定が無い」と 500
#    (httpsConfigError) を返すのを止めるため。Home Assistant Cloud 経由は HTTPS で
#    届くので、これが無いと /api/config が落ち、画面は出るのに socket.io だけ
#    初期化できず IOIsNull になる。
# ⚠️ 注記は行末に置く。独立した行にすると、ユーザーがキー行だけ消したときに
#    注記が孤児として残り、追記のたびに増えていく。
NOTE='  # ingress のためアドオンが固定します。変更しても起動時に書き戻されます'
force_key() {
    key=$1
    val=$2
    line="${key}: ${val}${NOTE}"
    if ! grep -qE "^${key}:" "$USER_CFG"; then
        printf '%s\n' "$line" >> "$USER_CFG"
        echo "config.yml に ${key}: ${val} を追記しました" >&2
        return 0
    fi
    [ "$(grep -m1 -E "^${key}:" "$USER_CFG")" = "$line" ] && return 0
    # 値が違うときだけ知らせる。注記が付いていないだけなら黙って揃える。
    current=$(grep -m1 -E "^${key}:" "$USER_CFG" | sed -e "s|^${key}:[[:space:]]*||" -e "s|[[:space:]]*#.*$||")
    [ "$current" = "$val" ] || echo "config.yml の ${key} を ${current} から ${val} に戻しました" >&2
    sed -i "s|^${key}:.*|${line}|" "$USER_CFG"
}
force_key port 8888
force_key clientSocketioPort 8888

# ⚠️ subDirectory は「設定しない」が正しい値。ingress は
#    /api/hassio_ingress/<token>/ を剥がしてから転送するので、アプリから見えるパスは
#    / から始まる。接頭辞を足すと socket.io の待受パスがずれて繋がらなくなる。
#    ブラウザ側の接頭辞は location.pathname から導かれる。
if grep -qE "^subDirectory:" "$USER_CFG"; then
    sed -i '/^subDirectory:/d' "$USER_CFG"
    echo "config.yml の subDirectory を削除しました（ingress のため設定できません）" >&2
fi

# ------------------------------------------------------------------ 保存先の用意
# データベースとサムネイルは /data へ置く。コンテナは更新のたびに作り直されるので、
# /app の下に残すと消える。録画先は config.yml の recorded から読む（複数可）。
mkdir -p /data/epgstation /data/thumbnail
awk '/^recorded:/{f=1;next} f&&/^[^[:space:]]/{f=0}
     f&&/^[[:space:]]*path:/{
         sub(/^[[:space:]]*path:[[:space:]]*/,"");
         gsub(/^['"'"'"]|['"'"'"]$/,"");
         gsub(/%ROOT%/,"/app");
         print}' "$USER_CFG" \
  | while read -r dir; do
        [ -n "$dir" ] && mkdir -p "$dir"
    done

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

# ログ設定と変換スクリプトはテンプレから。無いと起動しない。
for name in operatorLogConfig epgUpdaterLogConfig serviceLogConfig; do
    [ -f "/app/config/${name}.yml" ] || cp "/app/config/${name}.sample.yml" "/app/config/${name}.yml" 2>/dev/null || true
done
[ -f /app/config/enc.js ] || cp /app/config/enc.js.template /app/config/enc.js 2>/dev/null || true

echo "設定: ${USER_CFG}"
cd /app
exec node dist/index.js
