################################################################################
### c3g_cbioportal_instance: all-in-one cBioPortal image
### cBioPortal webapp + ClickHouse server + MongoDB + session-service in ONE container,
### started (and stopped, in order) by entrypoint.sh.
### Versions follow cbioportal-docker-compose for cBioPortal 7.1.2, except MongoDB
### (mongo 4.2 does not install on the base image's Ubuntu 24.04 "noble").
### Follows https://github.com/c3g/web-app-template: app in /app, data in /data, secrets as env vars.
################################################################################

## CHANGE HERE ## versions
ARG CBIO_VERSION=7.1.2
ARG CH_VERSION=24.10
ARG SESSION_VERSION=0.6.4

## Helper stages: each one only provides a single file to COPY below
FROM docker.io/clickhouse/clickhouse-server:${CH_VERSION} AS clickhouse
# session-service only gives us a .war (platform independent), so always pull the amd64 image
FROM --platform=linux/amd64 docker.io/cbioportal/session-service:${SESSION_VERSION} AS session


FROM docker.io/cbioportal/cbioportal:${CBIO_VERSION}
LABEL maintainer="Gerardo Zapata gerardo.zapata@mcgill.ca"
LABEL org.opencontainers.image.source="https://github.com/c3g/c3g_cbioportal_instance"
LABEL org.opencontainers.image.description="All-in-one cBioPortal (webapp + ClickHouse + MongoDB + session-service) with OIDC login and OPA study access, for the C3G webapp VM"
LABEL org.opencontainers.image.licenses="AGPL-3.0"

## CHANGE HERE ## MongoDB major version (session-service database)
ARG MONGO_VERSION=8.0

USER root
WORKDIR /app

# 1. MongoDB server from the official MongoDB apt repo for this Ubuntu release
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && curl -fsSL https://www.mongodb.org/static/pgp/server-${MONGO_VERSION}.asc \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg \
    && . /etc/os-release \
    && echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg ] https://repo.mongodb.org/apt/ubuntu ${VERSION_CODENAME}/mongodb-org/${MONGO_VERSION} multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list \
    && apt-get update && apt-get install -y --no-install-recommends mongodb-org-server \
    && rm -rf /var/lib/apt/lists/* \
    && mongod --version

# 2. ClickHouse server binary, same version as cbioportal-docker-compose.
#    Kept in /opt/clickhouse so it does not replace the client bundled with the base image.
COPY --from=clickhouse /usr/bin/clickhouse /opt/clickhouse/clickhouse
RUN /opt/clickhouse/clickhouse --version

# 3. session-service (.war only; runs on the base image's Java)
COPY --from=session /app.war /app/session-service.war

# 4. Static ClickHouse configs (password, ports and memory cap are read from the environment)
COPY config/clickhouse-config.xml config/clickhouse-users.xml /app/config/

# 5. C3G logo in the portal header (skin.right_logo=c3g_logo.svg, set by entrypoint.sh)
COPY my_custom_logo.svg /app/my_custom_logo.svg
RUN found=0; \
    for d in $(find /cbioportal-webapp -type d -name images); do \
        cp /app/my_custom_logo.svg "${d}/c3g_logo.svg"; echo "logo -> ${d}/c3g_logo.svg"; found=1; \
    done; \
    [ "${found}" = 1 ] || echo "WARNING: no images/ folder under /cbioportal-webapp - header logo will not show"

# 6. Launcher + data folder (/data = the app volume: studies/, DB, config, logs; CBIO_DATA_DIR to move it)
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod 755 /app/entrypoint.sh && mkdir -p /data

EXPOSE 8080
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=60s --timeout=30s --start-period=15m --retries=3 \
    CMD ["/app/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
