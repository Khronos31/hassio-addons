FROM l3tnun/epgstation:v2.10.0-debian

# ⚠️ 上流のイメージには ffmpeg も ffprobe も入っていない。
#    無いと変換が全部 HTTP 500 で落ちるが、無変換のライブ視聴だけは通るので
#    気づきにくい。intel-media-va-driver は VAAPI で焼きたいとき用。
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        intel-media-va-driver \
        jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod 755 /run.sh

ENTRYPOINT []
CMD ["/run.sh"]
