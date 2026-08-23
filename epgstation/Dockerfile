FROM l3tnun/epgstation:v2.10.0-debian

# ⚠️ 上流のイメージには ffmpeg も ffprobe も入っていない。
#    無いと変換が全部 HTTP 500 で落ちるが、無変換のライブ視聴だけは通るので
#    気づきにくい。intel-media-va-driver は VAAPI で焼きたいとき用。
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        intel-media-va-driver \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    # ⚠️ EPGStation の内部既定値もテンプレートも /usr/local/bin を指しているが、
    #    Debian の ffmpeg パッケージは /usr/bin へ入る。リンクを張って上流の既定値を
    #    そのまま正解にする。こうしないと config.yml 側で毎回書き直す羽目になる。
    #    実行ファイルのリンクだけで動くことは実機で確認済み（RPATH を持たず、
    #    共有ライブラリは ld.so の既定パスで解決されるため）。
    && ln -sf /usr/bin/ffmpeg  /usr/local/bin/ffmpeg \
    && ln -sf /usr/bin/ffprobe /usr/local/bin/ffprobe

COPY run.sh /run.sh
RUN chmod 755 /run.sh

ENTRYPOINT []
CMD ["/run.sh"]
