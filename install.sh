#!/bin/bash
# chmod +x install.sh
set -euo pipefail

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_banner() {
  echo -e "${BLUE}"
  echo "╔═════════════════════════════════════════╗"
  echo "║       KubeWatch ERP Installer           ║"
  echo "╚═════════════════════════════════════════╝"
  echo -e "${NC}"
}

check_prerequisites() {
  local missing=0

  if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker is not installed or not in PATH.${NC}"
    echo "  Install Docker: https://docs.docker.com/get-docker/"
    missing=1
  fi

  if ! docker compose version &> /dev/null 2>&1; then
    echo -e "${RED}Error: 'docker compose' (v2) is not available.${NC}"
    echo "  Docker Compose v2 ships with Docker Desktop >= 3.4 and Docker Engine >= 20.10."
    echo "  If you installed Docker Engine on Linux, run:"
    echo "    sudo apt-get install docker-compose-plugin   # Debian/Ubuntu"
    echo "    sudo yum install docker-compose-plugin       # RHEL/CentOS"
    missing=1
  fi

  if ! command -v openssl &> /dev/null; then
    echo -e "${RED}Error: openssl is not installed or not in PATH.${NC}"
    echo "  Install with: sudo apt-get install openssl  (or  brew install openssl)"
    missing=1
  fi

  if [ "$missing" -eq 1 ]; then
    echo ""
    echo -e "${RED}One or more prerequisites are missing. Please install them and re-run the installer.${NC}"
    exit 1
  fi

  echo -e "${GREEN}All prerequisites satisfied.${NC}"
}

install_agent_only() {
  echo ""
  read -p "KubeWatch API key (from app.kubewatchlabs.com): " API_KEY </dev/tty
  read -p "Agent name (e.g. 'Production Server'): " AGENT_NAME </dev/tty

  echo -e "${YELLOW}Deploying KubeWatch agent...${NC}"
  echo "Pulling agent image..."
  if ! docker pull ghcr.io/lloyd-theophilus/kubewatch-agent:latest; then
    echo ""
    echo -e "${RED}Failed to pull the KubeWatch agent image.${NC}"
    echo "The agent image is public and requires no login, so an 'unauthorized' or"
    echo "'denied' error is usually a transient registry or network issue. Check"
    echo "outbound access to ghcr.io from this host and try again, or contact"
    echo "support@kubewatchlabs.com."
    exit 1
  fi
  # The agent image runs as a non-root user, but /var/run/docker.sock is owned by
  # root:docker. Grant the container the socket's group so it can read the Docker
  # API without running as root. Fall back to root if the socket group can't be
  # determined (e.g. rootless Docker).
  DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo "")
  if [ -n "$DOCKER_GID" ]; then
    GROUP_FLAG=(--group-add "$DOCKER_GID")
  else
    GROUP_FLAG=(--user 0:0)
  fi
  docker run -d \
    --name kubewatch-agent \
    --restart unless-stopped \
    "${GROUP_FLAG[@]}" \
    -e KUBEWATCH_API_KEY="$API_KEY" \
    -e KUBEWATCH_AGENT_NAME="$AGENT_NAME" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v kubewatch-agent-data:/data \
    ghcr.io/lloyd-theophilus/kubewatch-agent:latest

  echo ""
  echo -e "${GREEN}Agent deployed!${NC}"
  echo "   It will appear in your dashboard within 30 seconds."
  echo "   Dashboard: https://app.kubewatchlabs.com"
}

