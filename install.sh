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
  docker run -d \
    --name kubewatch-agent \
    --restart unless-stopped \
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

  # A bare IP can't get a public TLS cert, serve plain HTTP; a real domain gets
  # automatic HTTPS from Caddy.
  if echo "${DOMAIN}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    SITE="http://${DOMAIN}"
    BASE_URL="http://${DOMAIN}"
  else
    SITE="${DOMAIN}"
    BASE_URL="https://${DOMAIN}"
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

  # Write .env file
  # KUBEWATCH_LICENSE_KEY is intentionally absent — a 30-day trial starts automatically.
  # After purchase, add KUBEWATCH_LICENSE_KEY=<your-key> here and restart.
  cat > .env << EOF
KUBEWATCH_MODE=selfhosted
DOMAIN=${DOMAIN}
PUBLIC_BASE_URL=${BASE_URL}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
JWT_SECRET=${JWT_SECRET}
DB_PASSWORD=${DB_PASSWORD}

# ── Connecting agents ────────────────────────────────────────────────
# The platform itself does not need an API key. Once it's running, log in
# and create an API key under Settings -> API Keys, then use it as
# KUBEWATCH_API_KEY when you deploy an agent (see the docs). If you deploy
# an agent alongside this stack, set it here:
# KUBEWATCH_API_KEY=
EOF

  # Write Caddyfile. API, auth and WebSocket traffic goes to the gateway;
  # everything else (dashboard pages, assets) is served by the frontend.
  cat > Caddyfile << EOF
${SITE} {
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
EOF

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
  echo "Note: the 'kubewatch-erp-migrate-1' container will show 'Exited' — this is"
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
