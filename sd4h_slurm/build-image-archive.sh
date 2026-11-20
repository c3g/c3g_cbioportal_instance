#!/bin/bash
################################################################################
### c3g_cbioportal_instance - build the amd64 image OUTSIDE Cardinal and save it as a file (SD4H Slurm test)
### Why: on Cardinal, rootless podman has a single uid (no subuid range), so the mongodb-org-server install
### (chown to the mongodb user) fails in `podman build`, and there is no ghcr login there. Loading a finished
### image works, so: build here (e.g. the Mac's podman machine, amd64 by emulation) -> copy -> the Slurm job loads it
### (sd4h_slurm/c3g-cbioportal-slurm.sh, IMAGE_SOURCE=archive, the default).
###
###   1/4 export the git ref (default: newest v* release tag) into a temp folder (working tree untouched)
###   2/4 podman build --platform linux/amd64 --format docker (keeps HEALTHCHECK, as the GitHub workflow)
###   3/4 check: amd64, cBioPortal version
###   4/4 podman save -> <OUT_DIR>/c3g_cbioportal_instance_<ref>_<commit>_amd64.tar + .sha256
################################################################################
set -euo pipefail

## CHANGE HERE ##
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: run this inside the repo clone"; exit 1; }
cd "${REPO}"
git fetch --tags origin 2>/dev/null || echo "WARNING: git fetch --tags failed - using the tags this clone already has"
REF=${1:-$(git tag -l 'v*' --sort=-v:refname | head -n 1)}  # git ref to build: release tag (default newest v*), branch, HEAD
OUT_DIR=${OUT_DIR:-${REPO}/image_archives}                   ## CHANGE HERE ## where the .tar goes (git-ignored)
PLATFORM=${PLATFORM:-linux/amd64}                            # Cardinal nodes and the webapp VM are amd64

DIVIDER="=================================="; DIVIDER=$DIVIDER$DIVIDER
log() { echo -e "\n ${DIVIDER} \n $* \n\n"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "${REF}" ] || die "no git ref given and no v* tag in this clone (git fetch --tags)"
REV=$(git rev-parse --short "${REF}^{commit}" 2>/dev/null) || die "unknown git ref '${REF}' (git fetch --tags?)"
REF_ID=$(printf '%s' "${REF}" | tr -c 'A-Za-z0-9_.-' '_')
TAG=localhost/c3g_cbioportal_instance:${REF_ID}-${REV}-amd64
FILE=c3g_cbioportal_instance_${REF_ID}_${REV}_amd64.tar
podman info >/dev/null 2>&1 || die "podman does not answer (Mac: podman machine start)"

CTX=$(mktemp -d)
trap 'rm -rf "${CTX}"' EXIT

log "1/4 Export ${REF} (commit ${REV}) -> ${CTX}"
git archive "${REF}" | tar -x -C "${CTX}"
[ -f "${CTX}/Containerfile" ] || die "${REF} has no Containerfile"

log "2/4 podman build --platform ${PLATFORM} -> ${TAG}"
## --pull=always: the base images are fetched for PLATFORM (a local arm64 copy with the same tag is never reused)
podman build --platform "${PLATFORM}" --pull=always --format docker \
  --label org.opencontainers.image.revision="${REV}" \
  --label org.opencontainers.image.version="${REF}" \
  -t "${TAG}" -f "${CTX}/Containerfile" "${CTX}"

log "3/4 Check ${TAG}"
ARCH=$(podman image inspect --format '{{.Architecture}}' "${TAG}")
[ "${ARCH}" == "amd64" ] || die "built for '${ARCH}', not amd64"
CBIO=$(podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${TAG}" | sed -n 's/^CBIO_VERSION=//p')
HC=$(podman image inspect --format '{{if .Config.Healthcheck}}yes{{else}}NO{{end}}' "${TAG}")
echo "architecture=${ARCH}  cBioPortal=${CBIO:-unknown}  healthcheck=${HC}  ref=${REF}  commit=${REV}"

log "4/4 podman save -> ${OUT_DIR}/${FILE}"
mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}/${FILE}"
podman save --format docker-archive -o "${OUT_DIR}/${FILE}" "${TAG}"
( cd "${OUT_DIR}" && shasum -a 256 "${FILE}" > "${FILE}.sha256" )
ls -lh "${OUT_DIR}/${FILE}"
log "Done. Copy both files to <TEST_DIR>/image/ on Cardinal (README 'SD4H Slurm test' step 2):
   scp ${OUT_DIR}/${FILE} ${OUT_DIR}/${FILE}.sha256 <user>@cardinal.sd4h.ca:<TEST_DIR>/image/
 The Slurm job loads the newest *_amd64.tar there (or IMAGE_ARCHIVE=<file>)."


### How to run: ###
# (Mac, repo clone root; podman machine running, >= 4 GB RAM)
# ./sd4h_slurm/build-image-archive.sh                 # newest v* release tag (after git fetch --tags)
# ./sd4h_slurm/build-image-archive.sh v2.1.0          # a given release
# ./sd4h_slurm/build-image-archive.sh HEAD            # the current commit (uncommitted changes are NOT included)
# OUT_DIR=/Path/to/YOUR/archives ./sd4h_slurm/build-image-archive.sh
