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

  # Ensure a fast 200 OK for PaaS health checks
  # Insert an exact-match location for /healthcheck inside the first server block if missing
  if ! grep -q "location = /healthcheck" "$CONF"; then
    awk '
      BEGIN { done=0 }
      {
        print $0
        if (!done && $0 ~ /server\s*\{/ ) {
          print "    location = /healthcheck { return 200 \"OK\"; add_header Content-Type text/plain; }"
          done=1
        }
      }
    ' "$CONF" > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF" || true
  fi
fi

# Start default document server supervisor
exec /app/ds/run-document-server.sh
