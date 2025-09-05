#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-80}"

# Try to locate nginx ds.conf
CONF=""
if [ -f /etc/onlyoffice/documentserver/nginx/ds.conf ]; then
  CONF=/etc/onlyoffice/documentserver/nginx/ds.conf
elif [ -f /etc/nginx/conf.d/ds.conf ]; then
  CONF=/etc/nginx/conf.d/ds.conf
fi

if [ -n "$CONF" ]; then
  # Replace common listen patterns with Render-provided $PORT
  sed -E -i "s/listen\s+80;/listen ${PORT};/g" "$CONF" || true
  sed -E -i "s/listen\s+\[::\]:80;/listen [::]:${PORT};/g" "$CONF" || true
  sed -E -i "s/listen\s+0\.0\.0\.0:80;/listen 0.0.0.0:${PORT};/g" "$CONF" || true
  sed -E -i "s/listen\s+\[::\]:80\s+default_server;/listen [::]:${PORT} default_server;/g" "$CONF" || true
fi

# Start default document server supervisor
exec /app/ds/run-document-server.sh
