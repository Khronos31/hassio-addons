# xtne6f/EDCB の Unix 版。Lua 5.2 が要るので Debian を使う。
# Home Assistant のベースイメージは Alpine で、この依存は入らない。
# ピンは 2026-09-04 の work-plus-s（ebf50c7）と
# matching/BonDriver_LinuxMirakc の cfbefc6。
FROM debian:bookworm-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        git \
        liblua5.2-dev \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf lua5.2/lua.h /usr/include/lua.h \
    && ln -sf lua5.2/lauxlib.h /usr/include/lauxlib.h \
    && ln -sf lua5.2/lualib.h /usr/include/lualib.h

ARG EDCB_COMMIT=ebf50c730ccf8c1732e0bd8a4e2a3417a94d9b2b
ARG BONDRIVER_COMMIT=cfbefc6d21dab4009db5f124984c1b720b76d869

RUN set -eux; \
    git init -q /src/edcb; \
    git -C /src/edcb remote add origin https://github.com/xtne6f/EDCB.git; \
    git -C /src/edcb fetch -q --depth 1 origin "$EDCB_COMMIT"; \
    git -C /src/edcb checkout -q --detach FETCH_HEAD; \
    test "$(git -C /src/edcb rev-parse HEAD)" = "$EDCB_COMMIT"; \
    make -C /src/edcb/Document/Unix -j"$(nproc)"; \
    make -C /src/edcb/Document/Unix install; \
    mkdir -p /var/local/edcb; \
    make -C /src/edcb/Document/Unix setup_ini; \
    mkdir -p /usr/share/edcb; \
    cp -a /var/local/edcb /usr/share/edcb/seed; \
    rm -f /usr/share/edcb/seed/EpgTimerSrv.ini; \
    git init -q /src/bon; \
    git -C /src/bon remote add origin https://github.com/matching/BonDriver_LinuxMirakc.git; \
    git -C /src/bon fetch -q --depth 1 origin "$BONDRIVER_COMMIT"; \
    git -C /src/bon checkout -q --detach FETCH_HEAD; \
    test "$(git -C /src/bon rev-parse HEAD)" = "$BONDRIVER_COMMIT"; \
    git -C /src/bon submodule update --init --depth 1; \
    make -C /src/bon -j"$(nproc)"; \
    install -d /usr/local/lib/edcb; \
    install -m 0755 /src/bon/BonDriver_LinuxMirakc.so /usr/local/lib/edcb/BonDriver_LinuxMirakc.so; \
    cp -a /usr/local/lib/edcb/BonDriver_LinuxMirakc.so /usr/local/lib/edcb/BonDriver_LinuxMirakc_T.so; \
    cp -a /usr/local/lib/edcb/BonDriver_LinuxMirakc.so /usr/local/lib/edcb/BonDriver_LinuxMirakc_S.so

COPY BonDriver_S1UD.cpp /BonDriver_S1UD.cpp
RUN g++ -std=c++17 -fPIC -shared -o /usr/local/lib/edcb/BonDriver_S1UD.so /BonDriver_S1UD.cpp -pthread

FROM debian:bookworm-slim AS tuners

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        libpcsclite-dev \
        libusb-1.0-0-dev \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY tuner/ /tmp/tuner/

