#!/usr/bin/env bash
# KubeWatch ERP — Installer
# Downloads pre-built images and starts the stack. No git clone required.
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/lloyd-theophilus/kubewatch-releases/main/install.sh | bash
#
# Or download and inspect first:
#   curl -fsSL -O https://raw.githubusercontent.com/lloyd-theophilus/kubewatch-releases/main/install.sh
#   bash install.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[kubewatch]${NC} $*"; }
success() { echo -e "${GREEN}[kubewatch]${NC} $*"; }
warn()    { echo -e "${YELLOW}[kubewatch]${NC} $*"; }
die()     { echo -e "${RED}[kubewatch] ERROR:${NC} $*" >&2; exit 1; }

RELEASES_URL="https://raw.githubusercontent.com/lloyd-theophilus/kubewatch-releases/main"
COMPOSE_FILE="docker-compose.yml"

echo ""
echo -e "${BOLD}  KubeWatch — Container Observability Platform${NC}"
echo "  Installer · Docker Compose + Caddy"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────────────────

command -v docker  &>/dev/null || die "Docker not found. Install: https://docs.docker.com/engine/install/"
docker compose version &>/dev/null || die "Docker Compose plugin not found. Install: https://docs.docker.com/compose/install/linux/"
command -v openssl &>/dev/null || die "openssl not found. Run: sudo apt install openssl  (or: sudo yum install openssl)"

info "Prerequisites OK (Docker $(docker --version | awk '{print $3}' | tr -d ','))"

# ── Working directory ──────────────────────────────────────────────────────────

# When piped through bash the script has no file path; use current directory.
INSTALL_DIR="${KUBEWATCH_DIR:-$PWD/kubewatch}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
info "Install directory: $INSTALL_DIR"

# ── Download compose file ──────────────────────────────────────────────────────

if [ ! -f "$COMPOSE_FILE" ]; then
    info "Downloading docker-compose.yml…"
    curl -fsSL "${RELEASES_URL}/docker-compose.yml" -o "$COMPOSE_FILE" \
        || die "Failed to download docker-compose.yml from ${RELEASES_URL}"
    info "docker-compose.yml downloaded"
else
    info "docker-compose.yml already present — skipping download"
fi

# ── .env setup ─────────────────────────────────────────────────────────────────

[ -f .env ] || touch .env

get_env() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true; }

set_env() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" .env 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
        echo "${key}=${val}" >> .env
    fi
}

# ── Auto-generate secrets ──────────────────────────────────────────────────────

if [ -z "$(get_env JWT_SECRET)" ]; then
    set_env JWT_SECRET "$(openssl rand -hex 32)"
    info "Generated JWT_SECRET"
else
    info "JWT_SECRET already set — keeping existing value"
fi

if [ -z "$(get_env KUBEWATCH_API_KEY)" ]; then
    set_env KUBEWATCH_API_KEY "$(openssl rand -hex 16)"
    info "Generated KUBEWATCH_API_KEY"
else
    info "KUBEWATCH_API_KEY already set — keeping existing value"
fi

# ── Domain / IP ────────────────────────────────────────────────────────────────

DOMAIN="$(get_env DOMAIN)"
if [ -z "$DOMAIN" ]; then
    echo ""
    echo "  Enter your domain name or public IP address."
    echo "  Domain → HTTPS with automatic TLS certificate (Let's Encrypt)."
    echo "  IP     → HTTP only (no TLS)."
    echo ""
    read -rp "  Domain or IP: " DOMAIN
    [ -z "$DOMAIN" ] && die "Domain or IP is required."
    set_env DOMAIN "$DOMAIN"
fi
info "Using DOMAIN=${DOMAIN}"

# ── Admin credentials ──────────────────────────────────────────────────────────

ADMIN_EMAIL="$(get_env ADMIN_EMAIL)"
if [ -z "$ADMIN_EMAIL" ] || [ "$ADMIN_EMAIL" = "admin@example.com" ]; then
    echo ""
    read -rp "  Admin email address: " ADMIN_EMAIL
    [ -z "$ADMIN_EMAIL" ] && die "Admin email is required."
    set_env ADMIN_EMAIL "$ADMIN_EMAIL"
fi

ADMIN_PASSWORD="$(get_env ADMIN_PASSWORD)"
if [ -z "$ADMIN_PASSWORD" ]; then
    echo ""
    read -rsp "  Admin password: " ADMIN_PASSWORD
    echo ""
    [ -z "$ADMIN_PASSWORD" ] && die "Admin password is required."
    set_env ADMIN_PASSWORD "$ADMIN_PASSWORD"
fi

# ── Write Caddyfile ────────────────────────────────────────────────────────────

if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PROTOCOL="http"
    WS_PROTOCOL="ws"
    warn "IP address detected — running on HTTP (no TLS). Use a domain name for HTTPS."
else
    PROTOCOL="https"
    WS_PROTOCOL="wss"
fi

cat > Caddyfile <<EOF
${DOMAIN} {
    reverse_proxy /api/* backend:8080
    reverse_proxy /ws     backend:8080
    reverse_proxy /*      frontend:3000

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options    "nosniff"
        X-Frame-Options           "SAMEORIGIN"
    }

    encode gzip
}
EOF

# HTTP-only override for bare IP addresses
if [[ "$PROTOCOL" == "http" ]]; then
    cat > Caddyfile <<EOF
:80 {
    reverse_proxy /api/* backend:8080
    reverse_proxy /ws     backend:8080
    reverse_proxy /*      frontend:3000

    encode gzip
}
EOF
fi

info "Caddyfile written"

# ── Pull images and start ──────────────────────────────────────────────────────

echo ""
info "Pulling KubeWatch images…"
docker compose -f "$COMPOSE_FILE" --env-file .env pull

echo ""
info "Starting KubeWatch ERP…"
docker compose -f "$COMPOSE_FILE" --env-file .env up -d

echo ""
echo -e "${GREEN}${BOLD}"
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │                   KubeWatch is running                          │"
echo "  ├─────────────────────────────────────────────────────────────────┤"
printf "  │  URL              %-48s│\n" "${PROTOCOL}://${DOMAIN}"
printf "  │  Admin email      %-48s│\n" "$(get_env ADMIN_EMAIL)"
printf "  │  Agent API key    %-48s│\n" "$(get_env KUBEWATCH_API_KEY)"
echo "  ├─────────────────────────────────────────────────────────────────┤"
echo "  │  First visit → setup wizard → create your org + admin account   │"
echo "  │  Use the Agent API key above when deploying kubewatch-agent.     │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo -e "${NC}"
echo "  Logs:    docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} logs -f"
echo "  Stop:    docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} down"
echo "  Restart: docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} restart"
echo ""
