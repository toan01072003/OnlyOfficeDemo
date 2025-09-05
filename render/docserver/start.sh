#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-80}"

echo "[start.sh] Starting ONLYOFFICE DocumentServer wrapper on port ${PORT}" >&2

patch_conf() {
  local patched=0
  for CONF in \
    /etc/onlyoffice/documentserver/nginx/ds.conf \
    /etc/nginx/conf.d/ds.conf
  do
    if [ -f "$CONF" ]; then
      echo "[start.sh] Patching Nginx conf: $CONF" >&2
      # Normalize listen directives to PORT (cover common patterns)
      sed -E -i "s/listen\s+80(\s*;)/listen ${PORT}\1/g" "$CONF" || true
      sed -E -i "s/listen\s+80\s+default_server;/listen ${PORT} default_server;/g" "$CONF" || true
      sed -E -i "s/listen\s+0\.0\.0\.0:80(\s*;)/listen 0.0.0.0:${PORT}\1/g" "$CONF" || true
      sed -E -i "s/listen\s+0\.0\.0\.0:80\s+default_server;/listen 0.0.0.0:${PORT} default_server;/g" "$CONF" || true
      sed -E -i "s/listen\s+\[::\]:80(\s*;)/listen [::]:${PORT}\1/g" "$CONF" || true
      sed -E -i "s/listen\s+\[::\]:80\s+default_server;/listen [::]:${PORT} default_server;/g" "$CONF" || true

      # Inject a fast /healthcheck exact-match inside first server block if missing
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
        echo "[start.sh] Injected /healthcheck location into $CONF" >&2
      fi

      patched=1
    fi
  done

  if [ "$patched" = "1" ]; then
    # Try reload Nginx if already running (ignore failures during boot)
    (nginx -t >/dev/null 2>&1 && nginx -s reload) || true
  fi
}

# First attempt before startup (in case config already exists)
patch_conf || true

# Start default document server supervisor in background
/app/ds/run-document-server.sh &
ds_pid=$!

# Ensure we forward signals to the child
trap 'echo "[start.sh] Caught TERM, forwarding to docserver" >&2; kill -TERM ${ds_pid} 2>/dev/null; wait ${ds_pid}; exit $?' TERM
trap 'echo "[start.sh] Caught INT, forwarding to docserver" >&2; kill -INT ${ds_pid} 2>/dev/null; wait ${ds_pid}; exit $?' INT

# During startup, DocumentServer may regenerate Nginx configs. Re-apply for a while.
for i in $(seq 1 60); do
  patch_conf || true
  sleep 2
done &

# Wait for the document server to exit
wait ${ds_pid}
exit $?
