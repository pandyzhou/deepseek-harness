# DSH Tavern (github.com/flizzywine/dsh-tavern) with the DeepSeek Harness it
# pins, as one image, behind a login page. The project's own installer runs
# once while the image is built, and the install it makes is packed into
# /opt/dsh-tavern. The first start of a container unpacks it into /data, where
# it lives on as an ordinary command-line install: it updates itself and keeps
# its data there.
FROM node:24-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq less procps python3 ripgrep tini unzip xdg-user-dirs zstd \
    && rm -rf /var/lib/apt/lists/*

# The registry the installer and every later update download from; the
# project's own default is a mirror in China.
ENV DSH_TAVERN_NPM_REGISTRY=https://registry.npmjs.org \
    DSH_TELEMETRY_DISABLED=1

# The tavern gives its command-line install no layout for phones, so in the
# browser of a phone the page of DSH around the tavern keeps the layout of a
# computer. With this the install loads the one the tavern's Android app
# carries (dsh-web-mobile), which changes the page on touch screens up to
# 1023 px wide and does nothing where there is a mouse. The tavern reads it at
# the install below and at every later update. build-seed.sh switches off the
# part of it that writes into the model settings.
ENV DSH_TAVERN_MOBILE_LAYOUT=1

# The commit of dsh-tavern that the image carries is the one in TAVERN_COMMIT.
# This step is done again only when that file or the script changes.
ARG TAVERN_REPOSITORY=flizzywine/dsh-tavern
COPY support/paths.sh build-seed.sh TAVERN_COMMIT /usr/local/lib/dsh-tavern-docker/
RUN install -d -o node -g node /data /opt/dsh-tavern /run/dsh-tavern-docker \
    && TAVERN_REPOSITORY="$TAVERN_REPOSITORY" \
        setpriv --reuid node --regid node --init-groups \
        bash /usr/local/lib/dsh-tavern-docker/build-seed.sh \
    && rm -rf /tmp/* /usr/local/lib/dsh-tavern-docker/build-seed.sh /usr/local/lib/dsh-tavern-docker/TAVERN_COMMIT

COPY support/ /usr/local/lib/dsh-tavern-docker/
COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY dsh-tavern /usr/local/bin/dsh-tavern
COPY healthcheck.sh /usr/local/bin/tavern-healthcheck
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/dsh-tavern /usr/local/bin/tavern-healthcheck

VOLUME ["/data"]
WORKDIR /data
EXPOSE 3081
# The first start unpacks the install before the tavern answers.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=3 CMD ["tavern-healthcheck"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["tini", "--", "docker-entrypoint.sh"]
