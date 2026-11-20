#!/bin/bash
#SBATCH --account=def-c3g             ## CHANGE HERE ## Cardinal (SD4H) account; rrg-bourqueg-ad does not exist on Cardinal
#SBATCH --time=12:00:00               ## CHANGE HERE ## build (~15 min seed + imports) + time to look at the portal
#SBATCH --mem=24G                     # one container at a time: builder (importer 8 GB + ClickHouse 8 GB), then host
#SBATCH --cpus-per-task 8
#SBATCH --signal=B:TERM@600           # 10 min before the time limit: ordered `podman stop -t 300` (ClickHouse last)
#SBATCH --job-name=cbio_sd4h_test
#SBATCH --output=job_outs/cbio_sd4h_test_%j.o
################################################################################
### c3g_cbioportal_instance - SD4H Slurm test (branch sd4h_test): Build VM + Host VM in ONE Slurm job on Cardinal
### As close as possible to the VMs: same image, same podman (rootless), same deploy/c3g-cbioportal-build.sh,
### same `podman run` flags as run.sh / deploy/c3g-cbioportal.service, same shared layout (studies/ reports/
### manifests/ snapshots/), ClickHouse on local disk only.
###
###   1/5 podman setup   rootless podman 5.7.1 (module), storage + runtime on the node's local disk ($SLURM_TMPDIR)
###   2/5 image          IMAGE_SOURCE=archive (default): podman load the newest <TEST_DIR>/image/*_amd64.tar made by
###                      sd4h_slurm/build-image-archive.sh off Cardinal | build: this clone's Containerfile (needs a subuid
###                      range) | pull: IMAGE from ghcr.io (needs podman login)
###   3/5 Build VM       deploy/c3g-cbioportal-build.sh <manifest> -> <SHARED>/snapshots/<id>/ (skipped if CBIO_DB_SNAPSHOT set)
###   4/5 Host VM        podman run c3g-cbioportal (= run.sh), serves the snapshot; waits for "All services up"
###   5/5 serve          stays up until the job ends / scancel; healthcheck every 5 min; logs copied to <SHARED>/test_logs/
###
### Differences from the VMs (all forced by the Slurm node, everything else is the same):
###   - OIDC login works as on the VM (same COmanage client), but the callback is the tunnel's:
###       OIDC_REDIRECT_URI = http://localhost:<HOST_PORT>/login/oauth2/code/cbio-idp   (register it on the client)
###     The browser must open http://localhost:<HOST_PORT> (not 127.0.0.1). Login is ON when the issuer, client id
###     and client secret are found (SECRETS_DIR); otherwise CBIO_AUTH=false (no login) with a warning.
###   - Secrets (OIDC client secret, users.tsv) come from SECRETS_DIR (chmod 700, files 600) on the project
###     storage, not from podman secrets created by hand: the job loads them into the same podman secret names.
###   - Ports are published on 127.0.0.1 of the node only, reached by an SSH tunnel (printed in the job log).
###     Other users with a job on the SAME node could reach 127.0.0.1 too (login still required when ON).
###   - CBIO_REPORTS_URL / CBIO_PORTAL_ORIGIN = http://localhost:<port> (the tunnel), written into the snapshot.
###   - No systemd: --cgroups=disabled instead of --cgroups=no-conmon / --sdnotify / --cidfile, no --memory
###     (rootless + cgroupfs cannot set limits; Slurm --mem is the cap), --no-healthcheck (no systemd timers;
###     the same /app/entrypoint.sh healthcheck is run by this script instead).
###   - No subuid range for the user on Cardinal: single-uid user namespace + ignore_chown_errors (storage.conf).
###   - No pasta on Cardinal: slirp4netns for every container, `podman build` RUN steps included (containers.conf).
###   - The host volume (/data: local DB copy, MongoDB, logs) is on $SLURM_TMPDIR, deleted at the end of the job
###     (the VM keeps it). Snapshots on <SHARED> stay, so a later job can serve one with CBIO_DB_SNAPSHOT=<id>.
###   - Host ports 28080 / 28090 (+20000, as on Narval) instead of 8080 / 8090.
################################################################################

