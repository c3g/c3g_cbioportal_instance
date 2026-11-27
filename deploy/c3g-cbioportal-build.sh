#!/bin/bash
################################################################################
### c3g_cbioportal_instance - build a DB snapshot in the BUILDER POD (README "How it works")
### One VM, two pods: the host pod (c3g-cbioportal, always on) serves; this script makes the builder pod
### (c3g-cbioportal-build) for ONE build and removes it at the end. The builder is capped so it can never take
### from the host: its own cores (BUILD_CPUSET), a hard memory limit (MEMORY, no swap), low CPU weight, and the
### kernel kills it first if the VM runs out of memory (BUILD_OOM_SCORE_ADJ). Only one build at a time (the pod
### name is the lock).
### Normally started by deploy/c3g-cbioportal-check.sh, which compares the drop folder with CURRENT and writes the
### plan this script takes (README "Incremental builds"). One-off container (same image as the host pod), ClickHouse
### on LOCAL scratch:
###   incremental: copy of CURRENT's database -> remove the REMOVED cohorts -> re-import each NEW / CHANGED cohort
###                whole (+ PCGR / ORANGE report tabs) -> compact;
###   full:        empty database -> schema + seed -> import every cohort;
### -> stop ClickHouse -> publish <shared>/snapshots/<id>/ (READY written last). The build first checks that the
### cohorts to import did not change since the check. Put it live with deploy/c3g-cbioportal-promote.sh <id>
### (or PROMOTE=true here): the host switches at its next scheduled sync, without a restart.
### ClickHouse never runs in the drop folder: it is only the hand-off area.
###
### <shared> layout (the data drop folder on this VM, seen by both pods):
###   studies/<folder>/            one folder per cBioPortal study (cohort)  -> /studies   (read-only)
###   reports/<study_id>/<files>   PCGR / ORANGE reports (report_types.tsv)  -> /reports   (read-only)
###   snapshots/<id>/              written by this script only               -> /snapshots (host pod: read-only)
################################################################################
set -euo pipefail

## CHANGE HERE ##
PLAN=${1:?Usage: ./c3g-cbioportal-build.sh <plan file> - normally run by deploy/c3g-cbioportal-check.sh, which makes the plan}
SHARED=${SHARED:-/Path/to/YOUR/cbioportal_drop}              ## CHANGE HERE - ASK ## the data drop folder on this VM
SHARED_LABEL=${SHARED_LABEL-z}                               # SELinux label: z (local disk, shared with the host pod)
                                                             # | empty = none (NFS: never relabel)
SCRATCH_ROOT=${SCRATCH_ROOT:-/home/genome/cbioportal-build}  ## CHANGE HERE ## LOCAL disk, room for ~2 snapshots
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}   ## CHANGE HERE ## same tag as the host pod
## Builder caps (README "Resources"): measured 1 core avg / 2.5 max, 2.7 GB real RAM for an 86-sample study
BUILD_POD=${BUILD_POD:-c3g-cbioportal-build}
BUILD_CPUSET=${BUILD_CPUSET-6-7}                             ## CHANGE HERE ## the builder's own cores (8 vCPU VM:
                                                             #   host uses all, the builder only these).
                                                             #   Empty = no pinning: laptop test ONLY (podman machine
                                                             #   has no cpuset controller; with CHECK_CGROUPS=false)
MEMORY=${MEMORY:-10g}                                        # hard cap, no swap: importer JVM (4 GB) + ClickHouse (4 GB) + slack
BUILD_CPU_SHARES=${BUILD_CPU_SHARES:-128}                    # CPU weight (default 1024): the host wins on shared cores
BUILD_OOM_SCORE_ADJ=${BUILD_OOM_SCORE_ADJ:-800}              # VM out of memory -> the build is killed, not the portal
BUILD_IO_WEIGHT=${BUILD_IO_WEIGHT:-}                         # optional --blkio-weight (10-1000); needs the io controller
                                                             #   and the BFQ disk scheduler, so off by default
