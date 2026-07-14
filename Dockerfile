# ベースは公式prebuilt(fork元 addon-vscode/amd64)を直接指定。build.yaml(deprecated)を廃止し
# build パラメータをここへ inline した。amd64専用なので固定でよい。upstream追随はこのタグを bump する。
# hadolint ignore=DL3006
FROM ghcr.io/hassio-addons/vscode/amd64:6.0.1

# ===== SCS Forge (self-hosted) — 公式prebuiltイメージへの追記 =====
# 目的②(PATH一元化)は init-env が構成タブの additional_path＋固定STANDARDから /etc/environment と
# /etc/scs-env.sh に組む方式へ移行（環境依存パスをイメージに焼かない）。よって ENV PATH は置かない。

# 目的③: リビルドで消える apt ツールを単一RUNで焼き込み（update先頭1回・lists最後にrm）。
#   ブラウザは Debian の純FOSS chromium 一本（Google Chrome は積まない・2026-07-15 決定）。
#   ※chromium 150.0.7871.46 は Debian cherry-pick バグで headless クラッシュしたが .100 で修正済み。
#     apt はビルド時の現行版（修正版）を引く。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        file x11-utils fonts-noto-cjk libusb-1.0-0 \
        clang cppcheck lua5.4 chromium \
        openssh-server \
    && rm -rf /var/lib/apt/lists/*

# phase 2: rootfs（sshd の s6 サービス・sshd_config 等）を上書きコピー。
# 公式rootfsはprebuiltに既に入っているので実質うちの追加分（init-sshd/sshd/sshd_config/user有効化）が入る。
COPY rootfs /
