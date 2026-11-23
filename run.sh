#!/bin/bash
################################################################################
### c3g_cbioportal_instance - the exact `podman run` commands for the C3G webapp VM (= Host VM; it only serves.
### Snapshots are made on the Build VM by deploy/c3g-cbioportal-build.sh)
### (web-app-template "Handing off to a maintainer": hand over these commands verbatim).
###   c3g-cbioportal : the portal, = deploy/c3g-cbioportal.service
###   (OPA, deploy/c3g-cbioportal-opa.service, is the FUTURE access mode - not started here)
### Same flags as the units, minus the systemd-only ones (--cidfile, --cgroups, --sdnotify, --rm).
### Needs the two podman secrets (README "How to Run" step 2), the volume (step 1)
### and a ghcr.io login (private image, step 2).
################################################################################

## CHANGE HERE ##
OIDC_ISSUER=${OIDC_ISSUER:?set OIDC_ISSUER (COmanage issuer URL)}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID:?set OIDC_CLIENT_ID (from the COmanage client registration)}
HOST_PORT=${HOST_PORT:-8080}           ## CHANGE HERE - ASK ## host port on the VM, agree it with the maintainer
REPORTS_HOST_PORT=${REPORTS_HOST_PORT:-8090}   ## CHANGE HERE - ASK ## host port of the PCGR report gatekeeper
                                               ## (nginx: location /reports/ -> this port, README "PCGR reports")
VOLUME=${VOLUME:-/home/genome/cbioportal-volume}
SHARED_SNAPSHOTS=${SHARED_SNAPSHOTS:?set SHARED_SNAPSHOTS (<shared>/snapshots on this VM)}   ## CHANGE HERE - ASK ##
CBIO_DB_SNAPSHOT=${CBIO_DB_SNAPSHOT:-current}   # current = follow <shared>/snapshots/CURRENT (promote) | <id> = pinned
CBIO_SYNC_TIMES=${CBIO_SYNC_TIMES:-06:00 18:00}   # scheduled sync: snapshot check + users.tsv (local time, TZ)
TZ_HOST=${TZ_HOST:-America/Toronto}
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}

## The portal (who can log in: /data/access/users.tsv on the volume, README "Who can see what")
podman run \
  -d \
  --replace \
  --name c3g-cbioportal \
  --stop-timeout=300 \
  -v "${VOLUME}":/data:Z \
  -v "${SHARED_SNAPSHOTS}":/snapshots:ro \
  -e CBIO_DB_SNAPSHOT="${CBIO_DB_SNAPSHOT}" \
  -e TZ="${TZ_HOST}" \
  -e CBIO_SYNC_TIMES="${CBIO_SYNC_TIMES}" \
  --secret C3G_CBIOPORTAL_OIDC_CLIENT_SECRET,type=env,target=OIDC_CLIENT_SECRET \
  --secret C3G_CBIOPORTAL_CH_PASSWORD,type=env,target=CLICKHOUSE_PASSWORD \
  -e OIDC_ISSUER="${OIDC_ISSUER}" \
  -e OIDC_CLIENT_ID="${OIDC_CLIENT_ID}" \
  --label io.containers.autoupdate=registry \
  --network slirp4netns:allow_host_loopback=true \
  -p "${REPORTS_HOST_PORT}":8090 \
  -p "${HOST_PORT}":8080 "${IMAGE}"


### How to run: ###
# OIDC_ISSUER=<issuer_url> OIDC_CLIENT_ID=<client_id> \
#   SHARED_SNAPSHOTS=<shared>/snapshots ./run.sh                  # serves CURRENT (promote on the Build VM)
# podman exec c3g-cbioportal /app/entrypoint.sh sync-now          # switch to a newly promoted snapshot now
# podman logs -f c3g-cbioportal
# podman exec c3g-cbioportal /app/entrypoint.sh users      # who can log in
