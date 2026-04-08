# CLIProxyAPI Using Codex on Claude

Windows-first local gateway for using OpenAI-compatible GPT/Codex models inside Claude via `CLIProxyAPI` and `cc-switch`.

This repository packages a pinned `CLIProxyAPI` build, a local Anthropic-compatible gateway, and a few one-click Windows launchers so the workflow stays simple:

1. Start the local gateway
2. Register the provider into `cc-switch`
3. Select the provider inside `cc-switch`
4. Open Claude

The project does not directly modify Claude settings. It only registers provider metadata into `cc-switch`.

## What This Project Includes

- Pinned `CLIProxyAPI` submodule at [`vendor/CLIProxyAPI`](./vendor/CLIProxyAPI)
- A Docker-based local gateway that exposes an Anthropic-compatible endpoint
- One-click `.bat` launchers for common Windows usage
- `cc-switch` provider registration scripts
- Basic gateway diagnostics for health, models, message calls, and tool roundtrips

## Current Status

Verified locally:

- Basic Claude-style message calls
- Non-streaming tool request / tool result roundtrip
- Streaming text
- Streaming tool calls
- `cc-switch` provider registration

Known limitation:

- Claude server-side `web_search_*` tools are not fully compatible yet because the Anthropic-to-OpenAI tool translation is still incomplete in the current pinned upstream

## Requirements

- Windows
- Docker Desktop
- PowerShell 7 (`pwsh`)
- Python 3
- `cc-switch`

Optional:

- A local `%USERPROFILE%\\.codex\\auth.json` with `OPENAI_API_KEY`, if you do not want to place the key in `.env`

If you cloned this repository from GitHub, initialize the pinned upstream first:

```bash
git submodule update --init --recursive
```

## Quick Start

### 1. Prepare config

Create a local `.env` based on [`.env.example`](./.env.example), then fill at least:

- `OPENAI_BASE_URL`
- `OPENAI_API_KEY`

You can keep the default local gateway values unless you need custom ports or image settings.

### 2. Start the gateway

Double-click [`quick-start-gateway.bat`](./quick-start-gateway.bat).

The first start may take a while because Docker needs to build the pinned image.

### 3. Register into cc-switch

Double-click [`quick-register-cc-switch.bat`](./quick-register-cc-switch.bat).

This only writes provider data into `cc-switch`. It does not auto-switch Claude.

### 4. Select the provider

Open `cc-switch` and manually select `CLIProxyAPI Claude` as the Claude provider.

### 5. Verify

Use either of these launchers when needed:

- [`quick-show-status.bat`](./quick-show-status.bat)
- [`quick-verify-compatibility.bat`](./quick-verify-compatibility.bat)

### 6. Stop

When finished, double-click [`quick-stop-gateway.bat`](./quick-stop-gateway.bat).

## One-Click Launchers

- [`quick-start-gateway.bat`](./quick-start-gateway.bat)
  Starts the local Dockerized gateway.
- [`quick-show-status.bat`](./quick-show-status.bat)
  Shows the current gateway URL, model status, and auth visibility.
- [`quick-verify-compatibility.bat`](./quick-verify-compatibility.bat)
  Runs health checks, model checks, Claude-style message checks, and tool roundtrip checks.
- [`quick-register-cc-switch.bat`](./quick-register-cc-switch.bat)
  Registers or updates the local provider in `cc-switch`.
- [`quick-stop-gateway.bat`](./quick-stop-gateway.bat)
  Stops and removes the local container.

## Configuration

Main files:

- [`.env.example`](./.env.example)
- [`config/cli-proxy-config.yaml`](./config/cli-proxy-config.yaml)
- [`docker/Dockerfile.cliproxyapi`](./docker/Dockerfile.cliproxyapi)

Important environment variables:

- `OPENAI_BASE_URL`
- `OPENAI_API_KEY`
- `CLI_PROXY_API_ENDPOINT`
- `CLI_PROXY_API_KEY`
- `CLI_PROXY_API_MANAGEMENT_KEY`
- `CLI_PROXY_API_PORT`
- `CLI_PROXY_API_HOST`

If `OPENAI_API_KEY` is empty and `CLI_PROXY_API_USE_LOCAL_CODEX_AUTH_JSON=true`, the startup script will also try `%USERPROFILE%\\.codex\\auth.json`.

## Manual Scripts

If you prefer PowerShell over the one-click launchers, the main entry points are:

- [`scripts/start-cliproxyapi.ps1`](./scripts/start-cliproxyapi.ps1)
- [`scripts/stop-cliproxyapi.ps1`](./scripts/stop-cliproxyapi.ps1)
- [`scripts/test-gateway-e2e.ps1`](./scripts/test-gateway-e2e.ps1)
- [`scripts/setup-claude-provider.ps1`](./scripts/setup-claude-provider.ps1)
- [`scripts/cc-switch/register-cc-switch-provider.ps1`](./scripts/cc-switch/register-cc-switch-provider.ps1)

## Repository Layout

- [`config/`](./config) static wrapper config
- [`docker/`](./docker) Docker build files
- [`scripts/`](./scripts) PowerShell, Python helpers, and launcher plumbing
- [`vendor/CLIProxyAPI`](./vendor/CLIProxyAPI) pinned upstream submodule

Runtime output is written to `.runtime/` and should not be committed.

## Security Notes

- Do not commit `.env`
- Do not commit `.runtime/`
- `.runtime/generated-config.yaml` may contain real upstream API keys
- Docker ports are now bound to `CLI_PROXY_API_HOST` and default to `127.0.0.1`
- Review [`config/cli-proxy-config.yaml`](./config/cli-proxy-config.yaml) before exposing the service outside localhost or a trusted LAN

## Pinned Upstream

- Upstream repository: `https://github.com/router-for-me/CLIProxyAPI`
- Pinned tag: `v6.9.16`
- Pinned commit: `c8b7e2b8d6f24462b724925dfe4f984ae6b9e302`

## Notes For Open Source Publishing

Before pushing to GitHub, double-check:

- `.env` is not staged
- `.runtime/` is not staged
- no real API key appears in screenshots, examples, or copied terminal output
- the remote-management configuration matches your intended exposure model
