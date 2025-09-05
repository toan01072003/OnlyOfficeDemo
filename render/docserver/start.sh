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
  sed -i "s/listen 80;/listen ${PORT};/g" "$CONF" || true
  sed -i "s/listen \[::\]:80;/listen \[::\]:${PORT};/g" "$CONF" || true
fi

# Start default document server supervisor
exec /app/ds/run-document-server.sh

