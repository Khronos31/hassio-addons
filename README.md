# scs-forge — Studio Code Server (self-hosted)

公式 `hassio-addons/addon-vscode` をフォークした自作ローカルアドオン（slug `local_scs_forge`）のソース。
`FROM ghcr.io/hassio-addons/vscode/amd64:<ver>` の prebuilt イメージに、開発ツール焼き込み・PATH一元化・
LAN直SSH（root鍵のみ・接続元制限）を追加している。

## リポジトリ = source of truth / デプロイ

- このリポジトリ（`/config/GitHub/scs-forge`）が正。
- HA Supervisor が読むのは `/addons/scs-forge`（別実体のコピー）。
- デプロイ: `rsync -a --delete /config/GitHub/scs-forge/ /addons/scs-forge/`（`.git` は除外）してから
  `ha addons rebuild local_scs_forge`。config.yaml の schema/ports 変更時は version bump→`ha addons reload`→`update` が要る。

## 設計・経緯

`/config/.tools/claude-home/specs/scs-addon-phase1.md` / `phase2.md` / `scs-addon-env-config.md`、
`/config/.tools/claude-home/red-team/20260714-*.md` を参照。
