# PX-S1UD 用 mirakc。recisdb が .deb のため Debian ベース。
# siano-ts は musl でもビルドできるが、このイメージでは glibc で同梱する。
FROM docker.io/mirakc/mirakc:3.4.82-debian

USER root

ARG SIANO_REF=v0.1.0
ARG RECISDB_DEB=https://github.com/kazuki0824/recisdb-rs/releases/download/1.2.4/recisdb_1.2.4-1_amd64.deb
ARG FIRMWARE_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/isdbt_rio.inp
ARG FIRMWARE_MD5=9b762c1808fd8da81bbec3e24ddb04a3

COPY px-s1ud-stream /usr/local/bin/px-s1ud-stream
COPY run.sh /run.sh
COPY config.yml.template /usr/share/mirakc-addon/config.yml.template
COPY LICENCE.siano /usr/share/doc/isdbt_rio.LICENCE.siano

RUN chmod 755 /usr/local/bin/px-s1ud-stream /run.sh \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gcc \
        libc6-dev \
        make \
        pkg-config \
        libusb-1.0-0 \
        libusb-1.0-0-dev \
        pcscd \
        libccid \
        libpcsclite1 \
    && curl -fsSL -o /tmp/recisdb.deb "$RECISDB_DEB" \
    && apt-get install -y --no-install-recommends /tmp/recisdb.deb \
    && git clone --depth 1 --branch "$SIANO_REF" \
         https://github.com/Khronos31/siano-userland.git /tmp/siano \
    && make -C /tmp/siano \
    && install -m 0755 /tmp/siano/siano-ts /usr/local/bin/siano-ts \
    && mkdir -p /lib/firmware \
    && curl -fsSL -o /lib/firmware/isdbt_rio.inp "$FIRMWARE_URL" \
    && echo "${FIRMWARE_MD5}  /lib/firmware/isdbt_rio.inp" | md5sum -c \
    && apt-get purge -y gcc libc6-dev make pkg-config libusb-1.0-0-dev git \
    && apt-get autoremove -y \
    && rm -rf /tmp/recisdb.deb /tmp/siano /var/lib/apt/lists/*

ENV PX_S1UD_FIRMWARE=/lib/firmware/isdbt_rio.inp \
    TZ=Asia/Tokyo

ENTRYPOINT []
CMD ["/run.sh"]
