################################################################################
### c3g_cbioportal_instance: all-in-one cBioPortal image
### cBioPortal webapp + ClickHouse server + MongoDB + session-service in ONE container,
### started (and stopped, in order) by entrypoint.sh, + reports_server.py (PCGR report tabs, same study access).
### One image, two roles: `build <manifest>` on the Build VM (imports studies -> DB snapshot on shared storage),
### `start` on the Host VM (serves a snapshot, never imports). README "Build VM" / "Host VM".
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
LABEL org.opencontainers.image.description="All-in-one cBioPortal (webapp + ClickHouse + MongoDB + session-service) with OIDC login, per-study access (COmanage token groups + the app's OPA) and access-checked PCGR report tabs, for the C3G webapp VM"
LABEL org.opencontainers.image.licenses="AGPL-3.0"

## cBioPortal version recorded in every snapshot's BUILD_INFO.json; the host refuses a snapshot built with another one
ARG CBIO_VERSION
ENV CBIO_VERSION=${CBIO_VERSION}

## CHANGE HERE ## MongoDB major version (session-service database)
ARG MONGO_VERSION=8.0

USER root
WORKDIR /app

# 1. MongoDB server from the official MongoDB apt repo for this Ubuntu release
#    + tzdata: the host's scheduled sync runs at local clock times (TZ=America/Toronto in the unit)
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        tzdata \
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

# 5. C3G logos (set by entrypoint.sh): full logo centred on the home page (skin.blurb -> images/c3g_logo_new_full_colour_EN.jpg),
#    emblem in the header (skin.right_logo -> images/c3g_logo.png), moved LEFT of the login button by one CSS rule appended
#    to cBioPortal's reactapp/styles.css (#rightHeaderContent is a flex row: login button, then the logo; no skin setting for this)
COPY c3g_logo.png c3g_logo_new_full_colour_EN.jpg /app/
RUN found=0; \
    for d in $(find /cbioportal-webapp -type d -name images); do \
        cp /app/c3g_logo.png /app/c3g_logo_new_full_colour_EN.jpg "${d}/"; echo "logos -> ${d}/"; found=1; \
    done; \
    [ "${found}" = 1 ] || echo "WARNING: no images/ folder under /cbioportal-webapp - the logos will not show"; \
    css=/cbioportal-webapp/reactapp/styles.css; \
    if grep -q '#rightHeaderContent' "${css}" 2>/dev/null; then \
        printf '\n/* c3g_cbioportal_instance: header logo left of the login button */\n.cbioportal-frontend #rightHeaderContent #institute-logo{order:-1;margin-left:0;margin-right:12px}\n' >> "${css}"; \
        echo "header logo CSS -> ${css}"; \
    else \
        echo "WARNING: #rightHeaderContent not in ${css} (cBioPortal changed?) - header logo stays right of the login button"; \
    fi

# 6. Launcher + report gatekeeper + data folder (/data = local disk: DB, config, logs; host also mongo/.
#    Snapshots come from /snapshots (shared storage); build inputs from /studies and /reports)
COPY entrypoint.sh reports_server.py /app/
RUN chmod 755 /app/entrypoint.sh /app/reports_server.py && mkdir -p /data

# 8080 = cBioPortal, 8090 = PCGR report gatekeeper (reports_server.py, behind nginx /reports/)
EXPOSE 8080 8090
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=60s --timeout=30s --start-period=15m --retries=3 \
    CMD ["/app/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
