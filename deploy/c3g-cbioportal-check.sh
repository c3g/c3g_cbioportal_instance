#!/bin/bash
################################################################################
### c3g_cbioportal_instance - check the drop folder, then build only what changed (README "Incremental builds")
### Run on the VM as genome, AFTER a transfer into <shared>/studies (and <shared>/reports) has finished.
### A cohort = one folder of <shared>/studies = one cBioPortal study (+ its PCGR / ORANGE reports in reports/<study_id>/).
###   1. one-off container (same image, the builder's cores, 2 GB): fingerprints every cohort and compares it with
###      CURRENT (the snapshot being served) -> prints NEW / CHANGED / SAME / REMOVED, with the samples added /
###      removed and the files changed, and writes the plan: <SCRATCH_ROOT>/plans/<snapshot id>.json
###   2. asks y/N (a typed 'yes' when cohorts would be removed)
###   3. runs deploy/c3g-cbioportal-build.sh <plan> in the capped builder pod:
###        incremental: CURRENT's database + every NEW / CHANGED cohort re-imported WHOLE (a sample added or updated
###                     -> its whole cohort is rebuilt), REMOVED cohorts removed, SAME cohorts kept as they are;
###        full:        empty database + every cohort - first build, FULL=true, an image upgrade (another image
###                     than CURRENT was built with), changed report settings.
### Nothing changed -> no build. The snapshot still has to be promoted (deploy/c3g-cbioportal-promote.sh <id>,
### or PROMOTE=true here, which promotes right after a good build, still asking first).
################################################################################
set -euo pipefail

## CHANGE HERE ##
YES=${1:-}                                                   # --yes = no question (refused when cohorts would be
                                                             #   removed, unless CBIO_ALLOW_REMOVE=true)
SHARED=${SHARED:-/Path/to/YOUR/cbioportal_drop}              ## CHANGE HERE - ASK ## the data drop folder on this VM
SHARED_LABEL=${SHARED_LABEL-z}                               # SELinux label: z (local disk) | empty = none (NFS)
SCRATCH_ROOT=${SCRATCH_ROOT:-/home/genome/cbioportal-build}  ## CHANGE HERE ## as in c3g-cbioportal-build.sh (plans/ go here)
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}   ## CHANGE HERE ## same tag as the host pod
BUILD_POD=${BUILD_POD:-c3g-cbioportal-build}
BUILD_CPUSET=${BUILD_CPUSET-6-7}                             ## CHANGE HERE ## the builder's cores (as in c3g-cbioportal-build.sh;
                                                             #   empty = no pinning, laptop test only)
CBIO_REPORTS_URL=${CBIO_REPORTS_URL:-https://cbioportal.c3g-app.sd4h.ca/reports}   # written into the snapshot
FULL=${FULL:-false}                                          # true = full rebuild (empty DB, every cohort)
CBIO_ALLOW_REMOVE=${CBIO_ALLOW_REMOVE:-false}
SNAPSHOT_ID=${SNAPSHOT_ID:-$(date '+%Y%m%d-%H%M%S')}

DIVIDER="=================================="; DIVIDER=$DIVIDER$DIVIDER

[ -z "${YES}" ] || [ "${YES}" == "--yes" ] || { echo "Usage: ./c3g-cbioportal-check.sh [--yes]"; exit 1; }
for d in studies reports snapshots; do
  [ -d "${SHARED}/${d}" ] || { echo "ERROR: ${SHARED}/${d} not found (SHARED = the data drop folder: studies/ reports/ snapshots/)"; exit 1; }
done
if podman pod exists "${BUILD_POD}"; then
  echo "ERROR: pod ${BUILD_POD} exists - a build is running. Check again when it has finished."
  exit 1
fi

## The image the build will use: its id decides "image upgrade -> full rebuild"
podman image exists "${IMAGE}" || podman pull "${IMAGE}"
IMAGE_ID=$(podman image inspect --format '{{.Id}}' "${IMAGE}")

PLAN_DIR=${SCRATCH_ROOT}/plans
PLAN=${PLAN_DIR}/${SNAPSHOT_ID}.json
mkdir -p "${PLAN_DIR}"
[ ! -e "${PLAN}" ] || { echo "ERROR: ${PLAN} already exists - use another SNAPSHOT_ID"; exit 1; }
RO=":ro${SHARED_LABEL:+,${SHARED_LABEL}}"                    # :ro,z
CPUSET_ARGS=()
[ -z "${BUILD_CPUSET}" ] || CPUSET_ARGS=(--cpuset-cpus "${BUILD_CPUSET}")

echo -e "\n ${DIVIDER} \n Check ${SHARED}/studies against CURRENT ($(cat "${SHARED}/snapshots/CURRENT" 2>/dev/null || echo none)) \n Image: ${IMAGE} \n\n"
set +e
podman run \
  --rm \
  --name "c3g-cbioportal-check-${SNAPSHOT_ID}" \
  ${CPUSET_ARGS[@]+"${CPUSET_ARGS[@]}"} \
  --cpu-shares 128 \
  --memory 2g \
  -v "${SHARED}/studies":/studies${RO} \
  -v "${SHARED}/reports":/reports${RO} \
  -v "${SHARED}/snapshots":/snapshots${RO} \
  -v "${PLAN_DIR}":/plan:Z \
  -e CBIO_SNAPSHOT_ID="${SNAPSHOT_ID}" \
  -e CBIO_IMAGE_ID="${IMAGE_ID}" \
  -e CBIO_FULL_BUILD="${FULL}" \
  -e CBIO_REPORTS_URL="${CBIO_REPORTS_URL}" \
  "${IMAGE}" check "/plan/${SNAPSHOT_ID}.json" 2>&1 | tee "${PLAN_DIR}/${SNAPSHOT_ID}.check.log"
rc=${PIPESTATUS[0]}
set -e

case "${rc}" in
  3)    echo -e "\n Nothing to build: the drop folder matches CURRENT. \n"; exit 0 ;;
  0|10) ;;
  *)    echo -e "\n CHECK FAILED (exit ${rc}) - nothing built. Log: ${PLAN_DIR}/${SNAPSHOT_ID}.check.log \n"; exit "${rc}" ;;
