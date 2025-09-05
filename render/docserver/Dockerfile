FROM onlyoffice/documentserver:latest

# Optional: set default envs; Render can override at deploy time
ENV JWT_ENABLED=false \
    ALLOW_PRIVATE_IP_ADDRESS=true

# In Railway, the Dockerfile's directory is often the build context.
# Copy the script relative to this Dockerfile's folder.
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Render expects the app to listen on $PORT
CMD ["/bin/bash", "/start.sh"]
