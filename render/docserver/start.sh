#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-80}"

echo "[start.sh] Starting ONLYOFFICE DocumentServer wrapper on port ${PORT}" >&2

# Ensure cookies work in cross-domain iframe (Chrome 3rd-party cookies)
# Sets SameSite=None; Secure and Partitioned cookie attributes
configure_cookies() {
  local LOCAL_JSON=/etc/onlyoffice/documentserver/local.json
  mkdir -p /etc/onlyoffice/documentserver
  cat > "$LOCAL_JSON" <<'JSON'
{
  "services": {
    "CoAuthoring": {
      "cookie": {
        "secure": true,
        "sameSite": "None",
        "partitioned": true
      }
    }
  }
}
JSON
  echo "[start.sh] Wrote cookie settings to $LOCAL_JSON (SameSite=None; Secure; Partitioned)" >&2
}

# Clean up WAIT_HOSTS to avoid invalid entries that break nc
sanitize_wait_hosts() {
  local raw="${WAIT_HOSTS:-}"
  if [ -z "$raw" ]; then
    return 0
  fi
  local IFS=',' token host port cleaned=()
  for token in $raw; do
    token="${token// /}"
    if [ -z "$token" ]; then
      continue
    fi
    host="${token%%:*}"
    port="${token##*:}"
    if [ -z "$host" ] || [ -z "$port" ]; then
      echo "[start.sh] Dropping WAIT_HOSTS entry '$token' (empty host/port)" >&2
      continue
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
      echo "[start.sh] Dropping WAIT_HOSTS entry '$token' (non-numeric port)" >&2
      continue
    fi
    cleaned+=("${host}:${port}")
  done
  if [ ${#cleaned[@]} -eq 0 ]; then
    echo "[start.sh] Unsetting WAIT_HOSTS (no valid entries)" >&2
    unset WAIT_HOSTS
  else
    WAIT_HOSTS=$(IFS=','; echo "${cleaned[*]}")
    export WAIT_HOSTS
    echo "[start.sh] WAIT_HOSTS sanitized to: ${WAIT_HOSTS}" >&2
  fi
}

# Ensure sane defaults for ONLYOFFICE env to avoid startup errors
ensure_defaults() {
  case "${DB_TYPE:-}" in
    postgres|postgresql|mysql|mariadb) ;; # supported values
    "" ) export DB_TYPE=postgres ; echo "[start.sh] DB_TYPE not set; defaulting to 'postgres'" >&2 ;;
    *  ) echo "[start.sh] Unknown DB_TYPE='${DB_TYPE}'. Forcing 'postgres'" >&2 ; export DB_TYPE=postgres ;;
  esac

  # Some images use AMQP_TYPE; default to rabbitmq if empty/invalid
  case "${AMQP_TYPE:-}" in
    rabbitmq|amqp) ;; 
    "" ) export AMQP_TYPE=rabbitmq ;;
    *  ) export AMQP_TYPE=rabbitmq ;;
  esac
}

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

# Apply cookie config and first attempt at nginx patch (in case config already exists)
configure_cookies || true
sanitize_wait_hosts || true
ensure_defaults || true
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
