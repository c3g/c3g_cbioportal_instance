#!/bin/bash
################################################################################
### c3g_cbioportal_instance - build a DB snapshot on the Build VM (README "Build VM")
### One-off container (same image as the Host VM): empty ClickHouse on LOCAL scratch -> schema + seed ->
### offline-validate + import every study of the manifest (+ PCGR report tabs) -> stop ClickHouse ->
### publish <shared>/snapshots/<id>/ (READY written last). The host then serves it (CBIO_DB_SNAPSHOT=<id>).
### ClickHouse never runs on the shared storage: it is only the hand-off area.
###
### <shared> layout (SD4H storage mounted on the Build VM and on the Host VM):
###   studies/<folder>/            study folders (pipeline output)          -> /studies   (read-only)
###   reports/<study_id>/*.html    PCGR flexdb reports                      -> /reports   (read-only)
###   manifests/<name>.txt         one study folder per line (# comments)   -> /manifests (read-only)
###   snapshots/<id>/              written by this script only              -> /snapshots
################################################################################
set -euo pipefail

## CHANGE HERE ##
MANIFEST=${1:?Usage: ./c3g-cbioportal-build.sh <manifest name in <shared>/manifests/, e.g. portal.txt>}
SHARED=${SHARED:-/mnt/cbioportal-shared/cbioportal}          ## CHANGE HERE - ASK ## shared SD4H storage on this VM
SCRATCH_ROOT=${SCRATCH_ROOT:-/home/genome/cbioportal-build}  ## CHANGE HERE ## LOCAL disk (not the shared storage)
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}   ## CHANGE HERE ## same tag as the Host VM
MEMORY=${MEMORY-18g}                                         # container cap: importer JVM (8 GB) + ClickHouse (8 GB) + slack
                                                             # MEMORY= (empty) -> no --memory (SD4H Slurm test: the job's --mem caps it)
PODMAN_EXTRA_OPTS=${PODMAN_EXTRA_OPTS:-}                     # extra `podman run` flags; VM: none. SD4H Slurm test: --cgroups=disabled
CBIO_IMPORT_JAVA_OPTS=${CBIO_IMPORT_JAVA_OPTS:--Xms2G -Xmx8G}
CH_MAX_MEMORY=${CH_MAX_MEMORY:-8589934592}                   # bytes (8 GB)
CBIO_REPORTS_URL=${CBIO_REPORTS_URL:-https://cbioportal.c3g-app.sd4h.ca/reports}   # written into the snapshot
OPA_URL=${OPA_URL:-}                                         # optional: warn about studies OPA does not list
SNAPSHOT_ID=${SNAPSHOT_ID:-$(date '+%Y%m%d-%H%M%S')}

DIVIDER="=================================="; DIVIDER=$DIVIDER$DIVIDER

for d in studies reports manifests snapshots; do
  [ -d "${SHARED}/${d}" ] || { echo "ERROR: ${SHARED}/${d} not found (shared storage mounted? layout in the header)"; exit 1; }
done
[ -s "${SHARED}/manifests/${MANIFEST}" ] || { echo "ERROR: manifest ${SHARED}/manifests/${MANIFEST} not found or empty"; exit 1; }

## A new, empty scratch folder per build (the builder refuses a non-empty DB)
SCRATCH=${SCRATCH_ROOT}/build_${SNAPSHOT_ID}
mkdir -p "${SCRATCH_ROOT}"
mkdir "${SCRATCH}"

echo -e "\n ${DIVIDER} \n Build snapshot ${SNAPSHOT_ID} from manifests/${MANIFEST} \n Scratch: ${SCRATCH} \n Image:   ${IMAGE} \n\n"
cat "${SHARED}/manifests/${MANIFEST}"

OPA_ARGS=()
[ -z "${OPA_URL}" ] || OPA_ARGS=(-e OPA_URL="${OPA_URL}")
MEMORY_ARGS=()
[ -z "${MEMORY}" ] || MEMORY_ARGS=(--memory "${MEMORY}")
EXTRA_ARGS=()
[ -z "${PODMAN_EXTRA_OPTS}" ] || read -r -a EXTRA_ARGS <<< "${PODMAN_EXTRA_OPTS}"

set +e
podman run \
  --rm \
  --name "c3g-cbioportal-build-${SNAPSHOT_ID}" \
  ${MEMORY_ARGS[@]+"${MEMORY_ARGS[@]}"} \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  --stop-timeout=150 \
  -v "${SCRATCH}":/data:Z \
  -v "${SHARED}/studies":/studies:ro \
  -v "${SHARED}/reports":/reports:ro \
  -v "${SHARED}/manifests":/manifests:ro \
  -v "${SHARED}/snapshots":/snapshots \
  -e CBIO_SNAPSHOT_ID="${SNAPSHOT_ID}" \
  -e CBIO_IMAGE_REF="${IMAGE}" \
  -e CBIO_REPORTS_URL="${CBIO_REPORTS_URL}" \
  -e CBIO_IMPORT_JAVA_OPTS="${CBIO_IMPORT_JAVA_OPTS}" \
  -e CH_MAX_MEMORY="${CH_MAX_MEMORY}" \
  ${OPA_ARGS[@]+"${OPA_ARGS[@]}"} \
  "${IMAGE}" build "/manifests/${MANIFEST}" 2>&1 | tee "${SCRATCH}/build.log"
rc=${PIPESTATUS[0]}
set -e

if [ "${rc}" -eq 0 ]; then
  cp "${SCRATCH}/build.log" "${SHARED}/snapshots/${SNAPSHOT_ID}/logs/build.log" 2>/dev/null || true
  echo -e "\n ${DIVIDER} \n Snapshot ready: ${SHARED}/snapshots/${SNAPSHOT_ID} \n Host VM: CBIO_DB_SNAPSHOT=${SNAPSHOT_ID}, restart (README 'Add / update a study') \n Scratch ${SCRATCH} can be removed. \n\n"
else
  echo -e "\n ${DIVIDER} \n BUILD FAILED (exit ${rc}) - logs: ${SCRATCH}/build.log and ${SCRATCH}/logs/ \n\n"
fi
exit "${rc}"


### How to run: ###
# (on the Build VM; study folders, reports and the manifest already on the shared storage)
# cp -r <study_folder> ${SHARED}/studies/
# mkdir -p ${SHARED}/reports/<cancer_study_identifier> && cp <group>.pcgr_acmg.grch38.flexdb.html ... ${SHARED}/reports/<cancer_study_identifier>/
# echo <study_folder> >> ${SHARED}/manifests/portal.txt            # the FULL list of studies the portal serves
# SHARED=<shared>/cbioportal ./c3g-cbioportal-build.sh portal.txt
# OPA_URL=http://<opa_host>:8181 SHARED=... ./c3g-cbioportal-build.sh portal.txt   # + OPA warnings
# Local laptop test (no login on the host):
# SHARED=./shared SCRATCH_ROOT=./scratch IMAGE=c3g_cbioportal_instance:dev MEMORY=12g \
#   CBIO_REPORTS_URL=http://localhost:8090/reports ./deploy/c3g-cbioportal-build.sh test.txt
