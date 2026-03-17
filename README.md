# OpenClaw on DigitalOcean + Telegram

Automated setup script for deploying OpenClaw to a DigitalOcean Droplet
and connecting it to your Telegram bot.

## Prerequisites

1. **DigitalOcean API token** — [create one here](https://cloud.digitalocean.com/account/api/tokens)
2. **Telegram bot token** — create one by messaging @BotFather
3. **GitHub account with Copilot access** (default) — OR an Anthropic/OpenAI API key

## Quick Start

```bash
export DO_TOKEN="dop_v1_your_token_here"
export TELEGRAM_BOT_TOKEN="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"

./setup.sh
```

The script uses **GitHub Copilot** as the AI provider by default.
During setup it will pause and show a device-login URL + code — open it in your browser
and authorize with your GitHub account. No API key needed.

### Using Anthropic or OpenAI instead

```bash
export DO_TOKEN="dop_v1_your_token_here"
export TELEGRAM_BOT_TOKEN="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
export AI_PROVIDER="anthropic"   # or "openai"
export AI_API_KEY="sk-ant-your-key-here"

./setup.sh
```

### Optional overrides

```bash
export COPILOT_MODEL="github-copilot/gpt-5.4"  # default: github-copilot/claude-opus-4.6
export DROPLET_SIZE="s-2vcpu-2gb"               # default: s-1vcpu-2gb
export DROPLET_REGION="sfo3"                    # default: nyc1
```

## What the Script Does

1. Authenticates with DigitalOcean via `doctl`
2. Registers your SSH key (generates one if needed)
3. Creates an Ubuntu 24.04 Droplet
4. Installs Node.js 22 and OpenClaw
5. Authenticates with GitHub Copilot (interactive device login) — or configures Anthropic/OpenAI if specified
6. Connects your Telegram bot
7. Sets up a systemd service for auto-restart
8. Creates a firewall (SSH-only inbound)
9. Verifies everything is running

## After Setup

- **Message your Telegram bot** — it should respond via your AI provider
- **Access the dashboard** via SSH tunnel:
  ```bash
  ssh -L 18789:localhost:18789 root@<DROPLET_IP>
  # Then open http://localhost:18789
  ```

## Teardown

```bash
export DO_TOKEN="dop_v1_your_token_here"
doctl auth init --access-token "$DO_TOKEN"
doctl compute droplet delete openclaw --force
doctl compute firewall delete $(doctl compute firewall list --format Name,ID --no-header | grep openclaw-fw | awk '{print $2}') --force
```
