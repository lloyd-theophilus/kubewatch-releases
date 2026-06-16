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
  read -p "KubeWatch API key (from app.kubewatch.io): " API_KEY
  read -p "Agent name (e.g. 'Production Server'): " AGENT_NAME

  echo -e "${YELLOW}Deploying KubeWatch agent...${NC}"
  docker run -d \
    --name kubewatch-agent \
    --restart unless-stopped \
    -e KUBEWATCH_SERVER_URL=https://api.kubewatch.io \
    -e KUBEWATCH_API_KEY="$API_KEY" \
    -e KUBEWATCH_AGENT_NAME="$AGENT_NAME" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v kubewatch-agent-data:/data \
    ghcr.io/lloyd-theophilus/kubewatch-agent:latest

  echo ""
  echo -e "${GREEN}Agent deployed!${NC}"
  echo "   It will appear in your dashboard within 30 seconds."
  echo "   Dashboard: https://app.kubewatch.io"
}

install_self_hosted_erp() {
  check_prerequisites

  echo ""
  read -p "License key (from your purchase email): " LICENSE_KEY
  read -p "Domain or IP for this server (e.g. monitoring.company.com or 1.2.3.4): " DOMAIN
  read -p "Admin email: " ADMIN_EMAIL

  ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
  JWT_SECRET=$(openssl rand -hex 32)
  DB_PASSWORD=$(openssl rand -hex 16)

  echo -e "${YELLOW}Setting up KubeWatch ERP in ~/kubewatch-erp/ ...${NC}"
  mkdir -p ~/kubewatch-erp
  cd ~/kubewatch-erp

  # Download production compose file
  echo "Downloading docker-compose.yml..."
  curl -fsSL https://releases.kubewatch.io/docker-compose.selfhost.yml -o docker-compose.yml

  # Write .env file
  cat > .env << EOF
KUBEWATCH_MODE=selfhosted
KUBEWATCH_LICENSE_KEY=${LICENSE_KEY}
DOMAIN=${DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
JWT_SECRET=${JWT_SECRET}
DB_PASSWORD=${DB_PASSWORD}
EOF

  # Write Caddyfile
  cat > Caddyfile << EOF
${DOMAIN} {
    reverse_proxy gateway:8000
}
EOF

  echo "Pulling images..."
  docker compose pull
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
  printf "║  URL:       http://%-37s║\n" "${DOMAIN}"
  printf "║  Email:     %-40s║\n" "${ADMIN_EMAIL}"
  printf "║  Password:  %-40s║\n" "${ADMIN_PASSWORD}"
  echo "╠═════════════════════════════════════════════════════════╣"
  echo "║  IMPORTANT: Save this password. Change it after login.  ║"
  echo "║  To add agents, use the API key shown in Settings.      ║"
  echo "╚═════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

main() {
  print_banner
  echo "Deployment mode:"
  echo "  1) Connect to kubewatch.io (SaaS agent only)"
  echo "  2) Self-Hosted ERP (run everything locally)"
  echo ""
  read -p "Select [1/2]: " MODE_CHOICE

  case "$MODE_CHOICE" in
    1) install_agent_only ;;
    2) install_self_hosted_erp ;;
    *) echo -e "${RED}Invalid choice. Please select 1 or 2.${NC}"; exit 1 ;;
  esac
}

main
