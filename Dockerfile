# ベースは公式prebuilt(fork元 addon-vscode/amd64)を直接指定。build.yaml(deprecated)を廃止し
# build パラメータをここへ inline した。amd64専用なので固定でよい。upstream追随はこのタグを bump する。
# hadolint ignore=DL3006
FROM ghcr.io/hassio-addons/vscode/amd64:6.0.1

# ===== SCS Forge (self-hosted) — 公式prebuiltイメージへの追記 =====
# 目的②(PATH一元化)は init-env が構成タブの additional_path＋固定STANDARDから /etc/environment と
# /etc/scs-env.sh に組む方式へ移行（環境依存パスをイメージに焼かない）。よって ENV PATH は置かない。

# 目的③: リビルドで消える apt/dpkg ツールを単一RUNで焼き込み（update先頭1回・lists最後にrm）。
#   基本 + 重量級(apt) + chrome(Google公式.deb/dpkg)。chromeはamd64専用。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        file x11-utils fonts-noto-cjk libusb-1.0-0 \
        clang cppcheck lua5.4 chromium \
        openssh-server \
    && wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    && apt-get install -y --no-install-recommends /tmp/chrome.deb \
    && rm -f /tmp/chrome.deb \
    && rm -rf /var/lib/apt/lists/*

# phase 2: rootfs（sshd の s6 サービス・sshd_config 等）を上書きコピー。
# 公式rootfsはprebuiltに既に入っているので実質うちの追加分（init-sshd/sshd/sshd_config/user有効化）が入る。
COPY rootfs /
