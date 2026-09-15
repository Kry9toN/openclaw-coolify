# OpenClaw Gateway - Optimized for Coolify Deployment
# https://github.com/openclaw/openclaw
#
# This Dockerfile builds a production-ready OpenClaw gateway with all
# required binaries baked in for persistent operation.

FROM node:26.8.2-trixie-slim

# Build arguments
ARG OPENCLAW_VERSION=latest
ARG TARGETARCH

# Labels for container identification
LABEL org.opencontainers.image.title="OpenClaw Gateway"
LABEL org.opencontainers.image.description="Personal AI Assistant - Gateway Service"
LABEL org.opencontainers.image.source="https://github.com/openclaw/openclaw"
LABEL org.opencontainers.image.vendor="OpenClaw"
LABEL org.opencontainers.image.licenses="MIT"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    socat \
    jq \
    ffmpeg \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun (required for some build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Determine architecture for binary downloads
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        echo "x86_64" > /tmp/arch; \
    elif [ "$ARCH" = "arm64" ]; then \
        echo "arm64" > /tmp/arch; \
    else \
        echo "x86_64" > /tmp/arch; \
    fi

# Install gog (Gmail CLI) - baked into image for persistence
RUN ARCH=$(cat /tmp/arch) && \
    curl -L "https://github.com/steipete/gog/releases/latest/download/gog_Linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/gog \
    || echo "Warning: gog installation failed (optional dependency)"

# Install goplaces (Google Places CLI)
RUN ARCH=$(cat /tmp/arch) && \
    curl -L "https://github.com/steipete/goplaces/releases/latest/download/goplaces_Linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/goplaces \
    || echo "Warning: goplaces installation failed (optional dependency)"

# Install wacli (WhatsApp CLI)
RUN ARCH=$(cat /tmp/arch) && \
    curl -L "https://github.com/steipete/wacli/releases/latest/download/wacli_Linux_${ARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/wacli \
    || echo "Warning: wacli installation failed (optional dependency)"

# Install Bitwarden CLI (for Vaultwarden support)
RUN npm install -g @bitwarden/cli && \
    ln -s /usr/local/lib/node_modules/@bitwarden/cli/bw.js /usr/local/bin/bw || \
    echo "Warning: Bitwarden CLI installation failed (optional dependency)"

# Install rbw (Rust Bitwarden CLI) - alternative efficient client
RUN ARCH=$(cat /tmp/arch) && \
    if [ "$ARCH" = "x86_64" ]; then RBW_ARCH="x86_64"; else RBW_ARCH="aarch64"; fi && \
    curl -L "https://git.tozt.net/rbw/plain/bin/rbw-${RBW_ARCH}-linux" -o /usr/local/bin/rbw && \
    curl -L "https://git.tozt.net/rbw/plain/bin/rbw-agent-${RBW_ARCH}-linux" -o /usr/local/bin/rbw-agent && \
    chmod +x /usr/local/bin/rbw /usr/local/bin/rbw-agent \
    || echo "Warning: rbw installation failed (optional dependency)"

# Create app user for security
RUN groupadd -r openclaw && useradd -r -g openclaw -d /home/openclaw -s /bin/bash openclaw
RUN mkdir -p /home/openclaw && chown -R openclaw:openclaw /home/openclaw

# Set working directory
WORKDIR /app

# Enable corepack for pnpm
RUN corepack enable

# Clone and build OpenClaw from source
RUN git clone --depth 1 https://github.com/openclaw/openclaw.git . && \
    pnpm install && \
    pnpm build && \
    pnpm ui:install && \
    pnpm ui:build

# Install additional CLI tools for OpenClaw skills
RUN npm install -g @steipete/bird || echo "Warning: bird CLI installation failed (optional dependency)"

# Copy entrypoint script
COPY entrypoint.sh /app/entrypoint.sh

# Create directories for persistent data and set ownership
RUN mkdir -p /data/.openclaw /data/openclaw && \
    chown -R openclaw:openclaw /data && \
    chown -R openclaw:openclaw /app && \
    chmod +x /app/entrypoint.sh

# Environment variables
# HOME=/data so that ~/.openclaw resolves to /data/.openclaw
# This ensures paste-token, gateway, and doctor all use the same auth path
ENV NODE_ENV=production
ENV HOME=/data
ENV OPENCLAW_CONFIG_PATH=/data/.openclaw/openclaw.json
ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV XDG_CONFIG_HOME=/data/.openclaw

# Expose ports
# 18789 - Gateway WebSocket + HTTP (Control UI)
# 18793 - Canvas host
EXPOSE 18789 18793

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:18789/health || exit 1

# Switch to non-root user for security
USER openclaw

# Use entrypoint script to handle config generation
ENTRYPOINT ["/app/entrypoint.sh"]
