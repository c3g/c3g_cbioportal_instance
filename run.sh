#!/bin/bash
################################################################################
### c3g_cbioportal_instance - the exact `podman run` commands for the C3G webapp VM
### (web-app-template "Handing off to a maintainer": hand over these commands verbatim).
###   1. c3g-cbioportal-opa : the app's own OPA (study -> group decisions), = deploy/c3g-cbioportal-opa.service
###   2. c3g-cbioportal     : the portal,                                  = deploy/c3g-cbioportal.service
### Same flags as the units, minus the systemd-only ones (--cidfile, --cgroups, --sdnotify, --rm).
### Needs the two podman secrets (README "How to Run" step 2), the volume (step 1)
### and a ghcr.io login (private image, step 2).
################################################################################

## CHANGE HERE ##
OIDC_ISSUER=${OIDC_ISSUER:?set OIDC_ISSUER (COmanage issuer URL)}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID:?set OIDC_CLIENT_ID (from the COmanage client registration)}
OPA_BUNDLE=${OPA_BUNDLE:?set OPA_BUNDLE (c3g_cbioportal policy bundle from c3g-opa-policies)}   ## CHANGE HERE - ASK ##
HOST_PORT=${HOST_PORT:-8080}           ## CHANGE HERE - ASK ## host port on the VM, agree it with the maintainer
OPA_HOST_PORT=${OPA_HOST_PORT:-8181}   ## CHANGE HERE - ASK ## 127.0.0.1 port of this app's OPA
OPA_IMAGE=${OPA_IMAGE:-docker.io/openpolicyagent/opa:1.4.2}   ## CHANGE HERE ## pin the current OPA 1.x
VOLUME=${VOLUME:-/home/genome/cbioportal-volume}
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}

## 1. OPA first: without it the portal hides every study (fail closed)
podman run \
  -d \
  --replace \
  --name c3g-cbioportal-opa \
  --network slirp4netns:allow_host_loopback=true \
  -p 127.0.0.1:"${OPA_HOST_PORT}":8181 \
  "${OPA_IMAGE}" \
  run --server --addr 0.0.0.0:8181 --bundle "${OPA_BUNDLE}"

## 2. The portal
podman run \
  -d \
  --replace \
  --name c3g-cbioportal \
  --stop-timeout=300 \
  -v "${VOLUME}":/data:Z \
  --secret C3G_CBIOPORTAL_OIDC_CLIENT_SECRET,type=env,target=OIDC_CLIENT_SECRET \
  --secret C3G_CBIOPORTAL_CH_PASSWORD,type=env,target=CLICKHOUSE_PASSWORD \
  -e OIDC_ISSUER="${OIDC_ISSUER}" \
  -e OIDC_CLIENT_ID="${OIDC_CLIENT_ID}" \
  -e OPA_URL="http://10.0.2.2:${OPA_HOST_PORT}" \
  --label io.containers.autoupdate=registry \
  --network slirp4netns:allow_host_loopback=true \
  -p "${HOST_PORT}":8080 "${IMAGE}"


### How to run: ###
# OIDC_ISSUER=<issuer_url> OIDC_CLIENT_ID=<client_id> OPA_BUNDLE=<bundle_url> ./run.sh
# podman logs -f c3g-cbioportal
# curl -s -X POST http://127.0.0.1:8181/v1/data/c3g_cbioportal/authz/study_access   # what OPA allows
