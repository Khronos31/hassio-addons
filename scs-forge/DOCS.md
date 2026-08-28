# Studio Code Server (self-hosted)

SCS Forge runs [code-server](https://github.com/coder/code-server) inside a
Home Assistant add-on, so that a Home Assistant configuration can be edited in
a browser. It inherits the standard Studio Code Server add-on behavior from
the upstream project and adds the configuration described below.

## Base options

```yaml
log_level: info
config_path: /config
packages: []
init_commands: []
```

- `log_level`: add-on logging level. The default is `info`.
- `config_path`: initial code-server workspace. Use a specific directory such
  as `/config`; never use `/`, which causes code-server to index the whole
  container filesystem.
- `packages`: additional Debian packages installed when the add-on starts.
  They increase startup time and are not retained in the image.
- `init_commands`: shell commands run at each add-on start. They run with the
  add-on's privileges, so use only trusted commands.

## SCS Forge options

```yaml
authorized_keys: []
allowed_ips: []
additional_path: []
env_vars: []
```

### `authorized_keys`

SSH public keys permitted for root login. SSH remains unavailable unless this
and `allowed_ips` are both configured. Use public keys only; never place a
private key in add-on configuration.

### `allowed_ips`

IP addresses or CIDR ranges allowed to reach the SSH service. Keep this list
as narrow as possible. The mapped SSH port must never be exposed to the public
internet.

### `additional_path`

Absolute directories prepended to `PATH` for the integrated terminal and SSH
sessions. Use this to expose persistent tools installed outside the ephemeral
add-on filesystem.

### `env_vars`

Name/value pairs added to the integrated terminal and SSH environments. Do not
put credentials in add-on configuration unless you accept that Home Assistant
will store them there.

## Published ports

| Container port | Default host port | Purpose |
| --- | ---: | --- |
| `22/tcp` | `8022` | SSH, key-only and source-restricted when configured. |
| `8765/tcp` | `18765` | CC Pocket Bridge WebSocket. |
| `3000/tcp` | `3000` | Antigravity Deck web UI. |
| `3500/tcp` | `3500` | Antigravity Deck API and WebSocket. |

Only publish ports required by services you operate, and restrict access to a
trusted LAN or an authenticated overlay network. The companion services behind
these ports are configured independently of SCS Forge.

## Resetting editor settings

If the base add-on's editor settings need to be restored, run
`reset-settings` from an integrated terminal, then reload the editor.

## Support

This fork is maintained independently. For SCS Forge-specific behavior, open
an issue in this repository. For code-server itself, consult the
[code-server project](https://github.com/coder/code-server). Upstream Home
Assistant Community Add-ons support channels cannot support this fork.

## License

SCS Forge is distributed under the [MIT License](LICENSE). It contains work
from the upstream Studio Code Server add-on by the Home Assistant Community
Add-ons project.
