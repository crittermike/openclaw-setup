#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenClaw on DigitalOcean + Telegram — Automated Setup
# ============================================================
# Usage:
#   export DO_TOKEN="your-digitalocean-api-token"
#   export TELEGRAM_BOT_TOKEN="your-telegram-bot-token"
#   ./setup.sh
#
# AI Provider (pick one):
#   - GitHub Copilot (default): No extra key needed. The script
#     will pause for an interactive device-login flow.
#   - Anthropic/OpenAI: set AI_PROVIDER and AI_API_KEY:
#       export AI_PROVIDER="anthropic"  # or "openai"
#       export AI_API_KEY="sk-..."
#
# Optional:
#   export COPILOT_MODEL="github-copilot/claude-opus-4.6"  # default model
#   export DROPLET_SIZE="s-2vcpu-2gb"  # default: s-1vcpu-2gb
#   export DROPLET_REGION="nyc1"       # default: nyc1
#   export DROPLET_NAME="openclaw"     # default: openclaw
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Pre-flight checks ---
command -v doctl >/dev/null 2>&1 || error "doctl is not installed. Run: brew install doctl"
command -v ssh   >/dev/null 2>&1 || error "ssh is not available"

[[ -z "${DO_TOKEN:-}" ]]           && error "Set DO_TOKEN (DigitalOcean API token)"
[[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && error "Set TELEGRAM_BOT_TOKEN (from @BotFather)"

# AI provider config: default to GitHub Copilot (no key needed)
AI_PROVIDER="${AI_PROVIDER:-github-copilot}"
AI_API_KEY="${AI_API_KEY:-}"
COPILOT_MODEL="${COPILOT_MODEL:-github-copilot/claude-opus-4.6}"
DROPLET_SIZE="${DROPLET_SIZE:-s-1vcpu-2gb}"
DROPLET_REGION="${DROPLET_REGION:-nyc1}"
DROPLET_NAME="${DROPLET_NAME:-openclaw}"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

# --- Step 1: Authenticate doctl ---
info "Authenticating with DigitalOcean..."
doctl auth init --access-token "$DO_TOKEN" 2>/dev/null

# --- Step 2: Ensure SSH key exists and is registered ---
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  info "Generating SSH key..."
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
fi

SSH_KEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_KEY_PATH.pub" -E md5 | awk '{print $2}' | sed 's/MD5://')
SSH_KEY_NAME="openclaw-setup-key"

# Check if key already registered
if ! doctl compute ssh-key list --format FingerPrint --no-header | grep -q "$SSH_KEY_FINGERPRINT"; then
  info "Registering SSH key with DigitalOcean..."
  doctl compute ssh-key import "$SSH_KEY_NAME" --public-key-file "$SSH_KEY_PATH.pub"
fi

SSH_KEY_ID=$(doctl compute ssh-key list --format ID,FingerPrint --no-header | grep "$SSH_KEY_FINGERPRINT" | awk '{print $1}')

# --- Step 3: Create the Droplet ---
info "Creating DigitalOcean Droplet ($DROPLET_SIZE in $DROPLET_REGION)..."

# Check if droplet already exists
EXISTING_DROPLET=$(doctl compute droplet list --format Name,ID --no-header | grep "^${DROPLET_NAME} " | awk '{print $2}' || true)
if [[ -n "$EXISTING_DROPLET" ]]; then
  warn "Droplet '$DROPLET_NAME' already exists (ID: $EXISTING_DROPLET). Using existing droplet."
  DROPLET_ID="$EXISTING_DROPLET"
else
  DROPLET_ID=$(doctl compute droplet create "$DROPLET_NAME" \
    --image ubuntu-24-04-x64 \
    --size "$DROPLET_SIZE" \
    --region "$DROPLET_REGION" \
    --ssh-keys "$SSH_KEY_ID" \
    --tag-names "openclaw" \
    --wait \
    --format ID --no-header)
  info "Droplet created (ID: $DROPLET_ID)"
fi

# Get the IP address
DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
info "Droplet IP: $DROPLET_IP"

# --- Step 4: Wait for SSH to be ready ---
info "Waiting for SSH to become available..."
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PATH" root@"$DROPLET_IP" "echo ok" 2>/dev/null; then
    break
  fi
  sleep 5
done

# --- Step 5: Install OpenClaw on the Droplet ---
info "Installing OpenClaw on the droplet..."

ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" bash <<'REMOTE_INSTALL'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo ">>> Updating system..."
apt-get update -qq && apt-get upgrade -y -qq

echo ">>> Installing Node.js 22..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
fi
echo "Node version: $(node --version)"

echo ">>> Installing OpenClaw..."
if ! command -v openclaw &>/dev/null; then
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
fi
echo "OpenClaw version: $(openclaw --version)"

echo ">>> Installation complete!"
REMOTE_INSTALL

# --- Step 6: Configure OpenClaw with AI provider and Telegram ---
info "Configuring OpenClaw (AI provider: $AI_PROVIDER, Telegram channel)..."

if [[ "$AI_PROVIDER" == "github-copilot" ]]; then
  # Check if Copilot is already authenticated on the droplet
  COPILOT_AUTHED=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" \
    "grep -q 'github-copilot' /root/.openclaw/openclaw.json 2>/dev/null && echo yes || echo no")

  if [[ "$COPILOT_AUTHED" == "yes" ]]; then
    info "GitHub Copilot already authenticated — skipping device login."
  else
    info "==> GitHub Copilot auth requires an interactive device login."
    info "==> You will see a URL and a code. Open the URL in your browser and enter the code."
    echo ""
    ssh -t -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" \
      "openclaw models auth login-github-copilot"
    echo ""
  fi

  info "Setting default model to $COPILOT_MODEL and gateway mode..."
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" bash <<REMOTE_COPILOT_CONFIG
set -euo pipefail
openclaw config set agents.defaults.model.primary "$COPILOT_MODEL"
openclaw config set gateway.mode local
REMOTE_COPILOT_CONFIG

else
  # Traditional API key provider (anthropic / openai)
  [[ -z "$AI_API_KEY" ]] && error "AI_PROVIDER=$AI_PROVIDER requires AI_API_KEY to be set"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" bash <<REMOTE_APIKEY_CONFIG
set -euo pipefail
openclaw config set ai.provider "$AI_PROVIDER"
openclaw config set ai.api_key "$AI_API_KEY"
REMOTE_APIKEY_CONFIG
fi

# Configure Telegram channel directly in config file
info "Adding Telegram channel..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" bash <<REMOTE_TELEGRAM
set -euo pipefail

# Install jq if not present for safe JSON manipulation
command -v jq &>/dev/null || apt-get install -y -qq jq

CONFIG_FILE="/root/.openclaw/openclaw.json"

# Merge Telegram channel config into existing config
jq --arg token "$TELEGRAM_BOT_TOKEN" '
  .channels.telegram = {
    "enabled": true,
    "botToken": \$token,
    "dmPolicy": "pairing",
    "groupPolicy": "open"
  } |
  .gateway.mode = "local"
' "\$CONFIG_FILE" > "\${CONFIG_FILE}.tmp" && mv "\${CONFIG_FILE}.tmp" "\$CONFIG_FILE"

echo "Telegram channel configured in \$CONFIG_FILE"
REMOTE_TELEGRAM

# Install and enable the systemd daemon
info "Installing and starting OpenClaw daemon..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" bash <<'REMOTE_DAEMON'
set -euo pipefail

# Ensure linger is enabled so user services run without a login session
loginctl enable-linger root

# Only install if not already installed
if [[ ! -f /root/.config/systemd/user/openclaw-gateway.service ]]; then
  openclaw daemon install
fi

# Export runtime dir for systemctl --user over non-interactive SSH
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

systemctl --user daemon-reload
systemctl --user enable openclaw-gateway
systemctl --user restart openclaw-gateway

# Brief pause then check status
sleep 2
echo ">>> OpenClaw service status:"
systemctl --user is-active openclaw-gateway && echo "RUNNING" || echo "NOT RUNNING"
echo ">>> Configuration complete!"
REMOTE_DAEMON

# --- Step 7: Configure firewall ---
info "Setting up firewall..."

# Check if firewall already exists
FW_ID=$(doctl compute firewall list --format Name,ID --no-header | grep "^openclaw-fw " | awk '{print $2}' || true)
if [[ -z "$FW_ID" ]]; then
  doctl compute firewall create \
    --name "openclaw-fw" \
    --droplet-ids "$DROPLET_ID" \
    --inbound-rules "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0" \
    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0" \
    --format ID --no-header >/dev/null
  info "Firewall created (SSH-only inbound)"
else
  warn "Firewall 'openclaw-fw' already exists."
fi

# --- Step 8: Verify everything is running ---
info "Verifying OpenClaw is running..."

ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" root@"$DROPLET_IP" bash <<'REMOTE_VERIFY'
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

echo "=== OpenClaw Status ==="
systemctl --user is-active openclaw-gateway && echo "Service: RUNNING" || echo "Service: NOT RUNNING"
echo ""

echo "=== Configured Channels ==="
timeout 10 openclaw channels list 2>/dev/null || echo "(could not list channels)"
echo ""

echo "=== Logs (last 20 lines) ==="
journalctl --user -u openclaw-gateway --no-pager -n 20 2>/dev/null || true
REMOTE_VERIFY

echo ""
echo "============================================================"
info "🎉 OpenClaw is deployed and connected to Telegram!"
echo "============================================================"
echo ""
echo "  Droplet IP:   $DROPLET_IP"
echo "  SSH:          ssh -i $SSH_KEY_PATH root@$DROPLET_IP"
echo "  Dashboard:    ssh -L 18789:localhost:18789 -i $SSH_KEY_PATH root@$DROPLET_IP"
echo "                then visit http://localhost:18789"
echo ""
echo "  Telegram:     Message your bot on Telegram — it should respond!"
echo ""
echo "  Useful commands (on the droplet):"
echo "    openclaw status                              # check status"
echo "    openclaw channels list                       # list connected channels"
echo "    openclaw logs -f                             # follow live logs"
echo "    systemctl --user restart openclaw-gateway    # restart the service"
echo ""
