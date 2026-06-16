#!/bin/bash
# chmod +x reconfigure.sh
# Usage: ./reconfigure.sh --domain new.example.com [--email new@example.com]
# Updates .env and restarts affected services without a full reinstall.
set -euo pipefail

DOMAIN=""
EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --email)  EMAIL="$2";  shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

INSTALL_DIR="${HOME}/kubewatch-erp"

if [ ! -f "${INSTALL_DIR}/.env" ]; then
  echo "Error: KubeWatch not installed at ${INSTALL_DIR}"
  exit 1
fi

cd "${INSTALL_DIR}"

if [ -n "$DOMAIN" ]; then
  # Update DOMAIN in .env (create .bak backup first)
  sed -i.bak "s/^DOMAIN=.*/DOMAIN=${DOMAIN}/" .env
  # Regenerate Caddyfile with the new domain
  cat > Caddyfile << EOF
${DOMAIN} {
    reverse_proxy gateway:8000
}
EOF
  echo "Updated domain to: ${DOMAIN}"
  docker compose restart caddy
fi

if [ -n "$EMAIL" ]; then
  sed -i.bak "s/^ADMIN_EMAIL=.*/ADMIN_EMAIL=${EMAIL}/" .env
  echo "Updated admin email to: ${EMAIL}"
fi

echo "Reconfiguration complete."
