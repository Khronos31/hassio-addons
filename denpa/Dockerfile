# danything/denpa 1.28.0 の公式 AIO イメージ。本体とチューナーエージェントを
# 上流が対応を合わせて1コンテナにまとめ、HAOS アドオン向けに提供している。
ARG DENPA_VERSION=1.28.0
FROM ghcr.io/danything/denpa-aio:${DENPA_VERSION}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates procps tzdata jq python3 \
    && rm -rf /var/lib/apt/lists/*

# PX-M1UR / PX-S1UR のように同じ USB シリアルを名乗る筐体を denpa が個別に
# 扱えるよう、px4d / px4ctl を互換ラッパーへ差し替える。実体は別ディレクトリに
# 残し、ファームウェアと物理デバイスの経路は変えない。
COPY px4-compat/px4-wrapper.py /opt/px4-compat/px4-wrapper.py
RUN mkdir -p /opt/px4-compat-real \
    && mv /opt/px4-userland/px4d /opt/px4-compat-real/px4d \
    && mv /opt/px4-userland/px4ctl /opt/px4-compat-real/px4ctl \
    && cp /opt/px4-compat/px4-wrapper.py /opt/px4-userland/px4d \
    && cp /opt/px4-compat/px4-wrapper.py /opt/px4-userland/px4ctl \
    && chmod 755 /opt/px4-userland/px4d /opt/px4-userland/px4ctl

# BS/CS の標準チャンネル一覧。初回起動の seed に使う (地上波はスキャンで拾う)。
COPY seed/channels.bs.json /usr/share/denpa-addon/channels.bs.json

COPY run.sh /run.sh
RUN chmod 755 /run.sh

WORKDIR /app
ENTRYPOINT []
CMD ["/run.sh"]
