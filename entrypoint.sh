#!/bin/bash
# OpenClaw Gateway Entrypoint
# This script ensures the gateway can start with proper configuration

# Don't use set -e: we want the script to continue even if
# intermediate commands (doctor, paste-token) report non-fatal errors
set +e

# Ensure HOME points to /data so ~/.openclaw resolves to /data/.openclaw
# This is critical: paste-token, doctor, and gateway all resolve auth paths from $HOME
export HOME=/data

# Keep gateway restarts in-process instead of handing off to an external
# supervisor. In a container the supervisor handoff makes PID 1 exit, which
# makes Coolify think the container stopped and restart it -> crash loop.
export OPENCLAW_NO_RESPAWN="${OPENCLAW_NO_RESPAWN:-1}"

# Create config directory if it doesn't exist
mkdir -p /data/.openclaw

# Handle gateway token - persist across restarts
# Try to use provided env var first
GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"

# If no env var, try to load from existing config
if [ -z "$GATEWAY_TOKEN" ] && [ -f "/data/.openclaw/openclaw.json" ]; then
    GATEWAY_TOKEN=$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' /data/.openclaw/openclaw.json | head -1 | cut -d'"' -f4)
fi

# If still empty, generate a new token
if [ -z "$GATEWAY_TOKEN" ]; then
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    echo "Generated new gateway token: $GATEWAY_TOKEN"
fi

export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"

# Build trusted proxies JSON array from environment variable
# Default includes common Docker gateway IPs and ranges
DEFAULT_PROXIES="loopback,linklocal,uniquelocal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
TRUSTED_PROXIES=${OPENCLAW_TRUSTED_PROXIES:-$DEFAULT_PROXIES}

# Convert comma-separated list to JSON array
PROXIES_JSON=$(echo "$TRUSTED_PROXIES" | sed 's/,/", "/g' | sed 's/^/["/' | sed 's/$/"]/')
echo "Trusted proxies: $PROXIES_JSON"

# Determine default model based on available API keys
DEFAULT_MODEL="anthropic/claude-sonnet-4-5"  # fallback
if [ -n "$ANTHROPIC_API_KEY" ] || [ -n "$OPENCLAW_ANTHROPIC_SETUP_TOKEN" ]; then
    DEFAULT_MODEL="anthropic/claude-sonnet-4-5"
elif [ -n "$GEMINI_API_KEY" ]; then
    DEFAULT_MODEL="google/gemini-3-pro-preview"
elif [ -n "$OPENAI_API_KEY" ]; then
    DEFAULT_MODEL="openai/gpt-4o"
elif [ -n "$OPENROUTER_API_KEY" ]; then
    DEFAULT_MODEL="openrouter/anthropic/claude-sonnet-4"
fi

# Allow an explicit override of the primary model regardless of which API key
# is present. Useful for custom OpenAI-compatible endpoints (OPENAI_BASE_URL),
# e.g. OPENCLAW_PRIMARY_MODEL=openai/gpt-4o-mini
if [ -n "$OPENCLAW_PRIMARY_MODEL" ]; then
    DEFAULT_MODEL="$OPENCLAW_PRIMARY_MODEL"
fi
echo "Default model: $DEFAULT_MODEL"

# Public URL for node onboarding / device pairing.
# Coolify auto-populates SERVICE_URL_<SERVICENAME> (magic env) once a domain is
# assigned to the service. Prefer an explicit OPENCLAW_PUBLIC_URL if provided.
PUBLIC_URL="${OPENCLAW_PUBLIC_URL:-${SERVICE_URL_OPENCLAWGATEWAY:-}}"
if [ -n "$PUBLIC_URL" ]; then
    echo "Public URL: $PUBLIC_URL"
fi

# Always regenerate config from environment variables to ensure
# current settings are applied (env vars are the source of truth)
SHOULD_REGENERATE=true
if [ -f "/data/.openclaw/openclaw.json" ]; then
    echo "Regenerating configuration from environment variables..."
else
    echo "No existing config found, creating new configuration"
fi