## CHANGE HERE ##
MANIFEST=${1:-}                                               # manifest name in <SHARED>/manifests/ (build step)
TEST_DIR=${TEST_DIR:?set TEST_DIR=/Path/to/YOUR/test_dir (throwaway test area on /project; sbatch passes it)}  ## CHANGE HERE ##
SHARED=${SHARED:-${TEST_DIR}/shared}                          # = the VMs' shared storage (studies/ reports/ manifests/ snapshots/)
SECRETS_DIR=${SECRETS_DIR:-${TEST_DIR}/secrets}               # chmod 700. Temporary place for the test secrets:
                                                              #   oidc_client_secret  (600) the COmanage client secret
                                                              #   users.tsv           (600) who can log in (= /data/access/users.tsv on the VM)
                                                              #   oidc_issuer, oidc_client_id  (not secret; or pass them as env vars)
                                                              # (templates: sd4h_slurm/secrets.example/, one '# example' line each)
value_of() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | head -n 1 | tr -d '\r\n'; }   # first non-comment line
OIDC_ISSUER=${OIDC_ISSUER:-$(value_of "${SECRETS_DIR}/oidc_issuer")}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID:-$(value_of "${SECRETS_DIR}/oidc_client_id")}
OIDC_SECRET_FILE=${SECRETS_DIR}/oidc_client_secret
OIDC_CLIENT_SECRET_VALUE=$(value_of "${OIDC_SECRET_FILE}")    # never exported, never printed
USERS_TSV=${USERS_TSV:-${SECRETS_DIR}/users.tsv}
CBIO_AUTH=${CBIO_AUTH:-auto}                                  # auto = oauth2 when issuer + client id + secret are found | oauth2 | false
CBIO_DB_SNAPSHOT=${CBIO_DB_SNAPSHOT:-}                        # set = skip the build, serve this existing snapshot
IMAGE_SOURCE=${IMAGE_SOURCE:-archive}                         # archive | build | pull (see 2/5 above)
IMAGE_ARCHIVE=${IMAGE_ARCHIVE:-}                              # archive: the .tar; empty = newest ${TEST_DIR}/image/*_amd64.tar
IMAGE=${IMAGE:-ghcr.io/c3g/c3g_cbioportal_instance:latest}    # pull only: image to pull (same tag on Build and Host, as on the VMs)
HOST_PORT=${HOST_PORT:-28080}                                 # portal, on 127.0.0.1 of the node (VM: 8080)
REPORTS_HOST_PORT=${REPORTS_HOST_PORT:-28090}                 # PCGR report server (VM: 8090)
READY_TIMEOUT_MIN=${READY_TIMEOUT_MIN:-30}                    # host start (copy snapshot, migration, webapp)
HEALTH_SECS=${HEALTH_SECS:-300}
REGISTRY_AUTH_FILE=${REGISTRY_AUTH_FILE:-${HOME}/.config/containers/auth.json}   # `podman login ghcr.io` (How to run)
REPO_DIR=${REPO_DIR:-${SLURM_SUBMIT_DIR:-$(pwd)}}             # this repo's checkout on Cardinal (submit from its root)
JOB_TMP=${SLURM_TMPDIR:-/localscratch/${USER}.${SLURM_JOB_ID:-nojob}.0}   # node-local disk (Cardinal TmpFS=/localscratch)

CTR=c3g-cbioportal                                            # same container name as the VM
CBIO_REPORTS_URL=http://localhost:${REPORTS_HOST_PORT}/reports
CBIO_PORTAL_ORIGIN=http://localhost:${HOST_PORT}
OIDC_REDIRECT_URI=http://localhost:${HOST_PORT}/login/oauth2/code/cbio-idp   # register this callback on the OIDC client
NODE=$(hostname -s)
WORK=${JOB_TMP}/cbio
HOSTDATA=${WORK}/hostdata                                     # = /home/genome/cbioportal-volume on the Host VM
SCRATCH_ROOT=${WORK}/buildscratch                             # = SCRATCH_ROOT on the Build VM (local disk)
LOGS_OUT=${SHARED}/test_logs/${SLURM_JOB_ID:-nojob}

DIVIDER="=================================="; DIVIDER=$DIVIDER$DIVIDER
log() { echo -e "\n ${DIVIDER} \n $* \n\n"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "${REPO_DIR}/deploy/c3g-cbioportal-build.sh" ] || die "REPO_DIR=${REPO_DIR} is not the repo checkout (sbatch from its root)"
for d in studies reports manifests snapshots; do
  [ -d "${SHARED}/${d}" ] || die "${SHARED}/${d} not found (mkdir -p ${SHARED}/{studies,reports,manifests,snapshots})"
