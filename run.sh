#!/bin/bash
################################################################################
### c3g_cbioportal_instance - the exact podman commands for the HOST POD on the C3G VM
### (web-app-template "Handing off to a maintainer": hand over these commands verbatim).
### One VM, two pods (README "How it works"):
###   host pod    c3g-cbioportal        these commands: portal + its OPA, always on
###   builder pod c3g-cbioportal-build  deploy/c3g-cbioportal-build.sh (one build, then removed; capped)
###   0. pod c3g-cbioportal   : network + ports,                            = deploy/c3g-cbioportal-pod.service
###   1. c3g-cbioportal-opa   : the app's own OPA (study -> group decisions), = deploy/c3g-cbioportal-opa.service
###   2. c3g-cbioportal       : the portal,                                  = deploy/c3g-cbioportal.service
### Same flags as the units, minus the systemd-only ones (--cidfile, --pod-id-file, --cgroups, --sdnotify, --rm).
### Needs the two podman secrets (README "For hosting" step 2), the volume (step 1)
### and a ghcr.io login (private image, step 2).
################################################################################

## CHANGE HERE ##
OIDC_ISSUER=${OIDC_ISSUER:?set OIDC_ISSUER (COmanage issuer URL)}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID:?set OIDC_CLIENT_ID (from the COmanage client registration)}
OPA_BUNDLE=${OPA_BUNDLE:?set OPA_BUNDLE (c3g_cbioportal policy bundle from c3g-opa-policies)}   ## CHANGE HERE - ASK ##
HOST_PORT=${HOST_PORT:-8080}           ## CHANGE HERE - ASK ## host port on the VM, agree it with the maintainer
REPORTS_HOST_PORT=${REPORTS_HOST_PORT:-8090}   ## CHANGE HERE - ASK ## host port of the report gatekeeper (PCGR / ORANGE)
                                               ## (nginx: location /reports/ -> this port, README "Reports")
OPA_HOST_PORT=${OPA_HOST_PORT:-8181}   ## CHANGE HERE - ASK ## VM 127.0.0.1 port of this app's OPA (curl checks, build warnings)
OPA_IMAGE=${OPA_IMAGE:-docker.io/openpolicyagent/opa:1.4.2}   ## CHANGE HERE ## pin the current 1.x
VOLUME=${VOLUME:-/home/genome/cbioportal-volume}
SHARED_SNAPSHOTS=${SHARED_SNAPSHOTS:?set SHARED_SNAPSHOTS (<shared>/snapshots: the data drop folder on this VM)}   ## CHANGE HERE - ASK ##
SHARED_LABEL=${SHARED_LABEL-z}         # SELinux label of the shared folder: z (local disk, shared with the builder pod)
                                       # | empty = none (NFS: never relabel)
CBIO_DB_SNAPSHOT=${CBIO_DB_SNAPSHOT:-current}   # current = follow <shared>/snapshots/CURRENT (promote) | <id> = pinned
CBIO_SYNC_TIMES=${CBIO_SYNC_TIMES:-06:00 18:00}   # scheduled sync: snapshot check + OPA access (local time, TZ)
HOST_MEMORY_RESERVATION=${HOST_MEMORY_RESERVATION:-12g}   # portal memory.low (no hard cap on the host)
TZ_HOST=${TZ_HOST:-America/Toronto}
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}

## 0. The host pod: one network namespace for the portal and its OPA (OPA = 127.0.0.1:8181 inside the pod).
##    No resource cap here: the builder pod is the one that is capped.
podman pod create \
  --replace \
  --name c3g-cbioportal \
  --network slirp4netns:allow_host_loopback=true \
  -p 127.0.0.1:"${OPA_HOST_PORT}":8181 \
  -p "${REPORTS_HOST_PORT}":8090 \
  -p "${HOST_PORT}":8080

## 1. OPA first: without it the portal hides every study (fail closed)
podman run \
  -d \
  --replace \
  --pod c3g-cbioportal \
  --name c3g-cbioportal-opa \
  "${OPA_IMAGE}" \
  run --server --addr 0.0.0.0:8181 --bundle "${OPA_BUNDLE}"

## 2. The portal (study access: OPA x COmanage token groups, README "Who can see what")
podman run \
  -d \
  --replace \
  --pod c3g-cbioportal \
  --name c3g-cbioportal \
  --stop-timeout=300 \
  --memory-reservation "${HOST_MEMORY_RESERVATION}" \
  -v "${VOLUME}":/data:Z \
  -v "${SHARED_SNAPSHOTS}":/snapshots:ro${SHARED_LABEL:+,${SHARED_LABEL}} \
  -e CBIO_DB_SNAPSHOT="${CBIO_DB_SNAPSHOT}" \
  -e TZ="${TZ_HOST}" \
  -e CBIO_SYNC_TIMES="${CBIO_SYNC_TIMES}" \
  --secret C3G_CBIOPORTAL_OIDC_CLIENT_SECRET,type=env,target=OIDC_CLIENT_SECRET \
  --secret C3G_CBIOPORTAL_CH_PASSWORD,type=env,target=CLICKHOUSE_PASSWORD \
  -e OIDC_ISSUER="${OIDC_ISSUER}" \
  -e OIDC_CLIENT_ID="${OIDC_CLIENT_ID}" \
  -e CBIO_AUTHZ=opa \
  -e OPA_URL="http://127.0.0.1:8181" \
  --label io.containers.autoupdate=registry \
  "${IMAGE}"


### How to run: ###
# OIDC_ISSUER=<issuer_url> OIDC_CLIENT_ID=<client_id> OPA_BUNDLE=<bundle_url> \
#   SHARED_SNAPSHOTS=<shared>/snapshots ./run.sh                  # serves CURRENT (promote, builder side)
# podman pod ps; podman ps --pod                                  # the host pod and its 2 containers (+ infra)
# podman exec c3g-cbioportal /app/entrypoint.sh sync-now          # switch to a newly promoted snapshot now
# podman logs -f c3g-cbioportal
# podman exec c3g-cbioportal /app/entrypoint.sh studies    # studies + groups (C3G_OPA_DENY = hidden)
# curl -s -X POST http://127.0.0.1:${OPA_HOST_PORT:-8181}/v1/data/c3g_cbioportal/authz/study_access   # what OPA allows
# podman pod stop -t 300 c3g-cbioportal                    # ordered shutdown (ClickHouse last)
