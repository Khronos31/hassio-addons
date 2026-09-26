# danything/denpa 1.22.1。本体とチューナーエージェントを1つのアドオンで動かす。
# Q3U4 / MLT5 / DTV02A などはエージェント側の px4-userland。
ARG DENPA_VERSION=1.22.1
FROM ghcr.io/danything/denpa-agent:${DENPA_VERSION} AS agent
FROM ghcr.io/danything/denpa:${DENPA_VERSION}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates pcscd pcsc-tools libccid libpcsclite1 libusb-1.0-0 procps \
    && curl -fsSL -o /tmp/libaribb25.deb \
        https://github.com/tsukumijima/libaribb25/releases/download/v0.2.10/libaribb25_0.2.10_amd64.deb \
    && apt-get install -y --no-install-recommends /tmp/libaribb25.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/libaribb25.deb

COPY --from=agent /usr/local/bin/denpa-agent /usr/local/bin/denpa-agent
COPY --from=agent /opt/px4-userland /opt/px4-userland
COPY --from=agent /opt/siano-userland /opt/siano-userland
COPY run.sh /run.sh
COPY ingress.js /ingress.js
RUN chmod 755 /run.sh /usr/local/bin/denpa-agent

WORKDIR /app
ENTRYPOINT []
CMD ["/run.sh"]