done
if [ -z "${CBIO_DB_SNAPSHOT}" ]; then
  [ -n "${MANIFEST}" ] || die "give a manifest (sbatch ... <manifest>) or CBIO_DB_SNAPSHOT=<id> to serve an existing snapshot"
  [ -s "${SHARED}/manifests/${MANIFEST}" ] || die "${SHARED}/manifests/${MANIFEST} not found or empty"
fi
[ -d "${JOB_TMP}" ] || mkdir -p "${JOB_TMP}" || die "no node-local disk at ${JOB_TMP}"

## Login: on when the OIDC settings are there. Secrets must be private (no group / other permission bits)
private() { local m; m=$(stat -c %a "$1") && (( (8#${m} & 8#077) == 0 )); }
if [ "${CBIO_AUTH}" == "auto" ]; then
  if [ -n "${OIDC_ISSUER}" ] && [ -n "${OIDC_CLIENT_ID}" ] && [ -n "${OIDC_CLIENT_SECRET_VALUE}" ]; then CBIO_AUTH=oauth2; else CBIO_AUTH=false; fi
fi
case "${CBIO_AUTH}" in
  oauth2)
    [ -n "${OIDC_ISSUER}" ] || die "CBIO_AUTH=oauth2: no issuer (OIDC_ISSUER or ${SECRETS_DIR}/oidc_issuer)"
    [ -n "${OIDC_CLIENT_ID}" ] || die "CBIO_AUTH=oauth2: no client id (OIDC_CLIENT_ID or ${SECRETS_DIR}/oidc_client_id)"
    [ -n "${OIDC_CLIENT_SECRET_VALUE}" ] || die "CBIO_AUTH=oauth2: no client secret in ${OIDC_SECRET_FILE} (only comment lines, or missing)"
    private "${SECRETS_DIR}" || die "${SECRETS_DIR} is readable by others: chmod 700 ${SECRETS_DIR}"
    private "${OIDC_SECRET_FILE}" || die "${OIDC_SECRET_FILE} is readable by others: chmod 600 ${OIDC_SECRET_FILE}"
    if [ -s "${USERS_TSV}" ]; then
      private "${USERS_TSV}" || die "${USERS_TSV} is readable by others (personal data): chmod 600 ${USERS_TSV}"
    else
      echo "WARNING: ${USERS_TSV} not found - the portal starts but NOBODY can log in (fail closed, as on the VM)"
    fi
    ;;
  false) echo "WARNING: no OIDC settings in ${SECRETS_DIR} (or CBIO_AUTH=false): the portal runs WITHOUT login" ;;
  *) die "CBIO_AUTH must be auto, oauth2 or false (got '${CBIO_AUTH}')" ;;
esac


################################################################################
### Stop in order on scancel --signal=TERM --batch / time limit (--signal=B:TERM@600), copy the logs out
CLEANED=0
cleanup() {
  [ "${CLEANED}" = 0 ] || return 0; CLEANED=1
  command -v podman >/dev/null 2>&1 || return 0      # failed before step 1: nothing started
  set +e
  log "Stopping ${CTR} (ordered, up to 300 s) and saving logs to ${LOGS_OUT}"
  podman stop --ignore -t 300 "${CTR}"
  mkdir -p -m 700 "${LOGS_OUT}"; chmod 700 "${LOGS_OUT}"     # logs can name samples: not for the whole group
  podman logs "${CTR}" > "${LOGS_OUT}/podman_logs_${CTR}.txt" 2>&1
  [ ! -d "${HOSTDATA}/logs" ] || cp -r "${HOSTDATA}/logs" "${LOGS_OUT}/host_logs"
  for b in "${SCRATCH_ROOT}"/build_*; do [ ! -d "${b}/logs" ] || cp -r "${b}/logs" "${LOGS_OUT}/$(basename "${b}")_logs"; done
  podman rm -f --ignore "${CTR}"
  podman secret rm C3G_CBIOPORTAL_CH_PASSWORD C3G_CBIOPORTAL_OIDC_CLIENT_SECRET >/dev/null 2>&1
  echo "Done. ${JOB_TMP} (podman storage, host volume, build scratch) is removed by Slurm at job end."
}
trap 'cleanup; exit 0' TERM INT
trap 'cleanup' EXIT


################################################################################
log "1/5 podman setup on ${NODE} (job ${SLURM_JOB_ID:-none}, local disk ${JOB_TMP})"
module purge && module load StdEnv/2023 podman/5.7.1

mkdir -p "${WORK}/podman/storage" "${WORK}/podman/tmp" "${HOSTDATA}" "${SCRATCH_ROOT}" "${REPO_DIR}/job_outs"
mkdir -p -m 700 "${WORK}/podman/run"
export XDG_RUNTIME_DIR=${WORK}/podman/run                     # no /run/user/<uid> on compute nodes
export TMPDIR=${WORK}/podman/tmp
export REGISTRY_AUTH_FILE

## Storage on local disk (not ~/.local/share/containers on Ceph); single-uid namespace -> ignore_chown_errors
export CONTAINERS_STORAGE_CONF=${WORK}/podman/storage.conf
cat > "${CONTAINERS_STORAGE_CONF}" <<EOF
[storage]
driver = "overlay"
graphroot = "${WORK}/podman/storage"
runroot = "${WORK}/podman/run/storage"
[storage.options.overlay]
ignore_chown_errors = "true"
# if native overlay fails on this node: mount_program = "/cvmfs/soft.computecanada.ca/gentoo/2023/x86-64-v3/usr/bin/fuse-overlayfs"
EOF
## No systemd / journald on the node
export CONTAINERS_CONF=${WORK}/podman/containers.conf
cat > "${CONTAINERS_CONF}" <<EOF
[containers]
log_driver = "k8s-file"
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
image_copy_tmp_dir = "${WORK}/podman/tmp"
[network]
# podman 5 defaults to pasta, not installed on Cardinal: slirp4netns for podman build RUN steps too (run: = VM flag)
default_rootless_network_cmd = "slirp4netns"
EOF
PODMAN_EXTRA_OPTS="--cgroups=disabled"

## Same podman env for `podman exec` from an ssh session on this node: source it first
cat > "${WORK}/podman_env.sh" <<EOF
module purge && module load StdEnv/2023 podman/5.7.1
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} TMPDIR=${TMPDIR} REGISTRY_AUTH_FILE=${REGISTRY_AUTH_FILE}
export CONTAINERS_STORAGE_CONF=${CONTAINERS_STORAGE_CONF} CONTAINERS_CONF=${CONTAINERS_CONF}
EOF

