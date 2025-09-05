FROM onlyoffice/documentserver:latest

# Optional: set default envs; PaaS can override at deploy time
ENV JWT_ENABLED=false \
    ALLOW_PRIVATE_IP_ADDRESS=true

# Make build robust to different contexts (repo root vs render/docserver)
# Bring current context into image and copy start.sh from either path.
ADD . /tmp/buildctx
# Copy start.sh from either current context (render/docserver) or repo root
RUN if [ -f /tmp/buildctx/start.sh ]; then \
      cp /tmp/buildctx/start.sh /start.sh; \
    else \
      cp /tmp/buildctx/render/docserver/start.sh /start.sh; \
    fi \
    && chmod +x /start.sh

# Run our wrapper that adjusts Nginx listen port and healthcheck
ENTRYPOINT ["/start.sh"]
