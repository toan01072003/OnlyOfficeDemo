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

# Normalize and/or disable generic wait variables that can be injected by PaaS
sanitize_wait_vars() {
  # If a single WAIT_HOST numeric is provided without port, turn it into localhost:port
  if [[ "${WAIT_HOST:-}" =~ ^[0-9]+$ ]] && [ -z "${WAIT_PORT:-}" ]; then
    export WAIT_PORT="$WAIT_HOST"
    export WAIT_HOST="localhost"
    echo "[start.sh] Adjusted WAIT_HOST numeric to WAIT_HOST=localhost WAIT_PORT=${WAIT_PORT}" >&2
  fi
  # If host missing but port set → unset both
  if [ -z "${WAIT_HOST:-}" ] && [ -n "${WAIT_PORT:-}" ]; then
    echo "[start.sh] Unsetting WAIT_PORT (no WAIT_HOST)" >&2
    unset WAIT_PORT
  fi

  # If WAIT_HOSTS exists but some tokens invalid, we already sanitized; if it is still invalid, unset
  if [ -n "${WAIT_HOSTS:-}" ] && ! echo "$WAIT_HOSTS" | grep -q ':'; then
    echo "[start.sh] Unsetting WAIT_HOSTS (no host:port entries)" >&2
    unset WAIT_HOSTS
  fi

  # Some base images use WAIT_FOR_HOST / WAIT_FOR_PORT
  if [[ "${WAIT_FOR_HOST:-}" =~ ^[0-9]+$ ]] && [ -z "${WAIT_FOR_PORT:-}" ]; then
    export WAIT_FOR_PORT="$WAIT_FOR_HOST"
    export WAIT_FOR_HOST="localhost"
    echo "[start.sh] Adjusted WAIT_FOR_HOST numeric to WAIT_FOR_HOST=localhost WAIT_FOR_PORT=${WAIT_FOR_PORT}" >&2
  fi
  if [ -z "${WAIT_FOR_HOST:-}" ] && [ -n "${WAIT_FOR_PORT:-}" ]; then
    echo "[start.sh] Unsetting WAIT_FOR_PORT (no WAIT_FOR_HOST)" >&2
    unset WAIT_FOR_PORT
  fi
}

# Fix DB env if accidentally inverted (e.g., DB_HOST=5432 with empty DB_PORT)
normalize_host_port_pair() {
  # $1 = HOST_VAR name, $2 = PORT_VAR name
  local hv="$1" pv="$2" host="${!1:-}" port="${!2:-}"
  if [[ "$host" =~ ^[0-9]+$ ]] && [ -z "$port" ]; then
    eval export $pv="$host"
    eval export $hv="localhost"
    echo "[start.sh] Adjusted $hv numeric to $hv=localhost $pv=${!pv}" >&2
  fi
  if [ -z "$host" ] && [ -n "$port" ]; then
    # Provide localhost default to avoid broken waits
    eval export $hv="localhost"
    echo "[start.sh] Set $hv=localhost for existing $pv=${!pv}" >&2
  fi
}

sanitize_db_env() {
  normalize_host_port_pair DB_HOST DB_PORT
  normalize_host_port_pair POSTGRES_HOST POSTGRES_PORT
  normalize_host_port_pair POSTGRESQL_HOST POSTGRESQL_PORT
  normalize_host_port_pair ONLYOFFICE_DB_HOST ONLYOFFICE_DB_PORT
  normalize_host_port_pair PGHOST PGPORT
}

sanitize_wait_vars || true
sanitize_db_env || true

# As a last resort, drop problematic WAIT_* variables entirely if they remain inconsistent
drop_broken_waits() {
  local broken=0
  # If any of these forms are present but still inconsistent, unset them
  if [ -n "${WAIT_HOST:-}" ] && [ -z "${WAIT_PORT:-}" ]; then broken=1; fi
  if [ -n "${WAIT_FOR_HOST:-}" ] && [ -z "${WAIT_FOR_PORT:-}" ]; then broken=1; fi
  if [ -n "${WAIT_HOSTS:-}" ] && ! echo "$WAIT_HOSTS" | grep -Eiq ':[0-9]+'; then broken=1; fi
  if [ "$broken" = "1" ]; then
    echo "[start.sh] Unsetting WAIT_* variables to avoid invalid nc waits" >&2
    unset WAIT_HOST WAIT_PORT WAIT_FOR_HOST WAIT_FOR_PORT WAIT_HOSTS WAIT_FOR WAIT_TIMEOUT WAIT_SLEEP
  fi
}

drop_broken_waits || true
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