CHECK_CGROUPS=${CHECK_CGROUPS:-true}                         # false = skip the cgroup check (laptop test only)
CBIO_IMPORT_JAVA_OPTS=${CBIO_IMPORT_JAVA_OPTS:--Xms1G -Xmx4G}
CH_MAX_MEMORY=${CH_MAX_MEMORY:-4294967296}                   # bytes (4 GB)
CBIO_REPORTS_URL=${CBIO_REPORTS_URL:-https://cbioportal.c3g-app.sd4h.ca/reports}   # written into the snapshot
OPA_URL=${OPA_URL:-}                                         # optional: warn about studies OPA does not list
                                                             #   (host pod's OPA: http://10.0.2.2:8181)
SNAPSHOT_ID=$(basename "${PLAN}" .json)                      # the plan is <SCRATCH_ROOT>/plans/<snapshot id>.json
PROMOTE=${PROMOTE:-false}                                    # true = run c3g-cbioportal-promote.sh after a good build
                                                             #        (still shows the change and asks)

DIVIDER="=================================="; DIVIDER=$DIVIDER$DIVIDER

for d in studies reports snapshots; do
  [ -d "${SHARED}/${d}" ] || { echo "ERROR: ${SHARED}/${d} not found (SHARED = the data drop folder; layout in the header)"; exit 1; }
done
[ -s "${PLAN}" ] || { echo "ERROR: plan ${PLAN} not found or empty - run deploy/c3g-cbioportal-check.sh"; exit 1; }
PLAN=$(cd "$(dirname "${PLAN}")" && pwd)/$(basename "${PLAN}")

## One build at a time: the builder pod's name is the lock
if podman pod exists "${BUILD_POD}"; then
  echo "ERROR: pod ${BUILD_POD} already exists - a build is running (or a crashed one left it behind):"
  podman ps -a --pod --filter "pod=${BUILD_POD}" --format '  {{.Names}}  {{.Status}}' || true
  echo "  Wait for it. If no build container is listed above: podman pod rm -f ${BUILD_POD}"
  exit 1
fi

## The caps must really apply: rootless podman can only set them for cgroup v2 controllers delegated to this user
if [ "${CHECK_CGROUPS}" == "true" ]; then
  cg_version=$(podman info --format '{{.Host.CgroupsVersion}}')
  cg_controllers=$(podman info --format '{{.Host.CgroupControllers}}')
  [ "${cg_version}" == "v2" ] || { echo "ERROR: cgroup ${cg_version}: the builder caps need cgroup v2"; exit 1; }
  missing=""
  for c in cpu ${BUILD_CPUSET:+cpuset} memory; do
    [[ " ${cg_controllers//[\[\]]/ } " == *" ${c} "* ]] || missing="${missing} ${c}"
  done
  if [ -n "${missing}" ]; then
    echo "ERROR: cgroup controller(s)${missing} not delegated to $(id -un) (have: ${cg_controllers})."
    echo "  Without them the builder is NOT capped and could slow the portal. Fix (admin, README 'For web app maintainers'):"
    echo "  /etc/systemd/system/user@.service.d/delegate.conf -> [Service] Delegate=cpu cpuset io memory pids"
    exit 1
  fi
  [ -z "${BUILD_IO_WEIGHT}" ] || [[ " ${cg_controllers//[\[\]]/ } " == *" io "* ]] \
    || { echo "ERROR: BUILD_IO_WEIGHT is set but the io controller is not delegated"; exit 1; }
  [ -n "${BUILD_CPUSET}" ] || { echo "ERROR: BUILD_CPUSET is empty (no core pinning) - laptop test only, with CHECK_CGROUPS=false"; exit 1; }
  ncpu=$(podman info --format '{{.Host.CPUs}}')
  max_core=$(echo "${BUILD_CPUSET}" | tr ',-' '\n\n' | sort -n | tail -1)
  [ "${max_core}" -lt "${ncpu}" ] || { echo "ERROR: BUILD_CPUSET=${BUILD_CPUSET} but this VM has ${ncpu} CPUs (0-$((ncpu - 1)))"; exit 1; }
fi

## A new, empty scratch folder per build (the builder refuses a non-empty DB)
SCRATCH=${SCRATCH_ROOT}/build_${SNAPSHOT_ID}
mkdir -p "${SCRATCH_ROOT}"
mkdir "${SCRATCH}"

## The image id: the build refuses to run if it is not the image the check planned with (an image upgrade
## in between -> run the check again, which then plans a full rebuild)
IMAGE_ID=$(podman image inspect --format '{{.Id}}' "${IMAGE}")

echo -e "\n ${DIVIDER} \n Build snapshot ${SNAPSHOT_ID} from plan ${PLAN} \n Scratch: ${SCRATCH} \n Image:   ${IMAGE} \n Builder pod ${BUILD_POD}: cores ${BUILD_CPUSET:-all (no pinning)}, memory ${MEMORY}, cpu-shares ${BUILD_CPU_SHARES}, oom-score-adj ${BUILD_OOM_SCORE_ADJ} \n\n"

OPA_ARGS=()
[ -z "${OPA_URL}" ] || OPA_ARGS=(-e OPA_URL="${OPA_URL}")
IO_ARGS=()
[ -z "${BUILD_IO_WEIGHT}" ] || IO_ARGS=(--blkio-weight "${BUILD_IO_WEIGHT}")
CPUSET_ARGS=()
[ -z "${BUILD_CPUSET}" ] || CPUSET_ARGS=(--cpuset-cpus "${BUILD_CPUSET}")
RO=":ro${SHARED_LABEL:+,${SHARED_LABEL}}"                    # :ro,z
RW="${SHARED_LABEL:+:${SHARED_LABEL}}"                       # :z

## The builder pod (removed on exit, also after Ctrl-C or a failure). slirp4netns + host loopback: the optional
## OPA warnings reach the host pod's OPA at 10.0.2.2:8181. Its own network namespace: its ClickHouse never meets
## the host's.
podman pod create \
  --name "${BUILD_POD}" \
  --network slirp4netns:allow_host_loopback=true \
  ${CPUSET_ARGS[@]+"${CPUSET_ARGS[@]}"} > /dev/null
trap 'podman pod rm -f -t 150 "${BUILD_POD}" > /dev/null 2>&1 || true' EXIT

set +e
podman run \
  --rm \
  --pod "${BUILD_POD}" \
  --name "c3g-cbioportal-build-${SNAPSHOT_ID}" \
  ${CPUSET_ARGS[@]+"${CPUSET_ARGS[@]}"} \
  --cpu-shares "${BUILD_CPU_SHARES}" \
  --memory "${MEMORY}" \
  --memory-swap "${MEMORY}" \
  --oom-score-adj "${BUILD_OOM_SCORE_ADJ}" \
  ${IO_ARGS[@]+"${IO_ARGS[@]}"} \
  --stop-timeout=150 \
  -v "${SCRATCH}":/data:Z \
  -v "${SHARED}/studies":/studies${RO} \
  -v "${SHARED}/reports":/reports${RO} \
  -v "${PLAN}":/plan.json:ro,Z \
  -v "${SHARED}/snapshots":/snapshots${RW} \
  -e CBIO_SNAPSHOT_ID="${SNAPSHOT_ID}" \
  -e CBIO_IMAGE_REF="${IMAGE}" \
  -e CBIO_IMAGE_ID="${IMAGE_ID}" \
  -e CBIO_REPORTS_URL="${CBIO_REPORTS_URL}" \
  -e CBIO_IMPORT_JAVA_OPTS="${CBIO_IMPORT_JAVA_OPTS}" \
  -e CH_MAX_MEMORY="${CH_MAX_MEMORY}" \
  ${OPA_ARGS[@]+"${OPA_ARGS[@]}"} \
  "${IMAGE}" build /plan.json 2>&1 | tee "${SCRATCH}/build.log"
rc=${PIPESTATUS[0]}
set -e

if [ "${rc}" -eq 0 ]; then
  cp "${SCRATCH}/build.log" "${SHARED}/snapshots/${SNAPSHOT_ID}/logs/build.log" 2>/dev/null || true
  echo -e "\n ${DIVIDER} \n Snapshot ready: ${SHARED}/snapshots/${SNAPSHOT_ID} \n Put it live: ./deploy/c3g-cbioportal-promote.sh ${SNAPSHOT_ID} (README 'Step by step') \n Scratch ${SCRATCH} can be removed. \n\n"
  if [ "${PROMOTE}" == "true" ]; then
    SHARED="${SHARED}" IMAGE="${IMAGE}" BUILD_CPUSET="${BUILD_CPUSET}" "$(dirname "$0")/c3g-cbioportal-promote.sh" "${SNAPSHOT_ID}" || rc=$?
  fi
else
  [ "${rc}" -ne 137 ] || echo " Exit 137 = killed: most likely the ${MEMORY} memory cap (raise MEMORY, CH_MAX_MEMORY, CBIO_IMPORT_JAVA_OPTS together)."
  echo -e "\n ${DIVIDER} \n BUILD FAILED (exit ${rc}) - logs: ${SCRATCH}/build.log and ${SCRATCH}/logs/ \n\n"
fi
exit "${rc}"


### How to run: ###
# (on the VM as genome, inside tmux - a build can take hours, a dropped ssh session must not stop it)
# Normally through the check, which plans and then calls this script:
# SHARED=<shared> ./deploy/c3g-cbioportal-check.sh
# Directly, with a plan the check wrote but you did not build at the time (it is re-verified first):
# SHARED=<shared> ./deploy/c3g-cbioportal-build.sh /home/genome/cbioportal-build/plans/<id>.json
# SHARED=<shared> ./deploy/c3g-cbioportal-promote.sh <id printed above>     # put it live (asks first)
# OPA_URL=http://10.0.2.2:8181 SHARED=<shared> ./deploy/c3g-cbioportal-check.sh   # + OPA warnings during the build
# podman pod ps; podman stats --no-stream                    # while it runs: the builder pod and its usage
# Local laptop test (no login on the host; podman machine):
# SHARED=./shared SCRATCH_ROOT=./scratch IMAGE=c3g_cbioportal_instance:dev BUILD_CPUSET= CHECK_CGROUPS=false SHARED_LABEL= \
#   MEMORY=8g CBIO_REPORTS_URL=http://localhost:8090/reports ./deploy/c3g-cbioportal-check.sh