esac
[ -s "${PLAN}" ] || { echo "ERROR: the check wrote no plan (${PLAN})"; exit 1; }

echo
if [ "${YES}" == "--yes" ]; then
  [ "${rc}" -ne 10 ] || [ "${CBIO_ALLOW_REMOVE}" == "true" ] \
    || { echo "Cohorts would be REMOVED - not built with --yes. Run it in a terminal to confirm, or add CBIO_ALLOW_REMOVE=true"; exit 1; }
elif [ -t 0 ]; then
  if [ "${rc}" -eq 10 ]; then
    read -r -p "Cohorts would DISAPPEAR from the new snapshot. Type 'yes' to build ${SNAPSHOT_ID} anyway: " ans || ans=""
    [ "${ans}" == "yes" ] || { echo "Not built (plan kept: ${PLAN})"; exit 1; }
  else
    read -r -p "Build snapshot ${SNAPSHOT_ID} as planned above? [y/N] " ans || ans=""
    [[ "${ans}" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Not built (plan kept: ${PLAN})"; exit 1; }
  fi
else
  echo "ERROR: no terminal to ask for confirmation - run it in a terminal, or pass --yes"; exit 1
fi

## The build re-checks that the cohorts to import did not change since this check
exec env SHARED="${SHARED}" SHARED_LABEL="${SHARED_LABEL}" SCRATCH_ROOT="${SCRATCH_ROOT}" IMAGE="${IMAGE}" \
  BUILD_POD="${BUILD_POD}" BUILD_CPUSET="${BUILD_CPUSET}" CBIO_REPORTS_URL="${CBIO_REPORTS_URL}" \
  "$(dirname "$0")/c3g-cbioportal-build.sh" "${PLAN}"


### How to run: ###
# (on the VM as genome, inside tmux - a build can take hours; only after the transfer into the drop folder finished)
# SHARED=<shared> ./deploy/c3g-cbioportal-add.sh <study_folder> <oncoanalyser_output> [<pcgr_output>]
#                                                            # the study folder (replaced whole) + its PCGR / ORANGE reports
# SHARED=<shared> ./deploy/c3g-cbioportal-check.sh           # shows NEW / CHANGED / SAME / REMOVED, asks, builds
# FULL=true SHARED=<shared> ./deploy/c3g-cbioportal-check.sh # full rebuild (every cohort, empty DB)
# PROMOTE=true SHARED=<shared> ./deploy/c3g-cbioportal-check.sh   # + promote right after a good build (asks again)
# SHARED=<shared> ./deploy/c3g-cbioportal-promote.sh <id>    # put it live
# ls ${SCRATCH_ROOT:-/home/genome/cbioportal-build}/plans/   # every plan + its check log
# Local laptop test (podman machine):
# SHARED=./shared SCRATCH_ROOT=./scratch IMAGE=c3g_cbioportal_instance:dev BUILD_CPUSET= CHECK_CGROUPS=false SHARED_LABEL= \
#   MEMORY=8g CBIO_REPORTS_URL=http://localhost:8090/reports ./deploy/c3g-cbioportal-check.sh