install_self_hosted_erp() {
  check_prerequisites

  echo ""
  read -p "Domain or IP for this server (e.g. monitoring.company.com or 1.2.3.4): " DOMAIN </dev/tty
  read -p "Admin email: " ADMIN_EMAIL </dev/tty

  # Re-running the installer over an existing deployment must NOT regenerate
  # DB_PASSWORD or JWT_SECRET. Postgres only sets its password when the data
  # volume is first initialized, so a fresh DB_PASSWORD would fail to
  # authenticate against the existing volume (every service crash-loops with
  # "password authentication failed"), and a new JWT_SECRET would invalidate
  # all sessions. Preserve whatever the existing .env has; generate only what's
  # missing (first install).
  ENV_FILE="${HOME}/kubewatch-erp/.env"
  if [ -f "${ENV_FILE}" ]; then
    ADMIN_PASSWORD=$(grep '^ADMIN_PASSWORD=' "${ENV_FILE}" | cut -d= -f2-)
    JWT_SECRET=$(grep '^JWT_SECRET=' "${ENV_FILE}" | cut -d= -f2-)
    DB_PASSWORD=$(grep '^DB_PASSWORD=' "${ENV_FILE}" | cut -d= -f2-)
    REUSED_ENV=1
  fi
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 16 | tr -d '=+/')}"
  JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
  DB_PASSWORD="${DB_PASSWORD:-$(openssl rand -hex 16)}"

  # A bare IP can't get a public TLS cert (served over plain HTTP); a real domain
  # gets automatic HTTPS. Caddy is also set up for on-demand TLS (see the
  # Caddyfile below), so pointing a domain at this host's IP LATER auto-provisions
  # a certificate on the first HTTPS request, with no reinstall.
  if echo "${DOMAIN}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    BASE_URL="http://${DOMAIN}"
  else
    BASE_URL="https://${DOMAIN}"
  fi

  # Public IP of this host, used by the on-demand TLS gate: Caddy asks the gateway
  # whether to obtain a cert for an incoming domain, and the gateway only says yes
  # when the domain resolves to this IP. Detected via an external echo service;
  # falls back to DOMAIN when that is already a bare IP.
  SERVER_PUBLIC_IP=$(curl -fsSL https://api.ipify.org 2>/dev/null || true)
  if [ -z "${SERVER_PUBLIC_IP}" ] && echo "${DOMAIN}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    SERVER_PUBLIC_IP="${DOMAIN}"
  fi

  RELEASES="https://raw.githubusercontent.com/lloyd-theophilus/kubewatch-releases/main"

  echo -e "${YELLOW}Setting up KubeWatch ERP in ~/kubewatch-erp/ ...${NC}"
  mkdir -p ~/kubewatch-erp ~/kubewatch-erp/data ~/kubewatch-erp/migrations
  cd ~/kubewatch-erp

  # Download the Compose file and the database migrations bundle.
  echo "Downloading docker-compose.yml..."
  curl -fsSL "${RELEASES}/docker-compose.yml" -o docker-compose.yml
  echo "Downloading database migrations..."
  curl -fsSL "${RELEASES}/migrations.tar.gz" -o migrations.tar.gz
  tar -xzf migrations.tar.gz -C migrations && rm -f migrations.tar.gz

  # Stamp the installed version so the dashboard's System Health / update page
  # shows a real version instead of "dev". Falls back to "latest" if the release
  # marker isn't reachable.
  APP_VERSION=$(curl -fsSL "${RELEASES}/VERSION" 2>/dev/null | tr -d '[:space:]')
  APP_VERSION="${APP_VERSION:-latest}"

  # Write .env file
  # KUBEWATCH_LICENSE_KEY is intentionally absent: a 30-day trial starts automatically.
  # After purchase, add KUBEWATCH_LICENSE_KEY=<your-key> here and restart.
  cat > .env << EOF
KUBEWATCH_MODE=selfhosted
DOMAIN=${DOMAIN}
PUBLIC_BASE_URL=${BASE_URL}
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
JWT_SECRET=${JWT_SECRET}
DB_PASSWORD=${DB_PASSWORD}
APP_VERSION=${APP_VERSION}

# ── Email notifications (optional) ───────────────────────────────────
# Set these to enable outbound email: password-reset links, alert
# notifications, and license reminders. Leave them unset to disable email
# (you can still reset passwords from the server, see the docs). After
# setting them, run: docker compose up -d
# SMTP_HOST=smtp.your-provider.com
# SMTP_PORT=587
# SMTP_USER=your-smtp-username
# SMTP_PASS=your-smtp-password
# SMTP_FROM=support@your-company.com

# ── Connecting agents ────────────────────────────────────────────────
# The platform itself does not need an API key. Once it's running, log in
# and create an API key under Settings -> API Keys, then use it as
# KUBEWATCH_API_KEY when you deploy an agent (see the docs). If you deploy
# an agent alongside this stack, set it here:
# KUBEWATCH_API_KEY=
EOF

  # Write Caddyfile. API, auth and WebSocket traffic goes to the gateway;
  # everything else (dashboard pages, assets) is served by the frontend.
  #
  # Any host is served over HTTP on :80 (bare-IP access + ACME challenges) and
  # over HTTPS on :443. HTTPS uses on-demand TLS: Caddy obtains a certificate
  # during the first handshake for whatever domain is pointed at this host, gated
  # by the gateway's /api/v1/tls-check (which only allows domains that resolve to
  # SERVER_PUBLIC_IP). So a bare-IP install just works over HTTP today, and the
  # moment you point a domain at this IP it gets HTTPS automatically, no
  # reinstall.
  # If a prior run's `docker compose up` ever started with no Caddyfile on disk
  # yet, Docker auto-creates the bind-mount source as an empty DIRECTORY instead
  # of a file, and every future recreation of the caddy container then fails
  # ("not a directory") because the mount type is fixed at that point. Since
  # this block is about to fully regenerate Caddyfile anyway, clear a stray
  # directory first so `cat >` (which cannot overwrite a directory) succeeds.
  rm -rf Caddyfile
  cat > Caddyfile << 'EOF'
{
    on_demand_tls {
        ask http://gateway:8000/api/v1/tls-check
    }
}

(kubewatch_routes) {
    handle /api/* {
        reverse_proxy gateway:8000
    }
    handle /auth/* {
        reverse_proxy gateway:8000
    }
    handle /ws* {
        reverse_proxy gateway:8000
    }
    handle {
        reverse_proxy frontend:3000
    }
}

http:// {
    import kubewatch_routes
}

https:// {
    tls {
        on_demand
    }
    import kubewatch_routes
}
EOF

  # Restrict the files that carry secrets or reveal deployment internals to the
  # owner only, so other accounts on the host can't read them. .env holds
  # JWT_SECRET, DB_PASSWORD and any API keys; the compose file and Caddyfile
  # expose the deployment layout. The docker compose CLI and the in-app updater
  # run as the owner (or root), so 0600 does not affect normal operation.
  chmod 600 .env docker-compose.yml Caddyfile 2>/dev/null || true

  echo "Pulling images..."
  if ! docker compose pull; then
    echo ""
    echo -e "${RED}Failed to pull one or more KubeWatch images.${NC}"
    echo "If you saw 'unauthorized' or 'denied' above, the registry rejected the pull."
    echo "The KubeWatch container images are public and require no login, so this is"
    echo "usually a transient registry or network issue. Try again in a moment:"
    echo ""
    echo "    cd ~/kubewatch-erp && docker compose pull && docker compose up -d"
    echo ""
    echo "If it persists, check outbound access to ghcr.io from this host, or contact"
    echo "support@kubewatchlabs.com."
    exit 1
  fi
  echo "Starting services..."
  docker compose up -d

  # Wait for health
  echo -n "Waiting for services to be ready"
  for i in $(seq 1 30); do
    if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
      echo ""
      break
    fi
    echo -n "."
    sleep 2
  done

  print_summary
}

print_summary() {
  echo ""
  echo -e "${GREEN}"
  echo "╔═════════════════════════════════════════════════════════╗"
  echo "║              KubeWatch ERP is running!                  ║"
  echo "╠═════════════════════════════════════════════════════════╣"
  printf "║  URL:       %-40s║\n" "${BASE_URL:-http://${DOMAIN}}"
  printf "║  Email:     %-40s║\n" "${ADMIN_EMAIL}"
  printf "║  Password:  %-40s║\n" "${ADMIN_PASSWORD}"
  echo "╠═════════════════════════════════════════════════════════╣"
  echo "║  30-day free trial started. No license key required.    ║"
  echo "║  To purchase a license: Settings → Billing in the UI.  ║"
  echo "║  To connect agents: create an API key in the dashboard  ║"
  echo "║  under Settings → API Keys, then deploy an agent.       ║"
  echo "║  IMPORTANT: Save this password. Change it after login.  ║"
  echo "╚═════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  if [ "${REUSED_ENV:-0}" = "1" ]; then
    echo "Note: an existing install was detected, so your original database"
    echo "password and admin credentials were kept. If you already changed your"
    echo "admin password in the dashboard, log in with that one (the value above"
    echo "is the originally generated password)."
  fi
  echo "Note: the 'kubewatch-erp-migrate-1' container will show 'Exited', this is"
  echo "expected. It runs the database migrations once and stops; every other"
  echo "container keeps running. A stopped migrate container is not an error."
}

main() {
  print_banner
  echo "Deployment mode:"
  echo "  1) Agent only: monitor THIS host using KubeWatch Cloud."
  echo "     Pick this if you already have an account at app.kubewatchlabs.com."
  echo "     It deploys just the agent and does NOT install the platform."
  echo ""
  echo "  2) Self-Hosted: install the full KubeWatch platform on this server."
  echo "     Pick this to run everything yourself."
  echo ""
  read -p "Select [1/2]: " MODE_CHOICE </dev/tty

  case "$MODE_CHOICE" in
    1) install_agent_only ;;
    2) install_self_hosted_erp ;;
    *) echo -e "${RED}Invalid choice. Please select 1 or 2.${NC}"; exit 1 ;;
  esac
}

main
