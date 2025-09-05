FROM onlyoffice/documentserver:latest

# Optional: set default envs; Render can override at deploy time
ENV JWT_ENABLED=false \
    ALLOW_PRIVATE_IP_ADDRESS=true

# Build context is repo root on Render. Use full path.
COPY render/docserver/start.sh /start.sh
RUN chmod +x /start.sh

# Render expects the app to listen on $PORT
CMD ["/bin/bash", "/start.sh"]
