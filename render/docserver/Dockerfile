FROM onlyoffice/documentserver:latest

# Optional: set default envs; PaaS can override at deploy time
ENV JWT_ENABLED=false \
    ALLOW_PRIVATE_IP_ADDRESS=true

# Make build robust to different contexts (repo root vs render/docserver)
# Bring current context into image and copy start.sh from either path.
ADD . /tmp/buildctx
RUN set -euo pipefail \
 && (cp /tmp/buildctx/start.sh /start.sh 2>/dev/null \
     || cp /tmp/buildctx/render/docserver/start.sh /start.sh) \
 && chmod +x /start.sh

# Run our wrapper that adjusts Nginx listen port and healthcheck
ENTRYPOINT ["/start.sh"]
