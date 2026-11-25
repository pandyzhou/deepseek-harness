# DeepSeek Harness (dsh) as one process: the published npm package on Node.js,
# serving its Web UI over plain HTTP for a reverse proxy in front of it. There
# is no login inside the image; the reverse proxy must ask for one.
FROM node:24-bookworm-slim

# The version of @deepseek-ai/dsh to install.
ARG DSH_VERSION=latest

# What the agent works with inside the container.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq less openssh-client procps python3 ripgrep tini unzip \
    && rm -rf /var/lib/apt/lists/*

RUN npm install --global "@deepseek-ai/dsh@${DSH_VERSION}" \
    && npm cache clean --force

COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY dsh /usr/local/bin/dsh
COPY healthcheck.sh /usr/local/bin/dsh-healthcheck
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/dsh /usr/local/bin/dsh-healthcheck \
    && dsh --help >/dev/null

ENV DSH_HOME=/data/dsh \
    DSH_PORT=3080 \
    DSH_TELEMETRY_DISABLED=1

VOLUME ["/data/dsh", "/workspace"]
WORKDIR /workspace
EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["dsh-healthcheck"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