if [ "$SHOULD_REGENERATE" = true ]; then
    echo "Generating OpenClaw configuration..."

    # Build channels object dynamically
    CHANNELS_JSON="{"
    FIRST_CHANNEL=true

    # Add WhatsApp (always included)
    if [ "$FIRST_CHANNEL" = false ]; then
        CHANNELS_JSON="$CHANNELS_JSON,"
    fi
    CHANNELS_JSON="$CHANNELS_JSON\"whatsapp\":{\"allowFrom\":[],\"groups\":{\"*\":{\"requireMention\":true}}}"
    FIRST_CHANNEL=false

    # Add Telegram if token is provided
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        CHANNELS_JSON="$CHANNELS_JSON,\"telegram\":{\"enabled\":true,\"botToken\":\"$TELEGRAM_BOT_TOKEN\",\"groups\":{\"*\":{\"requireMention\":true}}}"
        echo "Configured Telegram channel"
    fi

    # Add Discord if token is provided
    if [ -n "$DISCORD_BOT_TOKEN" ]; then
        CHANNELS_JSON="$CHANNELS_JSON,\"discord\":{\"enabled\":true,\"token\":\"$DISCORD_BOT_TOKEN\",\"dm\":{\"policy\":\"pairing\"}}"
        echo "Configured Discord channel"
    fi

    # Add Slack if both tokens are provided
    if [ -n "$SLACK_BOT_TOKEN" ] && [ -n "$SLACK_APP_TOKEN" ]; then
        CHANNELS_JSON="$CHANNELS_JSON,\"slack\":{\"enabled\":true,\"botToken\":\"$SLACK_BOT_TOKEN\",\"appToken\":\"$SLACK_APP_TOKEN\",\"dm\":{\"policy\":\"pairing\"}}"
        echo "Configured Slack channel"
    fi

    CHANNELS_JSON="$CHANNELS_JSON}"

    # Gateway auth block. Newer OpenClaw REFUSES to bind to lan/0.0.0.0 with
    # auth.mode=none (unauthenticated network exposure). We always have a token
    # (from env or Coolify's SERVICE_PASSWORD_* magic env), so enable token
    # auth; only fall back to "none" if somehow no token is present.
    if [ -n "$GATEWAY_TOKEN" ]; then
        AUTH_JSON="{
      \"mode\": \"token\",
      \"token\": \"${GATEWAY_TOKEN}\"
    }"
        echo "Gateway auth: token mode enabled"
    else
        AUTH_JSON="{
      \"mode\": \"none\"
    }"
        echo "Gateway auth: none (no token available)"
    fi

    # Optionally wire the public URL into device-pair so pairing links/QRs
    # point at the real Coolify domain instead of localhost.
    PLUGINS_JSON=""
    if [ -n "$PUBLIC_URL" ]; then
        PLUGINS_JSON=",
  \"plugins\": {
    \"entries\": {
      \"device-pair\": {
        \"config\": {
          \"publicUrl\": \"${PUBLIC_URL}\"
        }
      }
    }
  }"
    fi

    # Create the complete config using current OpenClaw schema
    # - agents.defaults.model.primary replaces agent.model
    # - browser.cdpUrl replaces browser.controlUrl
    cat > /data/.openclaw/openclaw.json << EOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "${DEFAULT_MODEL}"
      },
      "workspace": "/data/openclaw"
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "${OPENCLAW_GATEWAY_BIND:-lan}",
    "port": ${OPENCLAW_GATEWAY_PORT:-18789},
    "auth": ${AUTH_JSON},
    "trustedProxies": ${PROXIES_JSON},
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true
    }
  },
  "channels": ${CHANNELS_JSON},
  "browser": {
    "enabled": ${OPENCLAW_BROWSER_ENABLED:-true},
    "cdpUrl": "${OPENCLAW_BROWSER_URL:-http://openclaw-browser:9222}"
  }${PLUGINS_JSON}
}
EOF
    echo "Config written to /data/.openclaw/openclaw.json"
else
    echo "Using existing configuration from /data/.openclaw/openclaw.json"
fi

# Run doctor --fix to clean up any legacy config keys before auth setup
# This prevents paste-token from failing on config validation
echo "Running doctor --fix to clean up config..."
node dist/index.js doctor --fix 2>&1 || echo "Note: doctor --fix reported issues (non-fatal)"

# Setup authentication using OpenClaw's native methods
echo "Configuring authentication..."

# Create agent directory structure (where OpenClaw reads auth-profiles.json)
AGENT_DIR="/data/.openclaw/agents/main/agent"
mkdir -p "$AGENT_DIR"

# Write .env to BOTH locations (root config dir + agent dir)
# OpenClaw docs: cat >> ~/.openclaw/.env <<'EOF' ANTHROPIC_API_KEY=... EOF
ROOT_ENV="/data/.openclaw/.env"
AGENT_ENV="$AGENT_DIR/.env"

# Clear previous .env files to avoid duplicates on restart
> "$ROOT_ENV"
> "$AGENT_ENV"

# Check if any auth is configured
HAS_AUTH=false

# Write API keys to both .env locations
if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" >> "$ROOT_ENV"
    echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" >> "$AGENT_ENV"
    echo "Configured Anthropic API key"
    HAS_AUTH=true
fi