RUN set -eux; \
    siano_tag_object='5e584d18f95884362b4df6cf02c8215fb02b551b'; \
    siano_resolved_commit='ad9bc7361288e9c188a1d8235ab946ac8b7bd6ac'; \
    px4_tag_object='0c72e5281252b412879c527f637b9da39cb85f58'; \
    px4_resolved_commit='3477301c09578d6c0d85f381c1448a5c53157a68'; \
    recisdb_deb='https://github.com/kazuki0824/recisdb-rs/releases/download/1.2.4/recisdb_1.2.4-1_amd64.deb'; \
    recisdb_sha256='0ec83fc5d3779d95156265bda1af6ef0ca7d5b7db37e59dfa8bb17ced6a36f2a'; \
    siano_firmware_url='https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/isdbt_rio.inp?id=e981caea6ed33c48d25b7dbf473327dbd01df163'; \
    siano_firmware_size='85840'; \
    siano_firmware_sha256='054520642d5d09cb7ab7d08dbd6fd9ba9365de56adf2e7d7d06927f9845ff818'; \
    git init -q /tmp/siano; \
    git -C /tmp/siano remote add origin https://github.com/Khronos31/siano-userland.git; \
    git -C /tmp/siano fetch -q --no-tags --depth 1 origin "$siano_tag_object"; \
    test "$(git -C /tmp/siano rev-parse "$siano_tag_object^{commit}")" = "$siano_resolved_commit"; \
    git -C /tmp/siano checkout -q --detach "$siano_resolved_commit"; \
    make -C /tmp/siano CC=gcc PKG_CONFIG=pkg-config; \
    install -m 0755 /tmp/siano/siano-ts /usr/local/bin/siano-ts; \
    curl -fsSL -o /tmp/isdbt_rio.inp "$siano_firmware_url"; \
    test "$(wc -c < /tmp/isdbt_rio.inp)" -eq "$siano_firmware_size"; \
    printf '%s  %s\n' "$siano_firmware_sha256" /tmp/isdbt_rio.inp | sha256sum -c -; \
    install -D -m 0644 /tmp/isdbt_rio.inp /lib/firmware/isdbt_rio.inp; \
    git init -q /tmp/px4; \
    git -C /tmp/px4 remote add origin https://github.com/Khronos31/px4-userland.git; \
    git -C /tmp/px4 fetch -q --no-tags --depth 1 origin "$px4_tag_object"; \
    test "$(git -C /tmp/px4 rev-parse "$px4_tag_object^{commit}")" = "$px4_resolved_commit"; \
    git -C /tmp/px4 checkout -q --detach "$px4_resolved_commit"; \
    cmake -S /tmp/px4 -B /tmp/px4-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DPX4_BUILD_TESTS=OFF \
        -DPX4_ENABLE_LIBUSB=ON \
        -DPX4_BUILD_PCSC_IFD=ON \
        -DPX4_REQUIRE_PCSC_IFD=ON; \
    cmake --build /tmp/px4-build --target px4d px4-ts px4ctl px4_ifdhandler; \
    install -m 0755 /tmp/px4-build/px4d /usr/local/bin/px4d; \
    install -m 0755 /tmp/px4-build/px4-ts /usr/local/bin/px4-ts; \
    install -m 0755 /tmp/px4-build/px4ctl /usr/local/bin/px4ctl; \
    install -D -m 0755 /tmp/px4-build/libpx4-userland-ifd.so /usr/lib/px4-userland/libpx4-userland-ifd.so; \
    curl -fsSL -o /tmp/recisdb.deb "$recisdb_deb"; \
    printf '%s  %s\n' "$recisdb_sha256" /tmp/recisdb.deb | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/recisdb.deb; \
    install -m 0755 /tmp/tuner/px-s1ud-stream /tmp/tuner/px4-ts-stream /usr/local/bin/; \
    mkdir -p /usr/local/src; \
    install -m 0644 /tmp/recisdb.deb /usr/local/src/recisdb.deb

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        jq \
        liblua5.2-0 \
        libusb-1.0-0 \
        libpcsclite1 \
        libccid \
        pcscd \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/EpgTimerSrv /usr/local/bin/EpgDataCap_Bon /usr/local/bin/
COPY --from=tuners /usr/local/bin/siano-ts /usr/local/bin/px-s1ud-stream /usr/local/bin/px4d /usr/local/bin/px4-ts /usr/local/bin/px4ctl /usr/local/bin/px4-ts-stream /usr/local/bin/
COPY --from=tuners /lib/firmware/isdbt_rio.inp /lib/firmware/isdbt_rio.inp
COPY --from=tuners /usr/local/src/recisdb.deb /tmp/recisdb.deb
COPY --from=tuners /usr/lib/px4-userland /usr/lib/px4-userland
RUN apt-get update \
    && apt-get install -y --no-install-recommends /tmp/recisdb.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/recisdb.deb
COPY --from=build /usr/local/lib/edcb /usr/local/lib/edcb
COPY --from=build /usr/share/edcb/seed /usr/share/edcb/seed
COPY run.sh /run.sh
COPY chscan.sh /chscan.sh
RUN chmod 755 /run.sh /chscan.sh /usr/local/bin/EpgTimerSrv /usr/local/bin/EpgDataCap_Bon

ENTRYPOINT []
CMD ["/run.sh"]
