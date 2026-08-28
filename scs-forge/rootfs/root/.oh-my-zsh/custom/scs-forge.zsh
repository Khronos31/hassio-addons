# SCS Forge (self-hosted): 対話ログインでホームにいるときだけ作業ディレクトリへ移る。
# 固定ではなく“柔らかいデフォルト”: 非対話(ssh scs cmd)や、明示的に別ディレクトリにいる/cd した
# 場合は邪魔しない。着地先は init-env が config_path から export した SCS_WORKDIR（既定 /config）。
# oh-my-zsh が custom/*.zsh を自動 source するのでここに置く（upstream の .zshrc は触らない）。
if [[ -o interactive && "$PWD" == "$HOME" ]]; then
    cd "${SCS_WORKDIR:-/config}" 2>/dev/null || true
fi