if [ -n "$OPENAI_API_KEY" ]; then
    echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$ROOT_ENV"
    echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$AGENT_ENV"
    echo "Configured OpenAI API key"
    # Custom OpenAI-compatible endpoint (e.g. a self-hosted router / proxy)
    if [ -n "$OPENAI_BASE_URL" ]; then
        echo "OPENAI_BASE_URL=$OPENAI_BASE_URL" >> "$ROOT_ENV"
        echo "OPENAI_BASE_URL=$OPENAI_BASE_URL" >> "$AGENT_ENV"
        echo "Configured OpenAI base URL: $OPENAI_BASE_URL"
    fi
    HAS_AUTH=true
fi

if [ -n "$GEMINI_API_KEY" ]; then
    echo "GEMINI_API_KEY=$GEMINI_API_KEY" >> "$ROOT_ENV"
    echo "GEMINI_API_KEY=$GEMINI_API_KEY" >> "$AGENT_ENV"
    echo "Configured Gemini API key"
    HAS_AUTH=true
fi

if [ -n "$OPENROUTER_API_KEY" ]; then
    echo "OPENROUTER_API_KEY=$OPENROUTER_API_KEY" >> "$ROOT_ENV"
    echo "OPENROUTER_API_KEY=$OPENROUTER_API_KEY" >> "$AGENT_ENV"
    echo "Configured OpenRouter API key"
    HAS_AUTH=true
fi

# For setup-tokens, use the paste-token CLI command which writes the correct
# OAuth-based format to auth-profiles.json. Do NOT manually create the file.
# Ref: openclaw models auth paste-token --provider anthropic
if [ -n "$OPENCLAW_ANTHROPIC_SETUP_TOKEN" ]; then
    echo "Adding Anthropic setup-token via paste-token command..."
    echo "HOME=$HOME (~/.openclaw = $HOME/.openclaw)"
    echo "$OPENCLAW_ANTHROPIC_SETUP_TOKEN" | node dist/index.js models auth paste-token --provider anthropic 2>&1 || {
        echo "ERROR: paste-token command failed. Check token validity."
        echo "Generate a fresh token with: claude setup-token"
    }
    # Search for where auth-profiles.json was written
    echo "Searching for auth-profiles.json files..."
    find /data/.openclaw -name "auth-profiles.json" -type f 2>/dev/null | while read f; do
        echo "  Found: $f"
    done
    # Also check if it was written under the old HOME path
    find /home/openclaw -name "auth-profiles.json" -type f 2>/dev/null | while read f; do
        echo "  Found (old HOME): $f"
    done
    HAS_AUTH=true
fi

# Also handle CLAUDE_CODE_OAUTH_TOKEN if present
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    echo "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" >> "$ROOT_ENV"
    echo "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN" >> "$AGENT_ENV"
    echo "Configured Claude Code OAuth token"
    HAS_AUTH=true
fi

# Export API keys as environment variables for the process
export ANTHROPIC_API_KEY
export OPENAI_API_KEY
export OPENAI_BASE_URL
export GEMINI_API_KEY
export OPENROUTER_API_KEY
export CLAUDE_CODE_OAUTH_TOKEN

if [ "$HAS_AUTH" = false ]; then
    echo ""
    echo "=========================================="
    echo "WARNING: No API keys configured!"
    echo "=========================================="
    echo "Add one of these environment variables in Coolify:"
    echo "  - OPENCLAW_ANTHROPIC_SETUP_TOKEN - for Claude Pro/Max (run 'claude setup-token')"
    echo "  - ANTHROPIC_API_KEY - get from https://console.anthropic.com/settings/keys"
    echo "  - GEMINI_API_KEY - get from https://aistudio.google.com/apikey"
    echo "  - OPENAI_API_KEY - get from https://platform.openai.com/api-keys"
    echo "  - OPENROUTER_API_KEY - get from https://openrouter.ai/keys"
    echo "=========================================="
    echo ""
fi

# Verify auth status before starting gateway
echo "Verifying model authentication status..."
node dist/index.js models status 2>&1 || echo "Note: models status check completed (non-fatal)"

# Start the gateway with environment-variable-driven configuration.
# Pass --token explicitly when present so the gateway starts with auth
# (required: it refuses to bind to lan/0.0.0.0 unauthenticated).
GATEWAY_ARGS="gateway --bind ${OPENCLAW_GATEWAY_BIND:-lan} --port ${OPENCLAW_GATEWAY_PORT:-18789}"
if [ -n "$GATEWAY_TOKEN" ]; then
    exec node dist/index.js $GATEWAY_ARGS --token "$GATEWAY_TOKEN"
else
    exec node dist/index.js $GATEWAY_ARGS
fi
