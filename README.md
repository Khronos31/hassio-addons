# SCS Forge

SCS Forge is a self-hosted Home Assistant add-on based on
[hassio-addons/addon-vscode](https://github.com/hassio-addons/addon-vscode).
It provides Studio Code Server (code-server) for editing a Home Assistant
installation in the browser, with a few additions intended for a persistent,
self-hosted development environment:

- an extensible `PATH` and environment-variable configuration;
- optional key-only SSH access with an allowlist of source addresses;
- optional external ports for companion services such as CC Pocket Bridge and
  Antigravity Deck;
- a small set of runtime system dependencies, with heavyweight development
  tools installed on demand instead of baked into the image.

This is an independent, AMD64-only fork. It is not affiliated with, supported
by, or a drop-in replacement for the Home Assistant Community Add-ons project.

## Installation

1. In Home Assistant, open **Settings > Add-ons > Add-on Store**.
1. From the overflow menu, select **Repositories** and add:

   ```text
   https://github.com/Khronos31/scs-forge
   ```

1. Find **Studio Code Server (self-hosted)**, install it, then start it.
1. Open the add-on's Web UI through Home Assistant.

The add-on runs with broad access to the Home Assistant configuration and
selected Supervisor APIs. Treat it as a trusted administrator tool.

## Configuration

The base options (`log_level`, `config_path`, `packages`, and `init_commands`)
follow the upstream Studio Code Server add-on. SCS Forge adds the following:

| Option | Purpose |
| --- | --- |
| `authorized_keys` | SSH public keys allowed to log in as root. |
| `allowed_ips` | Source IP addresses or CIDRs permitted to use SSH. |
| `additional_path` | Absolute directories prepended to the terminal and SSH `PATH`. |
| `env_vars` | Additional environment variables supplied to the terminal and SSH sessions. |

SSH is not enabled merely by publishing port `22/tcp`: configure both
`authorized_keys` and a restrictive `allowed_ips` list first. Do not expose
this port directly to the public internet.

The optional `8765/tcp`, `3000/tcp`, and `3500/tcp` ports are intended for
locally trusted companion services. They are not authenticated by this add-on;
publish them only on a trusted LAN or an authenticated overlay network.

See [DOCS.md](DOCS.md) for the base configuration reference and operational
notes.

## Development

This repository is a Home Assistant add-on source tree. To test a local
checkout, make it available to the Supervisor as a local add-on repository,
then use the Home Assistant add-on UI or CLI to rebuild and restart the
add-on. The `config.yaml` version must be incremented for an add-on update to
be detected.

The Docker image is deliberately AMD64-only and inherits the upstream
`ghcr.io/hassio-addons/vscode/amd64` image. Update that base tag deliberately,
and test the resulting add-on before publishing a release.

## Upstream and license

SCS Forge contains and modifies work from
[Home Assistant Community Add-ons: Studio Code Server](https://github.com/hassio-addons/addon-vscode).
Upstream documentation and issue trackers do not provide support for this
fork. File SCS Forge-specific issues in this repository.

Distributed under the [MIT License](LICENSE).
