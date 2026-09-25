# PX-S1UD/PX-Q3U4 用 mirakc。recisdb が .deb のため Debian ベース。
# The Q3U4 vendor archive is never included.  At runtime a pinned GPL fwtool
# derives the firmware into the persistent add-on config volume after every
# input and output has passed the pinned size/SHA-256 manifest.
FROM docker.io/mirakc/mirakc:3.4.82-debian@sha256:26af4e0bdec9b0ef1e967c008cc5884b9daf978a3f556d7d3d19efcba4f4c140

USER root

COPY px-s1ud-stream px4-detect-q3u4 px4-ts-stream /usr/local/bin/
COPY generate-effective-config.py /usr/local/bin/generate-effective-config.py
COPY firmware-allowlist.txt px4-firmware-source.tsv /usr/share/mirakc-addon/
COPY px4-acquire-firmware /usr/local/bin/px4-acquire-firmware
COPY run.sh /run.sh
COPY config.yml.template /usr/share/mirakc-addon/config.yml.template
COPY LICENCE.siano /usr/share/doc/isdbt_rio.LICENCE.siano

RUN set -eux; \
    siano_tag_object='5e584d18f95884362b4df6cf02c8215fb02b551b'; \
    siano_resolved_commit='ad9bc7361288e9c188a1d8235ab946ac8b7bd6ac'; \
    px4_tag_object='0c72e5281252b412879c527f637b9da39cb85f58'; \
    px4_resolved_commit='3477301c09578d6c0d85f381c1448a5c53157a68'; \
    fwtool_version='v0.2.1'; \
    fwtool_commit='2b3f79b5bc5db56e8556bb28397f7d8f74b2adeb'; \
    recisdb_deb='https://github.com/kazuki0824/recisdb-rs/releases/download/1.2.4/recisdb_1.2.4-1_amd64.deb'; \
    recisdb_sha256='0ec83fc5d3779d95156265bda1af6ef0ca7d5b7db37e59dfa8bb17ced6a36f2a'; \
    siano_firmware_url='https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/isdbt_rio.inp?id=e981caea6ed33c48d25b7dbf473327dbd01df163'; \
    siano_firmware_size='85840'; \
    siano_firmware_sha256='054520642d5d09cb7ab7d08dbd6fd9ba9365de56adf2e7d7d06927f9845ff818'; \
    runtime_packages='libusb-1.0-0 pcscd libccid libpcsclite1 libstdc++6 libgcc-s1 ca-certificates curl python3 python3-yaml'; \
    build_packages='git gcc g++ libc6-dev make pkg-config cmake ninja-build libusb-1.0-0-dev libpcsclite-dev'; \
    apt-get update; \
    apt-get install -y --no-install-recommends $runtime_packages $build_packages; \
    apt-mark manual $runtime_packages; \
    mkdir -p /usr/share/mirakc-addon /usr/share/src /tmp/siano /tmp/px4 /tmp/px4-drv; \
    curl -fsSL -o /tmp/recisdb.deb "$recisdb_deb"; \
    printf '%s  %s\n' "$recisdb_sha256" /tmp/recisdb.deb | sha256sum -c -; \
    apt-get install -y --no-install-recommends /tmp/recisdb.deb; \
    git init -q /tmp/siano; \
    git -C /tmp/siano remote add origin https://github.com/Khronos31/siano-userland.git; \
    git -C /tmp/siano fetch -q --no-tags --depth 1 origin "$siano_tag_object"; \
    test "$(git -C /tmp/siano cat-file -t "$siano_tag_object")" = tag; \
    test "$(git -C /tmp/siano rev-parse "$siano_tag_object")" = "$siano_tag_object"; \
    test "$(git -C /tmp/siano rev-parse "$siano_tag_object^{commit}")" = "$siano_resolved_commit"; \
    git -C /tmp/siano checkout -q --detach "$siano_resolved_commit"; \
    test "$(git -C /tmp/siano rev-parse HEAD)" = "$siano_resolved_commit"; \
    curl -fsSL -o /tmp/isdbt_rio.inp "$siano_firmware_url"; \
    test "$(wc -c < /tmp/isdbt_rio.inp)" -eq "$siano_firmware_size"; \
    printf '%s  %s\n' "$siano_firmware_sha256" /tmp/isdbt_rio.inp | sha256sum -c -; \
    install -D -m 0644 /tmp/isdbt_rio.inp /lib/firmware/isdbt_rio.inp; \
    git init -q /tmp/px4; \
    git -C /tmp/px4 remote add origin https://github.com/Khronos31/px4-userland.git; \
    git -C /tmp/px4 fetch -q --no-tags --depth 1 origin "$px4_tag_object"; \
    test "$(git -C /tmp/px4 cat-file -t "$px4_tag_object")" = tag; \
    test "$(git -C /tmp/px4 rev-parse "$px4_tag_object")" = "$px4_tag_object"; \
    test "$(git -C /tmp/px4 rev-parse "$px4_tag_object^{commit}")" = "$px4_resolved_commit"; \
    git -C /tmp/px4 checkout -q --detach "$px4_resolved_commit"; \
    test "$(git -C /tmp/px4 rev-parse HEAD)" = "$px4_resolved_commit"; \
    git init -q /tmp/px4-drv; \
    git -C /tmp/px4-drv remote add origin https://github.com/nns779/px4_drv.git; \
    git -C /tmp/px4-drv fetch -q --no-tags --depth 1 origin "refs/tags/$fwtool_version"; \
    test "$(git -C /tmp/px4-drv rev-parse FETCH_HEAD)" = "$fwtool_commit"; \
    git -C /tmp/px4-drv checkout -q --detach "$fwtool_commit"; \
    test "$(git -C /tmp/px4-drv rev-parse HEAD)" = "$fwtool_commit"; \
    git -C /tmp/siano archive --format=tar --prefix=siano-userland/ "$siano_resolved_commit" \
        | tar -x -C /usr/share/src; \
    git -C /tmp/px4 archive --format=tar --prefix=px4-userland/ "$px4_resolved_commit" \
        | tar -x -C /usr/share/src; \
    git -C /tmp/px4-drv archive --format=tar --prefix=px4_drv-0.2.1/ "$fwtool_commit" \
        | tar -x -C /usr/share/src; \
    test ! -e /usr/share/src/px4-userland/firmware; \
    test ! -e /usr/share/src/px4_drv-0.2.1/fwtool/PXW3U4.sys; \
    test ! -e /usr/share/src/px4_drv-0.2.1/fwtool/it930x-firmware.bin; \
    make -C /tmp/siano CC=gcc PKG_CONFIG=pkg-config; \
    install -m 0755 /tmp/siano/siano-ts /usr/local/bin/siano-ts; \
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
    install -D -m 0755 /tmp/px4-build/libpx4-userland-ifd.so \
        /usr/lib/px4-userland/libpx4-userland-ifd.so; \
    install -D -m 0644 /tmp/px4/packaging/pcsc/reader.conf.d/px4-userland.conf.in \
        /usr/share/mirakc-addon/pcsc/reader.conf.d/px4-userland.conf.in; \
    make -C /tmp/px4-drv/fwtool; \
    install -D -m 0755 /tmp/px4-drv/fwtool/fwtool \
        /usr/libexec/mirakc-addon/px4-fwtool/fwtool; \
    install -m 0644 /tmp/px4-drv/fwtool/fwinfo.tsv \
        /usr/libexec/mirakc-addon/px4-fwtool/fwinfo.tsv; \
    install -D -m 0644 /tmp/px4-drv/LICENSE /usr/share/doc/px4_drv-fwtool/LICENSE; \
    chmod 0755 /run.sh /usr/local/bin/px-s1ud-stream /usr/local/bin/px4-detect-q3u4 /usr/local/bin/px4-ts-stream /usr/local/bin/generate-effective-config.py /usr/local/bin/px4-acquire-firmware; \
    dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort \
        > /usr/share/mirakc-addon/build-package-versions.txt; \
    { \
        printf '%s\n' \
            'manifest_version=1' \
            'base_image=docker.io/mirakc/mirakc:3.4.82-debian@sha256:26af4e0bdec9b0ef1e967c008cc5884b9daf978a3f556d7d3d19efcba4f4c140' \
            'siano_repository=https://github.com/Khronos31/siano-userland.git' \
            "siano_tag_object=$siano_tag_object" \
            "siano_resolved_commit=$siano_resolved_commit" \
            'px4_repository=https://github.com/Khronos31/px4-userland.git' \
            "px4_tag_object=$px4_tag_object" \
            "px4_resolved_commit=$px4_resolved_commit" \
            'fwtool_repository=https://github.com/nns779/px4_drv.git' \
            "fwtool_version=$fwtool_version" \
            "fwtool_commit=$fwtool_commit" \
            "recisdb_deb_url=$recisdb_deb" \
            "recisdb_deb_sha256=$recisdb_sha256" \
            "siano_firmware_url=$siano_firmware_url" \
            "siano_firmware_size=$siano_firmware_size" \
            "siano_firmware_sha256=$siano_firmware_sha256" \
            'siano_build=glibc/libusb' \
            'px4_build_type=Release' \
            'px4_build_tests=OFF' \
            'px4_enable_libusb=ON' \
            'px4_build_pcsc_ifd=ON' \
            'px4_require_pcsc_ifd=ON' \
            'source_siano=/usr/share/src/siano-userland' \
            'source_px4=/usr/share/src/px4-userland' \
            'source_fwtool=/usr/share/src/px4_drv-0.2.1' \
            'fwtool=/usr/libexec/mirakc-addon/px4-fwtool/fwtool' \
            'fwtool_info=/usr/libexec/mirakc-addon/px4-fwtool/fwinfo.tsv' \
            'fwtool_license=/usr/share/doc/px4_drv-fwtool/LICENSE' \
            'firmware_allowlist=/usr/share/mirakc-addon/firmware-allowlist.txt' \
            'firmware_source_manifest=/usr/share/mirakc-addon/px4-firmware-source.tsv' \
            'firmware_acquisition_helper=/usr/local/bin/px4-acquire-firmware' \
            'q3u4_firmware_payload=excluded' \
            'q3u4_vendor_archive=runtime-download-not-redistributed' \
            'siano_firmware=/lib/firmware/isdbt_rio.inp' \
            'siano_source_firmware=excluded' \
            'build_package_versions=/usr/share/mirakc-addon/build-package-versions.txt' \
            'runtime_package_versions=/usr/share/mirakc-addon/runtime-package-versions.txt' \
            'effective_config_helper=/usr/local/bin/generate-effective-config.py' \
            'effective_config_parser=python3-yaml' \
            'px4_ifd_library=/usr/lib/px4-userland/libpx4-userland-ifd.so' \
            'px4_reader_template=/usr/share/mirakc-addon/pcsc/reader.conf.d/px4-userland.conf.in'; \
    } > /usr/share/mirakc-addon/build-manifest.txt; \
    apt-get purge -y $build_packages; \
    apt-get autoremove -y; \
    dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort \
        > /usr/share/mirakc-addon/runtime-package-versions.txt; \
    rm -rf /tmp/recisdb.deb /tmp/isdbt_rio.inp /tmp/siano /tmp/px4 /tmp/px4-build /tmp/px4-drv; \
    rm -rf /var/lib/apt/lists/*

ENV TZ=Asia/Tokyo

ENTRYPOINT []
CMD ["/run.sh"]
