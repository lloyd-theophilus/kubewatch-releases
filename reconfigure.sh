#!/bin/sh
# KubeWatch — Domain reconfigure watcher
# Runs inside the 'reconfigure' container every 30 s.
# Reads DOMAIN from /config/.env; if it differs from the current Caddyfile,
# rewrites /config/Caddyfile. Caddy's --watch flag picks up the change
# automatically and provisions a TLS certificate when a real domain is set.
CADDYFILE=/config/Caddyfile
ENV_FILE=/config/.env

write_http() {
  cat > "$CADDYFILE" <<'EOF'
:80 {
    reverse_proxy /api/* backend:8080
    reverse_proxy /ws     backend:8080
    reverse_proxy /*      frontend:3000
    encode gzip
}
EOF
}

write_https() {
  local domain="$1"
  cat > "$CADDYFILE" <<EOF
${domain} {
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
}

echo "[reconfigure] Starting — checking every 30 s"

while true; do
  DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r\n ' || true)

  if [ -n "$DOMAIN" ]; then
    # Determine what the first line of the Caddyfile should be
    if echo "$DOMAIN" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      TARGET=":80"
    else
      TARGET="$DOMAIN"
    fi

    # Read what the current Caddyfile starts with (strip trailing space and brace)
    CURRENT=$(head -1 "$CADDYFILE" 2>/dev/null | sed 's/ {$//' | tr -d ' ' || true)

    if [ "$TARGET" != "$CURRENT" ]; then
      echo "[reconfigure] Domain changed: '$CURRENT' -> '$TARGET'"
      if [ "$TARGET" = ":80" ]; then
        write_http
      else
        write_https "$DOMAIN"
      fi
      echo "[reconfigure] Caddyfile updated. Caddy will reload automatically."
    fi
  fi

  sleep 30
done