podman info --format 'rootless={{.Host.Security.Rootless}} cgroups={{.Host.CgroupsVersion}}/{{.Host.CgroupManager}} runtime={{.Host.OCIRuntime.Name}} storage={{.Store.GraphDriverName}} uidmap={{.Host.IDMappings.UIDMap}}' \
  || die "podman does not work on ${NODE}"
echo "SELinux: $(getenforce 2>/dev/null || echo 'n/a')   (VM: shared storage is mounted WITHOUT :Z - same here)"


################################################################################
case "${IMAGE_SOURCE}" in
archive)
  [ -n "${IMAGE_ARCHIVE}" ] || IMAGE_ARCHIVE=$(ls -t "${TEST_DIR}"/image/*_amd64.tar 2>/dev/null | head -n 1)
  [ -s "${IMAGE_ARCHIVE}" ] || die "no image archive (${IMAGE_ARCHIVE:-${TEST_DIR}/image/*_amd64.tar}): build it off Cardinal with
     sd4h_slurm/build-image-archive.sh and copy the .tar + .sha256 to ${TEST_DIR}/image/ (README 'SD4H Slurm test' step 2)"
  log "2/5 Image: podman load ${IMAGE_ARCHIVE}"
  if [ -s "${IMAGE_ARCHIVE}.sha256" ]; then
    ( cd "$(dirname "${IMAGE_ARCHIVE}")" && sha256sum -c "$(basename "${IMAGE_ARCHIVE}").sha256" ) \
      || die "checksum does not match: copy incomplete or changed? (${IMAGE_ARCHIVE}.sha256)"
  else
    echo "WARNING: no ${IMAGE_ARCHIVE}.sha256 - the copy is not checked"
  fi
  IMAGE=$(podman load -i "${IMAGE_ARCHIVE}" | sed -n 's/^Loaded image: *//p' | tail -n 1)
  [ -n "${IMAGE}" ] || die "podman load ${IMAGE_ARCHIVE} failed (log above)"
  ARCH=$(podman image inspect --format '{{.Architecture}}' "${IMAGE}")
  [ "${ARCH}" == "amd64" ] || die "${IMAGE} is built for '${ARCH}', not amd64 (build-image-archive.sh uses --platform linux/amd64)"
  echo "Loaded ${IMAGE}: $(podman image inspect --format 'release {{index .Labels "org.opencontainers.image.version"}}, commit {{index .Labels "org.opencontainers.image.revision"}}, {{.Architecture}}' "${IMAGE}")"
  ;;
build)
  IMAGE=localhost/c3g_cbioportal_instance:sd4h_test
  GIT_REV=$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)
  [ -z "$(git -C "${REPO_DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ] || GIT_REV="${GIT_REV}+local-changes"
  log "2/5 Image: podman build ${REPO_DIR}/Containerfile (git ${GIT_REV}) -> ${IMAGE}"
  ## SLURM: single-uid user namespace -> apt cannot switch to its _apt sandbox user. This apt setting is mounted
  ## only while the RUN steps run (-v), it is not in the image and the Containerfile is unchanged.
  printf 'APT::Sandbox::User "root";\n' > "${WORK}/podman/99-sd4h-no-apt-sandbox"
  ## --format docker keeps the HEALTHCHECK (OCI format drops it), as the GitHub buildah workflow does
  podman build --format docker \
    -v "${WORK}/podman/99-sd4h-no-apt-sandbox":/etc/apt/apt.conf.d/99-sd4h-no-apt-sandbox:ro \
    --label org.opencontainers.image.revision="${GIT_REV}" \
    -t "${IMAGE}" -f "${REPO_DIR}/Containerfile" "${REPO_DIR}" || die "podman build failed (log above)
     Without a subuid range on this cluster the mongodb install (chown) fails: use IMAGE_SOURCE=archive"
  ;;
pull)
  log "2/5 Image: podman pull ${IMAGE}"
  if [[ "${IMAGE}" == ghcr.io/* ]] && [ ! -s "${REGISTRY_AUTH_FILE}" ]; then
    die "${IMAGE} is private and ${REGISTRY_AUTH_FILE} is missing: on the login node run
     module load StdEnv/2023 podman/5.7.1 && podman login ghcr.io --authfile ${REGISTRY_AUTH_FILE}   (GitHub token with read:packages)"
  fi
  podman pull "${IMAGE}" || die "podman pull ${IMAGE} failed"
  ;;
*) die "IMAGE_SOURCE must be archive, build or pull (got '${IMAGE_SOURCE}')" ;;
esac
echo "cBioPortal version in the image: $(podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" | grep '^CBIO_VERSION=' || echo unknown)"


################################################################################
if [ -z "${CBIO_DB_SNAPSHOT}" ]; then
  CBIO_DB_SNAPSHOT=$(date '+%Y%m%d-%H%M%S')
  log "3/5 Build VM: snapshot ${CBIO_DB_SNAPSHOT} from manifests/${MANIFEST} (deploy/c3g-cbioportal-build.sh, unchanged flow)"
  SHARED="${SHARED}" SCRATCH_ROOT="${SCRATCH_ROOT}" IMAGE="${IMAGE}" SNAPSHOT_ID="${CBIO_DB_SNAPSHOT}" \
    MEMORY="" PODMAN_EXTRA_OPTS="${PODMAN_EXTRA_OPTS}" CBIO_REPORTS_URL="${CBIO_REPORTS_URL}" \
    bash "${REPO_DIR}/deploy/c3g-cbioportal-build.sh" "${MANIFEST}" || die "build failed (logs: ${LOGS_OUT} after cleanup)"
else
  log "3/5 Build VM: skipped, serving the existing snapshot ${CBIO_DB_SNAPSHOT}"
  echo "NOTE: its PCGR report links point to the CBIO_REPORTS_URL it was built with (this job: ${CBIO_REPORTS_URL})"
fi
[ -f "${SHARED}/snapshots/${CBIO_DB_SNAPSHOT}/READY" ] || die "${SHARED}/snapshots/${CBIO_DB_SNAPSHOT}/READY not found"


################################################################################
log "4/5 Host VM: ${CTR} serving snapshot ${CBIO_DB_SNAPSHOT} (= run.sh, login: ${CBIO_AUTH})"
## Same secret names / mechanism as the VM (README "For web app maintainers"), filled from SECRETS_DIR
python3 -c 'import secrets; print(secrets.token_hex(16), end="")' | podman secret create --replace C3G_CBIOPORTAL_CH_PASSWORD - >/dev/null
if [ "${CBIO_AUTH}" == "oauth2" ]; then
  printf '%s' "${OIDC_CLIENT_SECRET_VALUE}" | podman secret create --replace C3G_CBIOPORTAL_OIDC_CLIENT_SECRET - >/dev/null
  AUTH_ARGS=(--secret C3G_CBIOPORTAL_OIDC_CLIENT_SECRET,type=env,target=OIDC_CLIENT_SECRET
             -e OIDC_ISSUER="${OIDC_ISSUER}" -e OIDC_CLIENT_ID="${OIDC_CLIENT_ID}"
             -e OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI}")
  ## Who can log in: VM = /home/genome/cbioportal-volume/access/users.tsv; here a copy on the node-local volume
  mkdir -p -m 700 "${HOSTDATA}/access"
  [ ! -s "${USERS_TSV}" ] || install -m 600 "${USERS_TSV}" "${HOSTDATA}/access/users.tsv"
  echo "OIDC: issuer ${OIDC_ISSUER}, client id ${OIDC_CLIENT_ID}, callback ${OIDC_REDIRECT_URI}"
else
  AUTH_ARGS=(-e CBIO_AUTH=false)
fi

## = run.sh / deploy/c3g-cbioportal.service. Changed lines are marked "## SLURM:"
podman run \
  -d \
  --replace \
  --name "${CTR}" \
  --stop-timeout=300 \
  --cgroups=disabled                                    `## SLURM: VM unit has --cgroups=no-conmon (systemd)` \
  --no-healthcheck                                      `## SLURM: no systemd timers; checked by this script` \
  -v "${HOSTDATA}":/data:Z                              `## SLURM: node-local disk, VM: /home/genome/cbioportal-volume` \
  -v "${SHARED}/snapshots":/snapshots:ro \
  -e CBIO_DB_SNAPSHOT="${CBIO_DB_SNAPSHOT}" \
  --secret C3G_CBIOPORTAL_CH_PASSWORD,type=env,target=CLICKHOUSE_PASSWORD \
  "${AUTH_ARGS[@]}"                                     `## SLURM: = VM OIDC secret + -e lines, callback = tunnel` \
  -e CBIO_REPORTS_URL="${CBIO_REPORTS_URL}"             `## SLURM: tunnel URL` \
  -e CBIO_PORTAL_ORIGIN="${CBIO_PORTAL_ORIGIN}"         `## SLURM: tunnel URL` \
  --label io.containers.autoupdate=registry \
  --network slirp4netns:allow_host_loopback=true \
  -p 127.0.0.1:"${REPORTS_HOST_PORT}":8090              `## SLURM: 127.0.0.1 only, VM: -p 8090:8090` \
  -p 127.0.0.1:"${HOST_PORT}":8080 "${IMAGE}"           `## SLURM: 127.0.0.1 only, VM: -p 8080:8080` \
  || die "podman run ${CTR} failed"

echo "Waiting up to ${READY_TIMEOUT_MIN} min for 'All services up' (podman logs ${CTR})"
ready=0
for _ in $(seq 1 $((READY_TIMEOUT_MIN * 6))); do
  if podman logs "${CTR}" 2>&1 | grep -q "All services up"; then ready=1; break; fi
  [ "$(podman inspect --format '{{.State.Running}}' "${CTR}" 2>/dev/null)" == "true" ] || break
  sleep 10 & wait $!
done
podman logs --tail 40 "${CTR}" 2>&1
[ "${ready}" = 1 ] || die "${CTR} did not come up (exited, or not ready after ${READY_TIMEOUT_MIN} min)"
podman exec "${CTR}" /app/entrypoint.sh snapshots
podman exec "${CTR}" /app/entrypoint.sh studies


################################################################################
log "5/5 Serving on ${NODE}: 127.0.0.1:${HOST_PORT} (portal), 127.0.0.1:${REPORTS_HOST_PORT} (reports)

 On your laptop (2 hops: laptop -> login node -> ${NODE}; the login-node end is a unix socket in a 700 folder,
 so other users on the login node can not use the tunnel):

   ssh -t \\
     -L ${HOST_PORT}:/tmp/cbio_tunnel_${USER}/portal.sock -L ${REPORTS_HOST_PORT}:/tmp/cbio_tunnel_${USER}/reports.sock \\
     ${USER}@cardinal.sd4h.ca \\
     'mkdir -p -m 700 /tmp/cbio_tunnel_${USER} && ssh -N -o StreamLocalBindUnlink=yes \\
        -L /tmp/cbio_tunnel_${USER}/portal.sock:127.0.0.1:${HOST_PORT} \\
        -L /tmp/cbio_tunnel_${USER}/reports.sock:127.0.0.1:${REPORTS_HOST_PORT} ${NODE}'

   then open ${CBIO_PORTAL_ORIGIN}   (login: ${CBIO_AUTH}; use 'localhost', the OIDC callback is ${OIDC_REDIRECT_URI})

 Commands (ssh ${NODE}, then: source ${WORK}/podman_env.sh):
   podman exec ${CTR} /app/entrypoint.sh studies | snapshots | users | healthcheck
   Change who can log in (as on the VM, applied at the next login):
     install -m 600 ${USERS_TSV} ${HOSTDATA}/access/users.tsv && podman exec ${CTR} /app/entrypoint.sh sync-access
 Stop cleanly:  scancel --signal=TERM --batch ${SLURM_JOB_ID:-<jobid>}   (plain scancel kills after 30 s)"

while true; do
  sleep "${HEALTH_SECS}" & wait $!
  [ "$(podman inspect --format '{{.State.Running}}' "${CTR}" 2>/dev/null)" == "true" ] || die "${CTR} stopped on its own"
  if podman exec "${CTR}" /app/entrypoint.sh healthcheck >/dev/null 2>&1; then
    echo "$(date '+%F %T') healthcheck OK"
  else
    echo "$(date '+%F %T') healthcheck FAILED"
  fi
done


### How to run: ###
## (same steps, with more detail: README "SD4H Slurm test")
## 0. Once: the repo on Cardinal + shared layout + the image file (built off Cardinal, see build-image-archive.sh)
# (Cardinal) export TEST_DIR=/Path/to/YOUR/test_dir; T=${TEST_DIR}
#            cd ${T} && git clone -b sd4h_test git@github.com:c3g/c3g_cbioportal_instance.git
#            mkdir -p ${T}/shared/{studies,reports,manifests,snapshots} && mkdir -p -m 700 ${T}/secrets
#            mkdir -p ${T}/image   # <- c3g_cbioportal_instance_<release>_<commit>_amd64.tar + .sha256 (scp from the Mac)
#            (only for IMAGE_SOURCE=pull) module load StdEnv/2023 podman/5.7.1 && podman login ghcr.io --authfile ~/.config/containers/auth.json
## 0b. Login (optional; without it the portal runs with no login). Callback on the COmanage client:
#      http://localhost:28080/login/oauth2/code/cbio-idp
# cp sd4h_slurm/secrets.example/* ${T}/secrets/ && chmod 600 ${T}/secrets/*      # templates: one '# example' line each
# nano ${T}/secrets/oidc_client_secret   # add the real value on a new line under the comment (never in git)
# nano ${T}/secrets/oidc_issuer ${T}/secrets/oidc_client_id ${T}/secrets/users.tsv   # same; users.tsv is TAB-separated
## 1. Inputs (as on the Build VM): study folder (meta_study.txt with groups:), PCGR reports, manifest
# SH=${T}/shared
# cp -r <study_folder> ${SH}/studies/
# mkdir -p ${SH}/reports/<cancer_study_identifier> && cp <...>.pcgr_acmg.grch38.flexdb.html ${SH}/reports/<cancer_study_identifier>/
# echo <study_folder> > ${SH}/manifests/test.txt
## 2. Submit from the repo root (build + serve)
# cd ${T}/c3g_cbioportal_instance && mkdir -p job_outs
# sbatch sd4h_slurm/c3g-cbioportal-slurm.sh test.txt
# IMAGE_ARCHIVE=${T}/image/<file>.tar sbatch sd4h_slurm/c3g-cbioportal-slurm.sh test.txt   # a given image file, not the newest
# IMAGE_SOURCE=pull IMAGE=ghcr.io/c3g/c3g_cbioportal_instance:v2.1.0 sbatch ...   # published image (podman login first)
# CBIO_DB_SNAPSHOT=<id> sbatch sd4h_slurm/c3g-cbioportal-slurm.sh                # serve / roll back to an existing snapshot
## 3. Follow + tunnel (the exact tunnel command is in the log at step 5/5)
# tail -f job_outs/cbio_sd4h_test_<jobid>.o
## 4. Stop cleanly (ordered shutdown + logs to ${SH}/test_logs/<jobid>/)
# scancel --signal=TERM --batch <jobid>
