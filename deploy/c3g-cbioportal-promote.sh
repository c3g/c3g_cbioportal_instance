#!/bin/bash
################################################################################
### c3g_cbioportal_instance - put a snapshot live (README "Add / update a study")
### Runs on the Build VM (the only VM that mounts <shared>/snapshots read-write). One-off container, same image:
###   checks the snapshot (READY, cBioPortal version) -> shows what changes against <shared>/snapshots/CURRENT
###   (studies added / removed / rebuilt, groups changed, PCGR reports) -> asks -> writes CURRENT (atomic)
###   -> one line in <shared>/snapshots/promote.log.
### The Host VM (CBIO_DB_SNAPSHOT=current) switches to it at its next scheduled sync (06:00 / 18:00) without a
### restart, or right away with: podman exec c3g-cbioportal /app/entrypoint.sh sync-now
### Rollback = promote the previous id.
################################################################################
set -euo pipefail

## CHANGE HERE ##
SNAPSHOT_ID=${1:?Usage: ./c3g-cbioportal-promote.sh <snapshot id> [--yes]   (ids: ls <shared>/snapshots)}
YES=${2:-}                                                  # --yes = no question (refused when a study would be removed,
                                                            #         unless CBIO_ALLOW_REMOVE=true)
SHARED=${SHARED:-/mnt/cbioportal-shared/cbioportal}         ## CHANGE HERE - ASK ## shared SD4H storage on this VM
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}  ## CHANGE HERE ## same tag as the Host VM
CBIO_ALLOW_REMOVE=${CBIO_ALLOW_REMOVE:-false}

[ -d "${SHARED}/snapshots" ] || { echo "ERROR: ${SHARED}/snapshots not found (shared storage mounted?)"; exit 1; }

TTY_OPTS=()
[ ! -t 0 ] || TTY_OPTS=(-it)                                # the confirmation question needs a terminal

podman run \
  --rm \
  ${TTY_OPTS[@]+"${TTY_OPTS[@]}"} \
  --name "c3g-cbioportal-promote-$$" \
  -v "${SHARED}/snapshots":/snapshots \
  -e CBIO_PROMOTED_BY="$(id -un)@$(hostname -s)" \
  -e CBIO_ALLOW_REMOVE="${CBIO_ALLOW_REMOVE}" \
  "${IMAGE}" promote "${SNAPSHOT_ID}" ${YES:+"${YES}"}


### How to run: ###
# (on the Build VM, after deploy/c3g-cbioportal-build.sh printed "Snapshot ready: .../snapshots/<id>")
# SHARED=<shared>/cbioportal ./deploy/c3g-cbioportal-promote.sh <id>          # shows the change, asks y/N
# SHARED=<shared>/cbioportal ./deploy/c3g-cbioportal-promote.sh <old id>      # rollback
# cat <shared>/cbioportal/snapshots/CURRENT <shared>/cbioportal/snapshots/promote.log
# Local laptop test:
# SHARED=./shared IMAGE=c3g_cbioportal_instance:dev ./deploy/c3g-cbioportal-promote.sh <id>
