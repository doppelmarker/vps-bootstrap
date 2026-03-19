#!/bin/bash
set -euo pipefail

# =============================================================================
# Bootstrap script for Aeza Sweden VPS (Ubuntu 24.04)
# Run as root on a fresh server to restore full configuration.
#
# What this does NOT set up (handled separately):
#   - Amnezia VPN: reinstall via Amnezia client over SSH
#   - App-specific containers: each app has its own docker-compose.yml
#   - SSH authorized_keys: personal key is embedded, deploy key is generated
# =============================================================================

SWAP_SIZE="2G"
SSH_PORT=22

echo "==> Updating system..."
apt-get update && apt-get upgrade -y

# --- Essential packages ---
echo "==> Installing essential packages..."
apt-get install -y \
  curl \
  wget \
  git \
  ufw \
  fail2ban \
  unattended-upgrades \
  apt-listchanges \
  htop \
  iotop \
  ncdu \
  jq \
  ca-certificates \
  gnupg \
  lsb-release

# --- Docker ---
echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable docker
systemctl start docker

# Install docker compose plugin if missing
if ! docker compose version &>/dev/null; then
  apt-get install -y docker-compose-plugin
fi

# --- Swap ---
echo "==> Configuring swap (${SWAP_SIZE})..."
if [ -f /swapfile ]; then
  swapoff /swapfile || true
  rm -f /swapfile
fi
fallocate -l "$SWAP_SIZE" /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
# Ensure fstab entry
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# --- Sysctl tuning ---
echo "==> Applying sysctl settings..."
cat > /etc/sysctl.d/99-server.conf << 'SYSCTL'
# IP forwarding (required for VPN)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# TCP performance
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_fastopen = 3

# Connection tracking
net.netfilter.nf_conntrack_max = 65536

# Memory pressure tuning for low-RAM VPS
vm.swappiness = 60
vm.overcommit_memory = 0
SYSCTL
sysctl --system

# --- Personal SSH key (must come BEFORE SSH hardening disables passwords) ---
echo "==> Installing personal SSH key..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys << 'AUTHKEYS'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKG8Cg0OwewpOGWPAcllxqg8C0N9SOq1/Q47e1KllyGM wsluser@UltraMachine
AUTHKEYS
chmod 600 ~/.ssh/authorized_keys

# --- Deploy key for GitHub Actions ---
echo "==> Generating deploy key for CI/CD..."
if [ ! -f ~/.ssh/deploy_key ]; then
  ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key -N ""
  cat ~/.ssh/deploy_key.pub >> ~/.ssh/authorized_keys
fi

# --- SSH hardening ---
echo "==> Hardening SSH..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i "s/^#\?Port.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
systemctl restart ssh

# --- Fail2ban ---
echo "==> Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
F2B
systemctl enable fail2ban
systemctl restart fail2ban

# --- UFW firewall ---
echo "==> Configuring UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow ${SSH_PORT}/tcp comment 'SSH'

# Amnezia VPN ports (will be used after Amnezia client setup)
ufw allow 44850/tcp comment 'Amnezia OpenVPN'
ufw allow 42824/udp comment 'Amnezia AWG'

# Web (for Cloudflare-proxied apps)
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

ufw --force enable

# --- Unattended upgrades ---
echo "==> Enabling unattended security upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UU

# --- Docker log rotation ---
echo "==> Configuring Docker log rotation..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKER'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
DOCKER
systemctl restart docker

# --- SSH key for GitHub ---
echo "==> Setting up SSH key..."
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -C "vps-aeza-sweden" -f ~/.ssh/id_ed25519 -N ""
  # Accept GitHub host key
  ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
fi

# --- Claude Code ---
echo "==> Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash

# --- CLAUDE.md (root-level context for Claude Code) ---
echo "==> Creating CLAUDE.md..."
cat > /root/CLAUDE.md << 'CLAUDEMD'
# Server Context

Aeza promo VPS located in Sweden.

## Specs

- 1 vCPU (AMD Ryzen 9 5950X, shared/virtualized)
- 3.8 GB RAM
- 10 GB disk (ext4)
- 2 GB swap
- Ubuntu 24.04 LTS
- KVM virtualization

## Constraints

- Disk space is very limited — be mindful of image sizes, build caches, and logs.
- Single core — avoid CPU-heavy parallel builds.
- No snapshots or backup API from hosting provider. If the server is lost, run bootstrap.sh from https://github.com/doppelmarker/vps-bootstrap to restore.

## Services

- **Amnezia VPN**: OpenVPN (TCP/44850) + AmneziaWG (UDP/42824). Containers managed by Amnezia client, configs stored inside containers. Do NOT modify Amnezia containers directly.
- **Caddy**: Reverse proxy at /opt/apps/caddy/ for routing Cloudflare subdomains to app containers.
- **Apps**: Each app lives in /opt/apps/<name>/ with its own docker-compose.yml, connected to the `web` Docker network.

## Firewall (UFW)

Open ports: SSH (22/tcp), OpenVPN (44850/tcp), AWG (42824/udp), HTTP (80/tcp), HTTPS (443/tcp). Everything else is denied.

## Docker

- All containers should use `restart: unless-stopped`.
- Log rotation is configured globally (10m max, 3 files).
- `live-restore: true` — containers survive dockerd restarts.
- App containers must join the `web` network to be reachable by Caddy.

## Adding a new app

1. Create /opt/apps/<name>/docker-compose.yml with the app service on the `web` network.
2. Add a reverse proxy entry in /opt/apps/caddy/Caddyfile.
3. Point a Cloudflare subdomain A record to the server IP.
4. `docker compose up -d` in both the app dir and caddy dir.
CLAUDEMD

# --- App directory structure ---
echo "==> Creating app directory structure..."
mkdir -p /opt/apps

# --- Caddy reverse proxy ---
echo "==> Setting up Caddy reverse proxy..."
mkdir -p /opt/apps/caddy/{data,config}

cat > /opt/apps/caddy/docker-compose.yml << 'CADDY'
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
    networks:
      - web

networks:
  web:
    name: web
    driver: bridge
CADDY

cat > /opt/apps/caddy/Caddyfile << 'CADDYFILE'
# Example: add entries like this for each app
#
# myapp.example.com {
#     reverse_proxy myapp:3000
# }
#
# For Cloudflare proxy mode, Caddy will auto-handle TLS.
# If using Cloudflare "Full (strict)", use:
#
# myapp.example.com {
#     tls {
#         dns cloudflare {env.CF_API_TOKEN}
#     }
#     reverse_proxy myapp:3000
# }
CADDYFILE

echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo "============================================"
echo ""
echo "==> GitHub SSH public key (add to https://github.com/settings/ssh/new):"
echo ""
cat ~/.ssh/id_ed25519.pub
echo ""
echo "==> Deploy private key (add as VPS_DEPLOY_KEY secret in GitHub repos):"
echo ""
cat ~/.ssh/deploy_key
echo ""
echo "Next steps:"
echo "  1. Add the GitHub SSH key above to https://github.com/settings/ssh/new"
echo "  2. Copy the deploy private key above into GitHub repo secrets as VPS_DEPLOY_KEY"
echo "  3. Reconnect via SSH to verify key auth works"
echo "  4. Install Amnezia VPN via your Amnezia client"
echo "  5. Start Caddy: cd /opt/apps/caddy && docker compose up -d"
echo "  6. Add apps under /opt/apps/<appname>/ and add Caddyfile entries"
echo ""
