#!/bin/bash
################################################################################
### c3g_cbioportal_instance - put a snapshot live (README "Step by step")
### Builder side (the host pod only mounts <shared>/snapshots read-only). One-off container, same image, on the
### builder's cores (BUILD_CPUSET) with a small memory cap, so it never takes from the host pod:
###   checks the snapshot (READY, cBioPortal version) -> shows what changes against <shared>/snapshots/CURRENT
###   (studies added / removed / rebuilt, groups changed, PCGR reports) -> asks -> writes CURRENT (atomic)
###   -> one line in <shared>/snapshots/promote.log.
### The host pod (CBIO_DB_SNAPSHOT=current) switches to it at its next scheduled sync (06:00 / 18:00) without a
### restart, or right away with: podman exec c3g-cbioportal /app/entrypoint.sh sync-now
### Rollback = promote the previous id.
################################################################################
set -euo pipefail

## CHANGE HERE ##
SNAPSHOT_ID=${1:?Usage: ./c3g-cbioportal-promote.sh <snapshot id> [--yes]   (ids: ls <shared>/snapshots)}
YES=${2:-}                                                  # --yes = no question (refused when a study would be removed,
                                                            #         unless CBIO_ALLOW_REMOVE=true)
SHARED=${SHARED:-/Path/to/YOUR/cbioportal_drop}             ## CHANGE HERE - ASK ## the data drop folder on this VM
SHARED_LABEL=${SHARED_LABEL-z}                              # SELinux label: z (local disk) | empty = none (NFS)
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}  ## CHANGE HERE ## same tag as the host pod
BUILD_CPUSET=${BUILD_CPUSET-6-7}                            ## CHANGE HERE ## the builder's cores (as in c3g-cbioportal-build.sh;
                                                            #   empty = no pinning, laptop test only)
CBIO_ALLOW_REMOVE=${CBIO_ALLOW_REMOVE:-false}

[ -d "${SHARED}/snapshots" ] || { echo "ERROR: ${SHARED}/snapshots not found (SHARED = the data drop folder)"; exit 1; }

TTY_OPTS=()
[ ! -t 0 ] || TTY_OPTS=(-it)                                # the confirmation question needs a terminal
CPUSET_ARGS=()
[ -z "${BUILD_CPUSET}" ] || CPUSET_ARGS=(--cpuset-cpus "${BUILD_CPUSET}")

podman run \
  --rm \
  ${TTY_OPTS[@]+"${TTY_OPTS[@]}"} \
  --name "c3g-cbioportal-promote-$$" \
  ${CPUSET_ARGS[@]+"${CPUSET_ARGS[@]}"} \
  --cpu-shares 128 \
  --memory 1g \
  -v "${SHARED}/snapshots":/snapshots${SHARED_LABEL:+:${SHARED_LABEL}} \
  -e CBIO_PROMOTED_BY="$(id -un)@$(hostname -s)" \
  -e CBIO_ALLOW_REMOVE="${CBIO_ALLOW_REMOVE}" \
  "${IMAGE}" promote "${SNAPSHOT_ID}" ${YES:+"${YES}"}


### How to run: ###
# (on the VM as genome, after deploy/c3g-cbioportal-build.sh printed "Snapshot ready: .../snapshots/<id>")
# SHARED=<shared> ./deploy/c3g-cbioportal-promote.sh <id>          # shows the change, asks y/N
# SHARED=<shared> ./deploy/c3g-cbioportal-promote.sh <old id>      # rollback
# cat <shared>/snapshots/CURRENT <shared>/snapshots/promote.log
# Local laptop test:
# SHARED=./shared SHARED_LABEL= BUILD_CPUSET= IMAGE=c3g_cbioportal_instance:dev ./deploy/c3g-cbioportal-promote.sh <id>
