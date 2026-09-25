# KonomiTV 0.14.1。公式 Dockerfile は CUDA と GPU ドライバ一式を入れる。
# まずは FFmpeg で起動できる Ubuntu 22.04 に、リリース同梱のサードパーティだけ載せる。
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Tokyo \
    LANG=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libfontconfig1 \
        libfreetype6 \
        libfribidi0 \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

ARG KONOMI_COMMIT=0a32188274b81c1e7bed642474b208bd2a543a6b

RUN set -eux; \
    curl -fsSL -o /tmp/thirdparty-linux.tar.xz \
        https://github.com/tsukumijima/KonomiTV/releases/download/v0.14.1/thirdparty-linux.tar.xz; \
    mkdir -p /code/server; \
    tar -C /code/server -xf /tmp/thirdparty-linux.tar.xz; \
    test -x /code/server/thirdparty/Python/bin/python; \
    git init -q /src; \
    git -C /src remote add origin https://github.com/tsukumijima/KonomiTV.git; \
    git -C /src fetch -q --depth 1 origin "$KONOMI_COMMIT"; \
    git -C /src checkout -q --detach FETCH_HEAD; \
    test "$(git -C /src rev-parse HEAD)" = "$KONOMI_COMMIT"; \
    cp -a /src/server/. /code/server/; \
    test -f /code/server/pyproject.toml; \
    cd /code/server; \
    ./thirdparty/Python/bin/python -m poetry env use ./thirdparty/Python/bin/python; \
    ./thirdparty/Python/bin/python -m poetry install --only main --no-root; \
    mkdir -p /code/client; \
    cp -a /src/client/dist /code/client/dist; \
    rm -rf /src /tmp/thirdparty-linux.tar.xz

COPY config.default.yaml /code/config.default.yaml
COPY run.sh /run.sh
COPY ingress_proxy.py /ingress_proxy.py
RUN chmod 755 /run.sh /ingress_proxy.py

WORKDIR /code/server
ENTRYPOINT []
CMD ["/run.sh"]
