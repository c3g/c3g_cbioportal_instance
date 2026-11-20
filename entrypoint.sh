#!/bin/bash
################################################################################
### c3g_cbioportal_instance - container entrypoint
### One container = cBioPortal 7.1.2 webapp + ClickHouse server + MongoDB + session-service.
### Logic adapted from cbioportal-docker-compose:
###   ClickHouse -> schema/seed/derived tables (first launch only) -> schema migration
###   -> mongod -> session-service -> cBioPortal webapp (login through OIDC) -> report gatekeeper
###
### One image, two roles (README "Build VM" / "Host VM"):
###   BUILD VM  `build` imports the studies into a fresh ClickHouse DB on local scratch (/data) and publishes it
###             as a snapshot on the shared SD4H storage (/snapshots/<id>/). Never serves anything.
###   HOST VM   `start` copies the snapshot named by CBIO_DB_SNAPSHOT (read-only mount /snapshots) onto its local
###             /data/clickhouse and serves it. Never imports. ClickHouse never runs on the shared storage.
###
### Subcommands:
###   build <manifest>  (Build VM, one-off `podman run --rm`) manifest = one study folder of /studies per line.
###                     Empty DB -> schema + seed -> offline-validate + import every study -> stop ClickHouse ->
###                     publish /snapshots/<id>/ {clickhouse/, reports/, logs/, BUILD_INFO.json, READY (last)}.
###                     Reports in /reports/<study_id>/ (PCGR flexdb HTML) are linked to their samples as cBioPortal
###                     "resources" (generated in a staging copy; the study folder is not changed) and copied in.
###   start             (Host VM, default CMD) activate CBIO_DB_SNAPSHOT, then start every service, webapp + report
###                     gatekeeper last. On SIGTERM (podman stop) stops reports -> webapp -> session -> mongod -> ClickHouse.
###   snapshots         list the snapshots in /snapshots (READY, cBioPortal version, studies, which one is active)
###   studies           list the studies in the DB with their access groups (podman exec)
###   sync-access       re-apply OPA's study -> groups decisions now (podman exec; also runs every CBIO_OPA_SYNC_SECS)
###   healthcheck       exit 0 when every service answers (image HEALTHCHECK)
###
### Access:   authentication = cBioPortal's OIDC login (COmanage); decisions = OPA (the app's own OPA container,
###           policy c3g_cbioportal/authz from c3g-opa-policies); enforcement = cBioPortal's study filter, fed by
###           writing OPA's answer into cancer_study.groups. OPA unreachable -> every study hidden (fail closed).
###           CBIO_AUTHZ=meta_study = fallback for tests without OPA (meta_study.txt 'groups:' decides).
###           Reports (reports_server.py, port CBIO_REPORTS_PORT): served only when cBioPortal itself answers 200
###           to /api/studies/<study_id> with the viewer's session cookie (= same per-study access as the portal).
###
### Data:     /data (CBIO_DATA_DIR) = local disk, as in the C3G web-app-template. Must be /data in BOTH roles:
###           ClickHouse's internal symlinks are absolute (/data/clickhouse/store/...).
###             Host:  clickhouse/ (active snapshot copy, .snapshot_id), clickhouse.prev/, mongo/, config/, logs/
###             Build: clickhouse/, config/ (staging/, importer JAR), logs/, portalinfo/  (scratch, one per build)
###           /snapshots (CBIO_SNAPSHOTS_DIR) = shared SD4H storage: builder writes, host mounts read-only.
###           Build inputs (read-only): /studies/<folder>/ (pipeline output), /reports/<study_id>/ (PCGR HTML).
################################################################################
set -euo pipefail

CMD=${1:-start}
DIVIDER="=================================="; DIVIDER=$DIVIDER$DIVIDER

## CHANGE HERE ## defaults - every one can be overridden with `podman run -e VAR=...`
CBIO_PORT=${CBIO_PORT:-8080}
CBIO_AUTH=${CBIO_AUTH:-oauth2}                     # oauth2 | false (false = local testing ONLY)
OIDC_ISSUER=${OIDC_ISSUER:-}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID:-}
OIDC_REDIRECT_URI=${OIDC_REDIRECT_URI:-https://cbioportal.c3g-app.sd4h.ca/login/oauth2/code/cbio-idp}
OIDC_SCOPES=${OIDC_SCOPES:-openid,profile,email,org.cilogon.userinfo}
OIDC_CLIENT_AUTH_METHOD=${OIDC_CLIENT_AUTH_METHOD:-client_secret_basic}
OIDC_USERNAME_CLAIM=${OIDC_USERNAME_CLAIM:-email}
OIDC_ROLES_PATH=${OIDC_ROLES_PATH:-groups}
CBIO_FILTER_GROUPS_BY_APPNAME=${CBIO_FILTER_GROUPS_BY_APPNAME:-false}
CBIO_AUTHZ=${CBIO_AUTHZ:-opa}                      # opa | meta_study (meta_study = fallback for tests without OPA)
OPA_URL_FROM_ENV=${OPA_URL:-}                      # build: OPA is only asked (warning only) when OPA_URL is passed
OPA_URL=${OPA_URL:-http://10.0.2.2:8181}           # the app's own OPA container (host loopback, slirp4netns)
OPA_POLICY_PATH=${OPA_POLICY_PATH:-c3g_cbioportal/authz}   # Rego package c3g_cbioportal.authz
CBIO_OPA_SYNC_SECS=${CBIO_OPA_SYNC_SECS:-300}      # how often OPA's decisions are re-applied (5 min)
OPA_DENY_GROUP=${OPA_DENY_GROUP:-C3G_OPA_DENY}     # written to studies OPA does not allow - never create it in COmanage
CBIO_ALWAYS_SHOW_STUDY_GROUP=${CBIO_ALWAYS_SHOW_STUDY_GROUP:-}
CBIO_FORWARD_HEADERS=${CBIO_FORWARD_HEADERS:-framework}   # trust nginx X-Forwarded-* (https redirects)
CBIO_NCBI_BUILD=${CBIO_NCBI_BUILD:-38}
CBIO_UCSC_BUILD=${CBIO_UCSC_BUILD:-hg38}
CBIO_SKIN_TITLE=${CBIO_SKIN_TITLE:-C3G cBioPortal}
CBIO_RIGHT_LOGO=${CBIO_RIGHT_LOGO:-c3g_logo.svg}
CBIO_JAVA_OPTS=${CBIO_JAVA_OPTS:--Xms2g -Xmx4g}
CBIO_IMPORT_JAVA_OPTS=${CBIO_IMPORT_JAVA_OPTS:--Xms2G -Xmx8G}
SESSION_JAVA_OPTS=${SESSION_JAVA_OPTS:--Xms256m -Xmx1g}
CH_MAX_MEMORY=${CH_MAX_MEMORY:-8589934592}         # bytes (8 GB)
MONGO_CACHE_GB=${MONGO_CACHE_GB:-1}
CH_HTTP_PORT=${CH_HTTP_PORT:-8123}                 # internal ports (127.0.0.1 only)
CH_NATIVE_PORT=${CH_NATIVE_PORT:-9000}
SESSION_PORT=${SESSION_PORT:-5001}
MONGO_PORT=${MONGO_PORT:-27017}

## CHANGE HERE ## PCGR reports (README "PCGR reports")
CBIO_REPORTS_PORT=${CBIO_REPORTS_PORT:-8090}       # report gatekeeper (reports_server.py), published + behind nginx /reports/
CBIO_REPORTS_URL=${CBIO_REPORTS_URL:-https://cbioportal.c3g-app.sd4h.ca/reports}   # public base URL written into the study
CBIO_REPORT_SUFFIX=${CBIO_REPORT_SUFFIX:-.pcgr_acmg.grch38.flexdb.html}             # report = <SAMPLE_ID or PATIENT_ID><suffix>
CBIO_REPORT_NAME=${CBIO_REPORT_NAME:-PCGR report}                                 # tab name in the patient view
CBIO_REPORT_DESCRIPTION=${CBIO_REPORT_DESCRIPTION:-Personal Cancer Genome Reporter (PCGR) report for this sample}
CBIO_REPORT_OPEN_BY_DEFAULT=${CBIO_REPORT_OPEN_BY_DEFAULT:-true}                  # true = tab opens with the patient view
## portal origin allowed to embed the reports (CSP frame-ancestors); default = scheme://host of CBIO_REPORTS_URL
if [ -z "${CBIO_PORTAL_ORIGIN:-}" ] && [[ "${CBIO_REPORTS_URL}" =~ ^(https?://[^/]+) ]]; then
  CBIO_PORTAL_ORIGIN=${BASH_REMATCH[1]}
fi
CBIO_PORTAL_ORIGIN=${CBIO_PORTAL_ORIGIN:-}

## CHANGE HERE ## build / snapshot hand-off (README "Build VM" / "Host VM")
SNAPSHOTS=${CBIO_SNAPSHOTS_DIR:-/snapshots}        # shared SD4H storage: builder writes, host mounts read-only
CBIO_DB_SNAPSHOT=${CBIO_DB_SNAPSHOT:-}            # host: snapshot id to serve (= folder name in SNAPSHOTS)
CBIO_SNAPSHOT_ID=${CBIO_SNAPSHOT_ID:-$(date '+%Y%m%d-%H%M%S')}   # build: id of the snapshot it publishes
CBIO_IMAGE_REF=${CBIO_IMAGE_REF:-unknown}          # build: image tag, recorded in BUILD_INFO.json
CBIO_VERSION=${CBIO_VERSION:-unknown}              # set by the Containerfile (ENV); build and host must match

## Fixed paths / names (DATA itself can be moved with CBIO_DATA_DIR - same value in both roles)
DATA=${CBIO_DATA_DIR:-/data}                       # C3G web-app-template: app data under /data
STUDIES=${CBIO_STUDIES_DIR:-/studies}              # build input: study folders (read-only mount)
REPORTS=${CBIO_BUILD_REPORTS_DIR:-/reports}        # build input: reports/<study_id>/<SAMPLE_ID or PATIENT_ID><CBIO_REPORT_SUFFIX>
                                                   # (host: set to the active snapshot's reports/ by check_snapshot)
CONF=${DATA}/config
LOGS=${DATA}/logs
PORTALINFO=${DATA}/portalinfo
CH_BIN=/opt/clickhouse/clickhouse
CH_CONFIG=/app/config/clickhouse-config.xml
CH_DB=cbioportal
CH_USER=cbio_user
DB_SCRIPTS=/cbioportal/db-scripts/clickhouse
SEED_SQL=seed-cbioportal_hg19_hg38_v2.14.5.sql.gz
APP_PROPS=${CONF}/application.properties
IMPORTER_JAR=${CONF}/core-IMPORTER.jar
CACHE_HEADER=${CONF}/.cache_api_header             # X-API-KEY for cBioPortal's /api/cache (chmod 600)
STALE_FLAG=${CONF}/.webapp_stale                   # studies/access changed but the running webapp not refreshed yet
SYNC_LOCK=${CONF}/.sync.lock                       # one import / access sync at a time

## Service pids (only known to the `start` process)
CH_PID=""; MONGO_PID=""; SESSION_PID=""; WEB_PID=""; REPORTS_PID=""; SLEEP_PID=""
IMPORT_DIR=""                                      # set by stage_reports: the folder metaImport.py reads
SNAP=""                                            # host: /snapshots/<CBIO_DB_SNAPSHOT> (set by check_snapshot)
study_id=""                                        # set by import_study
IMPORTED_IDS=()                                    # build: cancer_study_identifier of every imported study
STUDY_SUMMARY=${CONF}/build_studies.tsv            # build: <folder> TAB <study_id>, one line per imported study


################################################################################
### Helpers

log() { echo -e "\n ${DIVIDER} \n $* \n"; }
die() { echo "ERROR: $*" >&2; exit 1; }

prepare_dirs() {   # prepare_dirs host|build
  mkdir -p "${CONF}/clickhouse" "${DATA}/clickhouse" "${LOGS}"
  [ "$1" != "host" ] || mkdir -p "${DATA}/mongo"
  chmod 700 "${CONF}"
  [ "$1" != "host" ] || mountpoint -q "${DATA}" 2>/dev/null \
    || echo "WARNING: ${DATA} is not a mounted volume - user sessions (MongoDB) are lost when the container is removed"
}

## Environment for every subcommand. ClickHouse password: podman secret (target=CLICKHOUSE_PASSWORD),
## else generated once into /data/config/.ch_password
load_env() {
  if [ -z "${CLICKHOUSE_PASSWORD:-}" ]; then
    if [ ! -s "${CONF}/.ch_password" ]; then
      ( umask 077; python3 -c 'import secrets; print(secrets.token_hex(16))' > "${CONF}/.ch_password" )
      echo "Generated a ClickHouse password in ${CONF}/.ch_password"
    fi
    CLICKHOUSE_PASSWORD=$(cat "${CONF}/.ch_password")
  fi
  ## cBioPortal cache endpoint key (internal only, generated once)
  if [ ! -s "${CACHE_HEADER}" ]; then
    ( umask 077; echo "X-API-KEY: $(python3 -c 'import secrets; print(secrets.token_hex(24))')" > "${CACHE_HEADER}" )
  fi
  CACHE_API_KEY=$(cut -d " " -f 2 "${CACHE_HEADER}")
  ## Who decides study access: off (no login) | opa | meta_study
  if [ "${CBIO_AUTH}" == "false" ]; then AUTHZ=off; else AUTHZ=${CBIO_AUTHZ}; fi
  ## read by clickhouse-users.xml / clickhouse-config.xml (from_env) and by migrate_db.py / metaImport.py
  export CLICKHOUSE_PASSWORD CH_HTTP_PORT CH_NATIVE_PORT CH_MAX_MEMORY
  export CH_PATH=${DATA}/clickhouse/ CH_TMP_PATH=${DATA}/clickhouse/tmp/
  export CH_USER_FILES_PATH=${DATA}/clickhouse/user_files/ CH_FORMAT_SCHEMA_PATH=${DATA}/clickhouse/format_schemas/
  export CH_LOG=${LOGS}/clickhouse-server.log CH_ERRORLOG=${LOGS}/clickhouse-server.err.log
  export CLICKHOUSE_DB=${CH_DB} CLICKHOUSE_USER=${CH_USER} CLICKHOUSE_HOST=127.0.0.1
  export CLICKHOUSE_HTTP_PORT=${CH_HTTP_PORT} CLICKHOUSE_NATIVE_PORT=${CH_NATIVE_PORT}
  export CLICKHOUSE_URL=jdbc:ch://127.0.0.1:${CH_HTTP_PORT}/${CH_DB}
  export CLICKHOUSE_OPTIMIZE_BACKOFF_SECS=0
}

## Client credentials in a chmod-600 file (never on the command line)
write_client_config() {
  ( umask 077; cat > "${CONF}/clickhouse/client.xml" <<EOF
<config>
    <user>${CH_USER}</user>
    <password>${CLICKHOUSE_PASSWORD}</password>
</config>
EOF
  )
}

ch_client() { "${CH_BIN}" client --config-file="${CONF}/clickhouse/client.xml" --host 127.0.0.1 --port "${CH_NATIVE_PORT}" "$@"; }

tcp_up()  { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

http_up() {   # http_up <url>  -> any HTTP answer except 5xx (302/401 = up, login required)
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" || true)
  [ "${code}" != "000" ] && [ "${code:0:1}" != "5" ]
}

wait_for() {   # wait_for "<test command>" "<name>" <pid> [max seconds]
  local max=${4:-600} i
  for (( i=0; i<max; i+=5 )); do
    if eval "$1" >/dev/null 2>&1; then echo "OK: $2 is up"; return 0; fi
    if ! kill -0 "$3" 2>/dev/null; then
      echo "ERROR: $2 process died - last log lines:"
      grep -hE '<Error>|<Fatal>|ERROR|Exception' "${LOGS}"/*.log 2>/dev/null | tail -5 | cut -c1-400
      return 1
    fi
    sleep 5
  done
  echo "TIMEOUT: $2 not up after ${max} s - see ${LOGS}/"; return 1
}

stop_service() {   # stop_service <pid> <name> <max seconds>
  local pid=$1 name=$2 max=$3 i
  { [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; } || return 0
  echo "Stopping ${name} (pid ${pid})"
  kill -TERM "${pid}" 2>/dev/null || true
  for (( i=0; i<max; i++ )); do
    kill -0 "${pid}" 2>/dev/null || { echo "stopped ${name}"; return 0; }
    sleep 1
  done
  echo "WARNING: ${name} still running after ${max} s - SIGKILL"
  kill -KILL "${pid}" 2>/dev/null || true
}

shutdown() {   # reverse start order, ClickHouse last so it flushes cleanly
  local rc=${1:-0}
  trap - EXIT TERM INT
  set +e
  log "Shutting down (exit code ${rc})"
  [ -z "${SLEEP_PID}" ] || kill "${SLEEP_PID}" 2>/dev/null
  stop_service "${REPORTS_PID}" "report server"     10
  stop_service "${WEB_PID}"     "cBioPortal webapp" 60
  stop_service "${SESSION_PID}" "session-service"   30
  stop_service "${MONGO_PID}"   "mongod"            60
  stop_service "${CH_PID}"      "ClickHouse"        120
  exit "${rc}"
}

check_auth() {
  case "${CBIO_AUTH}" in
    oauth2)
      local v missing=""
      for v in OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_REDIRECT_URI; do
        [ -n "${!v:-}" ] || missing="${missing} ${v}"
      done
      [ -z "${missing}" ] || die "login is required (CBIO_AUTH=oauth2) but these are not set:${missing}
       See README 'How to Run'. For a local test without login ONLY: -e CBIO_AUTH=false"
      case "${CBIO_AUTHZ}" in
        opa)
          [ -n "${OPA_URL}" ] && [ -n "${OPA_POLICY_PATH}" ] || die "CBIO_AUTHZ=opa needs OPA_URL and OPA_POLICY_PATH"
          [[ "${CBIO_OPA_SYNC_SECS}" =~ ^[0-9]+$ ]] && [ "${CBIO_OPA_SYNC_SECS}" -ge 30 ] \
            || die "CBIO_OPA_SYNC_SECS must be a number of seconds >= 30 (got '${CBIO_OPA_SYNC_SECS}')"
          echo "Study access decided by OPA: ${OPA_URL} (${OPA_POLICY_PATH}), re-applied every ${CBIO_OPA_SYNC_SECS} s"
          ;;
        meta_study)
          echo "WARNING: CBIO_AUTHZ=meta_study - study access from meta_study.txt 'groups:' (fallback for tests without OPA,"
          echo "         not for the webapp VM)"
          ;;
        *) die "CBIO_AUTHZ must be 'opa' or 'meta_study' (got '${CBIO_AUTHZ}')" ;;
      esac
      ;;
    false)
      echo -e "\n !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo " WARNING: CBIO_AUTH=false - NO LOGIN, every study is visible to anyone who can reach port ${CBIO_PORT}."
      echo " Local testing only. Never use this on the webapp VM."
      echo -e " !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
      ;;
    *) die "CBIO_AUTH must be 'oauth2' or 'false' (got '${CBIO_AUTH}')" ;;
  esac
}

check_reports() {   # report settings used by start (gatekeeper) and build (URLs written into the study)
  [[ "${CBIO_REPORTS_PORT}" =~ ^[0-9]+$ ]] || die "CBIO_REPORTS_PORT must be a port number (got '${CBIO_REPORTS_PORT}')"
  [[ "${CBIO_REPORTS_URL}" =~ ^https?://[^/]+ ]] \
    || die "CBIO_REPORTS_URL must start with http:// or https:// (cBioPortal resource URLs are absolute; got '${CBIO_REPORTS_URL}')"
  [[ "${CBIO_PORTAL_ORIGIN}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
    || die "CBIO_PORTAL_ORIGIN must look like https://host[:port] (got '${CBIO_PORTAL_ORIGIN}')"
  [[ "${CBIO_REPORT_OPEN_BY_DEFAULT}" =~ ^(true|false)$ ]] \
    || die "CBIO_REPORT_OPEN_BY_DEFAULT must be true or false (got '${CBIO_REPORT_OPEN_BY_DEFAULT}')"
  ## The gatekeeper only sees the portal session cookie when reports and portal share the host name
  if [ "${CBIO_AUTH}" == "oauth2" ]; then
    local rhost phost
    rhost=$(echo "${CBIO_REPORTS_URL}" | sed -E 's#^https?://([^/:]+).*#\1#')
    phost=$(echo "${OIDC_REDIRECT_URI}" | sed -E 's#^https?://([^/:]+).*#\1#')
    [ "${rhost}" == "${phost}" ] || echo "WARNING: CBIO_REPORTS_URL host '${rhost}' differs from the portal host '${phost}' -
         the browser will not send the portal login cookie, so every report answers 401"
  fi
}


################################################################################
### Config written at every start (so changed -e values / secrets are picked up)

## application.properties = the image defaults + our overrides appended (later keys win).
## The OIDC client secret is NOT written: Spring resolves ${OIDC_CLIENT_SECRET} from the environment.
write_app_properties() {
  ( umask 077
    cat /cbioportal-webapp/application.properties
    cat <<EOF

################################################################################
### c3g_cbioportal_instance overrides - written by /app/entrypoint.sh at every start
spring.datasource.url=${CLICKHOUSE_URL}
spring.datasource.username=${CH_USER}
spring.datasource.password=${CLICKHOUSE_PASSWORD}
spring.datasource.clickhouse.url=${CLICKHOUSE_URL}
spring.datasource.clickhouse.username=${CH_USER}
spring.datasource.clickhouse.password=${CLICKHOUSE_PASSWORD}
ncbi.build=${CBIO_NCBI_BUILD}
ucsc.build=${CBIO_UCSC_BUILD}
session.service.url=http://127.0.0.1:${SESSION_PORT}/api/sessions/my_portal/
server.forward-headers-strategy=${CBIO_FORWARD_HEADERS}
skin.title=${CBIO_SKIN_TITLE}
skin.right_logo=${CBIO_RIGHT_LOGO}
authenticate=${CBIO_AUTH}
### /api/cache: lets import / access sync refresh the running webapp (key in ${CACHE_HEADER})
cache.endpoint.enabled=true
cache.endpoint.api-key=${CACHE_API_KEY}
EOF
    if [ "${CBIO_AUTH}" == "oauth2" ]; then
      cat <<EOF

### Login: OIDC authorization-code flow against C3G COmanage / CILogon
spring.security.oauth2.client.provider.cbio-idp.issuer-uri=${OIDC_ISSUER}
spring.security.oauth2.client.provider.cbio-idp.user-name-attribute=${OIDC_USERNAME_CLAIM}
spring.security.oauth2.client.registration.cbio-idp.client-name=c3g-cbioportal
spring.security.oauth2.client.registration.cbio-idp.client-id=${OIDC_CLIENT_ID}
spring.security.oauth2.client.registration.cbio-idp.client-secret=\${OIDC_CLIENT_SECRET}
spring.security.oauth2.client.registration.cbio-idp.authorization-grant-type=authorization_code
spring.security.oauth2.client.registration.cbio-idp.client-authentication-method=${OIDC_CLIENT_AUTH_METHOD}
spring.security.oauth2.client.registration.cbio-idp.scope=${OIDC_SCOPES}
spring.security.oauth2.client.registration.cbio-idp.redirect-uri=${OIDC_REDIRECT_URI}
### Study access: token claim '${OIDC_ROLES_PATH}' vs meta_study.txt 'groups:'
spring.security.oauth2.client.jwt-roles-path=${OIDC_ROLES_PATH}
filter_groups_by_appname=${CBIO_FILTER_GROUPS_BY_APPNAME}
EOF
      [ -z "${CBIO_ALWAYS_SHOW_STUDY_GROUP}" ] || echo "always_show_study_group=${CBIO_ALWAYS_SHOW_STUDY_GROUP}"
    fi
  ) > "${APP_PROPS}.tmp"
  mv "${APP_PROPS}.tmp" "${APP_PROPS}"
  grep -E "^spring.datasource.url|^ncbi.build|^ucsc.build|^authenticate|issuer-uri|^spring.security.oauth2.client.jwt-roles-path" "${APP_PROPS}" | tail -n 6
}

## Importer JAR with our application.properties inside (rebuilt only when the properties change)
build_importer_jar() {
  local sum
  sum=$(sha256sum "${APP_PROPS}" | cut -d " " -f 1)
  if [ -s "${IMPORTER_JAR}" ] && [ "$(cat "${CONF}/.importer_props.sha256" 2>/dev/null)" == "${sum}" ]; then
    echo "Importer JAR up to date"; return 0
  fi
  echo "Building ${IMPORTER_JAR} ..."
  ( umask 077; python3 - /core/core-IMPORTER.jar "${IMPORTER_JAR}.tmp" "${APP_PROPS}" <<'PYEOF'
import sys, zipfile
src, dst, props = sys.argv[1:4]
with zipfile.ZipFile(src, "r") as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename != "application.properties":
            zout.writestr(item, zin.read(item.filename))
    zout.write(props, "application.properties")
PYEOF
  )
  mv "${IMPORTER_JAR}.tmp" "${IMPORTER_JAR}"
  echo "${sum}" > "${CONF}/.importer_props.sha256"
}


################################################################################
### Services

start_clickhouse() {   # = cbioportal-database service
  ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
  "${CH_BIN}" server --config-file="${CH_CONFIG}" >> "${LOGS}/clickhouse.stdout.log" 2>&1 &
  CH_PID=$!
  wait_for 'ch_client --query "SELECT 1"' "ClickHouse" "${CH_PID}" 300
}

init_db() {   # build only: = data/init.sh + load_schema.sh + load_seed.sh + load_derived_tables.sh
  local n_tables
  n_tables=$(ch_client --query "SELECT count() FROM system.tables WHERE database = '${CH_DB}'")
  [ "${n_tables}" -eq 0 ] || die "database '${CH_DB}' already has tables - a build always starts from an empty DB.
       Use a new, empty scratch folder for ${DATA} (deploy/c3g-cbioportal-build.sh makes one per build)."
  log "Empty DB: load schema + seed + derived tables (takes several minutes)"
  ch_client --query "CREATE DATABASE IF NOT EXISTS ${CH_DB}"
  echo "Loading schema..."
  ch_client --database "${CH_DB}" --multiquery < "${DB_SCRIPTS}/init/schema.sql"
  echo "Loading seed data (${SEED_SQL})..."
  gunzip -c "${DB_SCRIPTS}/init/${SEED_SQL}" | ch_client --database "${CH_DB}" --multiquery
  echo "Populating derived tables..."
  ch_client --database "${CH_DB}" --multiquery --param_optimize_backoff_secs=0 < "${DB_SCRIPTS}/populate_derived_tables.sql"
  check_seed
  migrate_schema
}

check_seed() {   # docker-compose healthcheck: type_of_cancer must have rows
  local n_toc
  n_toc=$(ch_client --query "SELECT COUNT(*) FROM ${CH_DB}.type_of_cancer" 2>/dev/null || echo 0)
  [ "${n_toc}" -gt 0 ] 2>/dev/null || die "database '${CH_DB}' has no seed data (type_of_cancer empty or missing).
       Host: the snapshot is not a finished build - serve another one. Build: the seed load failed, see ${LOGS}/."
  echo "type_of_cancer rows: ${n_toc}"
}

migrate_schema() {   # = cbioportal-migration service (no-op when the schema is current)
  log "Schema migration"
  python3 "${DB_SCRIPTS}/migrate/migrate_db.py" --populate-derived-tables
}

start_mongo() {   # = cbioportal-session-database service
  mongod --dbpath "${DATA}/mongo" --bind_ip 127.0.0.1 --port "${MONGO_PORT}" \
    --wiredTigerCacheSizeGB "${MONGO_CACHE_GB}" \
    --logpath "${LOGS}/mongod.log" --logappend &
  MONGO_PID=$!
  wait_for "tcp_up ${MONGO_PORT}" "MongoDB" "${MONGO_PID}" 120
}

start_session() {   # = cbioportal-session service
  java ${SESSION_JAVA_OPTS} \
    -Dserver.port="${SESSION_PORT}" -Dserver.address=127.0.0.1 \
    -Dspring.data.mongodb.uri="mongodb://127.0.0.1:${MONGO_PORT}/session-service" \
    -jar /app/session-service.war \
    >> "${LOGS}/session-service.log" 2>&1 &
  SESSION_PID=$!
  wait_for "http_up http://127.0.0.1:${SESSION_PORT}/" "session-service" "${SESSION_PID}" 300
}

start_webapp() {   # = cbioportal service
  java ${CBIO_JAVA_OPTS} -cp '/cbioportal-webapp:/cbioportal-webapp/lib/*' org.cbioportal.PortalApplication \
    --spring.config.location="file:${APP_PROPS}" \
    --server.port="${CBIO_PORT}" --server.address=0.0.0.0 \
    --clickhouse_mode=true \
    --spring.profiles.active=clickhouse \
    >> "${LOGS}/cbioportal.log" 2>&1 &
  WEB_PID=$!
  wait_for "http_up http://127.0.0.1:${CBIO_PORT}/api/health" "cBioPortal webapp" "${WEB_PID}" 900
}

start_reports() {   # report gatekeeper: serves the snapshot's reports/ after asking the webapp (README "PCGR reports")
  python3 -I /app/reports_server.py \
    --port "${CBIO_REPORTS_PORT}" --portal-port "${CBIO_PORT}" \
    --reports-dir "${REPORTS}" --auth "${CBIO_AUTH}" \
    --frame-origin "${CBIO_PORTAL_ORIGIN}" --log "${LOGS}/reports.log" \
    >> "${LOGS}/reports_server.log" 2>&1 &
  REPORTS_PID=$!
  wait_for "http_up http://127.0.0.1:${CBIO_REPORTS_PORT}/reports/health" "report server" "${REPORTS_PID}" 60
}


################################################################################
### Access decisions (OPA)
### OPA answers POST /v1/data/<OPA_POLICY_PATH>/study_access with {"result": {"<study_id>": ["<group>", ...]}}.
### Studies OPA does not list, and every study when OPA fails, get OPA_DENY_GROUP (= visible to nobody).

opa_fetch() {   # opa_fetch <out.json>: OPA's study -> groups table (3 tries, 10 s apart)
  local i
  for i in 1 2 3; do
    if curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' -d '{"input": {"action": "sync"}}' \
         -o "$1" "${OPA_URL%/}/v1/data/${OPA_POLICY_PATH}/study_access" 2>> "${LOGS}/access_sync.log"; then
      return 0
    fi
    [ "${i}" -eq 3 ] || sleep 10
  done
  return 1
}

opa_has_study() {   # opa_has_study <study_id>: print the groups OPA allows; fail if none or OPA down
  local tmp rc=0
  tmp=$(mktemp "${CONF}/.opa.XXXXXX")
  opa_fetch "${tmp}" || { rm -f "${tmp}"; echo "OPA not reachable at ${OPA_URL}"; return 1; }
  python3 -c 'import json, sys
g = json.load(open(sys.argv[1])).get("result", {}).get(sys.argv[2])
print(";".join(sorted(g)) if g else "")
sys.exit(0 if g else 1)' "${tmp}" "$1" || rc=1
  rm -f "${tmp}"
  return "${rc}"
}

## sync_access [verbose]: write OPA's decision into cancer_study.groups (caller holds the sync lock).
## Returns 1 when OPA failed (every study then hidden) or the update failed.
sync_access() {
  [ "${AUTHZ}" == "opa" ] || return 0
  local tmp opa_ok=1 rc=0
  tmp=$(mktemp -d "${CONF}/.sync.XXXXXX")
  opa_fetch "${tmp}/opa.json" || opa_ok=0
  if ! ch_client --database "${CH_DB}" --query \
       "SELECT cancer_study_identifier, ifNull(groups, '') FROM cancer_study FORMAT TabSeparated" > "${tmp}/db.tsv"; then
    echo "ERROR: could not read the studies from ClickHouse - access not synced"; rm -rf "${tmp}"; return 1
  fi

  python3 - "${tmp}/opa.json" "${tmp}/db.tsv" "${opa_ok}" "${OPA_DENY_GROUP}" > "${tmp}/plan.sql" 2> "${tmp}/plan.log" <<'PYEOF' || rc=$?
import json, re, sys
opa_file, db_file, opa_ok, deny = sys.argv[1:5]
STUDY_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
GROUP_RE = re.compile(r"^[^;'\"\\\x00-\x1f]+$")     # no ; (cBioPortal separator), quotes, backslash, control chars
if not GROUP_RE.match(deny):
    print(f"ERROR: OPA_DENY_GROUP {deny!r} has forbidden characters", file=sys.stderr); sys.exit(4)

access, why = {}, ""
if opa_ok != "1":
    why = "OPA not reachable"
else:
    try:
        res = json.load(open(opa_file))["result"]          # no 'result' = wrong OPA_POLICY_PATH / no policy loaded
        if not isinstance(res, dict):
            raise ValueError("result is not an object")
        for study, groups in res.items():
            if not isinstance(groups, list) or not all(isinstance(g, str) and GROUP_RE.match(g.strip()) for g in groups):
                raise ValueError(f"bad group list for {study!r}")
            keep = sorted({g.strip() for g in groups if g.strip() and g.strip() != deny})
            if keep:
                access[study] = ";".join(keep)
    except (KeyError, ValueError) as e:
        access, why = {}, f"OPA answer not usable ({e})"

n = 0
for line in open(db_file):
    study, _, current = line.rstrip("\n").partition("\t")
    if not study:
        continue
    current = "" if current == "\\N" else current
    want = access.get(study, deny)
    if current == want:
        continue
    if not STUDY_RE.match(study):
        print(f"ERROR: study id {study!r} has unexpected characters - not changed", file=sys.stderr)
        continue
    print(f"ALTER TABLE cancer_study UPDATE \"groups\" = '{want}' WHERE cancer_study_identifier = '{study}';")
    print(f"  {study}: '{current}' -> '{want}'", file=sys.stderr)
    n += 1
print(f"{n} study access change(s)", file=sys.stderr)
if why:
    print(f"FAIL CLOSED: {why} - every study set to {deny} (hidden) until OPA answers", file=sys.stderr)
    sys.exit(3)
PYEOF

  { echo "### $(date '+%Y-%m-%d %H:%M:%S')"; cat "${tmp}/plan.log"; } >> "${LOGS}/access_sync.log"
  if [ "${1:-}" == "verbose" ] || [ -s "${tmp}/plan.sql" ] || [ "${rc}" -ne 0 ]; then
    sed 's/^/ [access] /' "${tmp}/plan.log"
  fi
  if [ -s "${tmp}/plan.sql" ]; then
    if ch_client --database "${CH_DB}" --multiquery --mutations_sync=2 < "${tmp}/plan.sql"; then
      touch "${STALE_FLAG}"
    else
      echo "ERROR: ClickHouse update of cancer_study.groups failed - access NOT changed"; rc=1
    fi
  fi
  rm -rf "${tmp}"
  [ "${rc}" -eq 0 ]
}

locked_sync() {   # locked_sync <wait secs, 0 = skip if busy> [verbose]: sync_access under the sync lock
  ( if [ "$1" -eq 0 ]; then
      flock -n 9 || { echo "access sync skipped: an import or sync is running"; exit 0; }
    else
      flock -w "$1" 9 || { echo "ERROR: sync lock still busy after $1 s"; exit 1; }
    fi
    sync_access "${2:-}" ) 9> "${SYNC_LOCK}"
}

clear_webapp_cache() {   # the webapp reads new studies / groups after this (2xx = done)
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X DELETE -H "@${CACHE_HEADER}" \
    "http://127.0.0.1:${CBIO_PORT}/api/cache" || true)
  [ "${code:0:1}" == "2" ]
}

refresh_webapp() {   # start process only: apply pending changes to the running webapp (cache, else restart)
  [ -e "${STALE_FLAG}" ] || return 0
  if clear_webapp_cache; then
    rm -f "${STALE_FLAG}"; echo "cBioPortal cache cleared - study/access changes are live"; return 0
  fi
  log "cBioPortal cache endpoint did not answer - restarting the webapp so the study/access changes apply"
  stop_service "${WEB_PID}" "cBioPortal webapp" 60
  rm -f "${STALE_FLAG}"
  start_webapp
}

report_refresh() {   # podman exec subcommands: try to refresh the running webapp now
  [ -e "${STALE_FLAG}" ] || return 0
  if clear_webapp_cache; then
    rm -f "${STALE_FLAG}"; echo "cBioPortal cache cleared - changes are live"
  else
    echo "Cache endpoint did not answer: the running portal applies the changes within ${CBIO_OPA_SYNC_SECS} s (webapp restart)"
  fi
}


################################################################################
### PCGR reports -> cBioPortal "resources" (build only)
### Resources cannot be added incrementally, so they must be in the study at import time. The study
### folder (pipeline output) is never edited: a staging copy = symlinks to every study file + the
### generated meta/data_resource_*.txt files is imported instead.

## stage_reports <study_dir> <study_id> <folder_name>: sets IMPORT_DIR (= study_dir when there is nothing to add)
stage_reports() {
  local study_dir=$1 study_id=$2 folder=$3 rdir=${REPORTS}/$2 stage entry rc=0
  IMPORT_DIR=${study_dir}
  log "PCGR reports (${rdir}/*${CBIO_REPORT_SUFFIX})"
  if grep -qsE '^resource_type:' "${study_dir}"/*meta*.txt; then
    echo "The study folder already has resource files - using them, nothing generated"; return 0
  fi
  if ! compgen -G "${rdir}/*${CBIO_REPORT_SUFFIX}" > /dev/null; then
    echo "No reports for ${study_id} - imported without report tabs"; return 0
  fi

  stage=${CONF}/staging/${folder}
  rm -rf "${stage}"; mkdir -p "${stage}"
  for entry in "${study_dir}"/*; do ln -s "${entry}" "${stage}/"; done

  python3 - "${study_dir}" "${stage}" "${rdir}" "${study_id}" "${CBIO_REPORT_SUFFIX}" "${CBIO_REPORTS_URL%/}" \
      "${CBIO_REPORT_NAME}" "${CBIO_REPORT_DESCRIPTION}" "${CBIO_REPORT_OPEN_BY_DEFAULT}" <<'PYEOF' || rc=$?
import os, re, sys
from collections import Counter
from urllib.parse import quote
study_dir, stage, rdir, study_id, suffix, base_url, name, desc, open_default = sys.argv[1:10]
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*\.html$")    # = reports_server.py: other names are never served
RID = "PCGR_REPORT"
for v, what in ((name, "CBIO_REPORT_NAME"), (desc, "CBIO_REPORT_DESCRIPTION")):
    if not v.strip() or re.search(r"[\t\r\n]", v):
        sys.exit(f"ERROR: {what} must be non-empty and have no tabs / newlines")

def meta(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        k, sep, v = line.partition(":")
        if sep:
            out[k.strip()] = v.strip()
    return out

## clinical sample file = the meta with datatype SAMPLE_ATTRIBUTES
clin = None
for f in sorted(os.listdir(study_dir)):
    if "meta" in f and f.endswith(".txt") and os.path.isfile(os.path.join(study_dir, f)):
        m = meta(os.path.join(study_dir, f))
        if m.get("genetic_alteration_type") == "CLINICAL" and m.get("datatype") == "SAMPLE_ATTRIBUTES":
            clin = os.path.join(study_dir, m["data_filename"])
if not clin or not os.path.isfile(clin):
    sys.exit("ERROR: no clinical sample file (meta with datatype: SAMPLE_ATTRIBUTES) - cannot link reports to samples")

samples, header = [], None
for line in open(clin, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    row = line.rstrip("\r\n").split("\t")
    if header is None:
        header = row
        if "PATIENT_ID" not in header or "SAMPLE_ID" not in header:
            sys.exit(f"ERROR: {clin} has no PATIENT_ID / SAMPLE_ID columns")
        ip, i_s = header.index("PATIENT_ID"), header.index("SAMPLE_ID")
        continue
    if len(row) <= max(ip, i_s) or not row[i_s].strip():
        continue
    samples.append((row[ip].strip(), row[i_s].strip()))

## reports: regular files in rdir with the suffix and a name the gatekeeper serves
reports, bad = set(), []
for f in sorted(os.listdir(rdir)):
    p = os.path.join(rdir, f)
    if not f.endswith(suffix) or not os.path.isfile(p):
        continue
    if FILE_RE.match(f) and os.path.dirname(os.path.realpath(p)) == os.path.realpath(rdir):
        reports.add(f)
    else:
        bad.append(f)

rows, missing = [], []
for patient, sample in samples:
    hit = next((c for c in (sample + suffix, patient + suffix) if c in reports), None)
    if hit:
        rows.append((patient, sample, hit))
    else:
        missing.append(sample)
used = Counter(r[2] for r in rows)

print(f"Reports in {rdir}: {len(reports)}; samples in the study: {len(samples)}; linked: {len(rows)}")
if missing:
    print(f"  samples without a report ({len(missing)}): {', '.join(missing)}")
unused = sorted(reports - set(used))
if unused:
    print(f"  reports matching no SAMPLE_ID / PATIENT_ID ({len(unused)}): {', '.join(unused)}")
shared = sorted(f for f, n in used.items() if n > 1)
if shared:
    print(f"  WARNING: reports linked to more than one sample (PATIENT_ID match): {', '.join(shared)}")
if bad:
    print(f"  WARNING: not linked - name not served (letters, digits, _ . - only) or symlink out of the folder: {', '.join(bad)}")
if not rows:
    sys.exit(3)

def write(fname, text):
    with open(os.path.join(stage, fname), "x", encoding="utf-8") as fh:    # "x": never overwrite a study file
        fh.write(text)

write("meta_resource_definition.txt",
      f"cancer_study_identifier: {study_id}\nresource_type: DEFINITION\ndata_filename: data_resource_definition.txt\n")
write("data_resource_definition.txt",
      "RESOURCE_ID\tDISPLAY_NAME\tRESOURCE_TYPE\tDESCRIPTION\tOPEN_BY_DEFAULT\tPRIORITY\n"
      f"{RID}\t{name}\tSAMPLE\t{desc}\t{open_default}\t1\n")
write("meta_resource_sample.txt",
      f"cancer_study_identifier: {study_id}\nresource_type: SAMPLE\ndata_filename: data_resource_sample.txt\n")
write("data_resource_sample.txt",
      "PATIENT_ID\tSAMPLE_ID\tRESOURCE_ID\tURL\n"
      + "".join(f"{p}\t{s}\t{RID}\t{base_url}/{quote(study_id, safe='')}/{quote(f, safe='')}\n" for p, s, f in rows))
print(f"Resource files written to {stage}/ (the study folder is unchanged)")
PYEOF

  case "${rc}" in
    0) IMPORT_DIR=${stage} ;;
    3) echo "WARNING: no report matches a sample - imported without report tabs"; rm -rf "${stage}" ;;
    *) rm -rf "${stage}"; die "could not link the reports (see above)" ;;
  esac
}


################################################################################
### Snapshots (README "Build VM" / "Host VM")
### A snapshot = /snapshots/<id>/ {clickhouse/ (stopped DB), reports/<study_id>/, logs/, BUILD_INFO.json, READY}.
### Written once by `build` (as <id>.partial, renamed, READY last), never changed afterwards. The host only reads
### it: it serves a local COPY in /data/clickhouse, so its own writes (migration, OPA groups) never reach it.

SAFE_ID_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

## cp_db <src> <dst>: copy a stopped ClickHouse folder. Keeps symlinks (-d; they are absolute /data/clickhouse/...),
## modes and times, NOT ownership: the copy belongs to this container's user, as ClickHouse wants, and a chown
## would fail on NFS (root_squash) or across VMs with other uids.
cp_db() { cp -dR --preserve=mode,timestamps "$1" "$2"; }

## check_snapshot: host - CBIO_DB_SNAPSHOT must be a finished snapshot made by this cBioPortal version (sets SNAP, REPORTS)
check_snapshot() {
  local built_with link
  [ -n "${CBIO_DB_SNAPSHOT}" ] || die "CBIO_DB_SNAPSHOT is not set. This container only serves snapshots made on the Build VM:
       set -e CBIO_DB_SNAPSHOT=<id> (list them: podman run --rm -v <shared>/snapshots:/snapshots:ro <image> snapshots)"
  [[ "${CBIO_DB_SNAPSHOT}" =~ ${SAFE_ID_RE} ]] && [[ "${CBIO_DB_SNAPSHOT}" != *.partial ]] \
    || die "CBIO_DB_SNAPSHOT '${CBIO_DB_SNAPSHOT}' is not a snapshot id (letters, digits, _ . -; not *.partial)"
  SNAP=${SNAPSHOTS}/${CBIO_DB_SNAPSHOT}
  [ -d "${SNAP}" ] || die "snapshot ${SNAP} not found - is the shared snapshots folder mounted at ${SNAPSHOTS}?"
  [ -e "${SNAP}/READY" ] || die "${SNAP} has no READY file - its build did not finish. Serve another snapshot."
  [ -d "${SNAP}/clickhouse/metadata" ] && [ -s "${SNAP}/BUILD_INFO.json" ] || die "${SNAP} is incomplete (no clickhouse/metadata or BUILD_INFO.json)"
  built_with=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("cbio_version", ""))' "${SNAP}/BUILD_INFO.json") \
    || die "${SNAP}/BUILD_INFO.json is not readable JSON"
  [ "${built_with}" == "${CBIO_VERSION}" ] || die "snapshot ${CBIO_DB_SNAPSHOT} was built with cBioPortal '${built_with}', this image is '${CBIO_VERSION}'.
       Rebuild it on the Build VM with the same image tag as the host."
  ## ClickHouse's symlinks are absolute: the snapshot only works at the DATA path it was built at
  link=$(readlink "${SNAP}/clickhouse/metadata/${CH_DB}" || true)
  [[ "${link}" == "${DATA}/clickhouse/"* ]] || die "snapshot links point to '${link}', not ${DATA}/clickhouse/ -
       build and host must use the same CBIO_DATA_DIR (default /data)"
  REPORTS=${SNAP}/reports
  echo "Snapshot ${CBIO_DB_SNAPSHOT}: built $(sed -n '1p' "${SNAP}/READY"), cBioPortal ${built_with}"
}

## activate_snapshot: host - make /data/clickhouse a copy of SNAP (kept as is when it already is that snapshot)
activate_snapshot() {
  local cur=""
  cur=$(cat "${DATA}/clickhouse/.snapshot_id" 2>/dev/null || true)
  if [ "${cur}" == "${CBIO_DB_SNAPSHOT}" ]; then
    echo "Snapshot ${CBIO_DB_SNAPSHOT} already active (${DATA}/clickhouse) - kept"; return 0
  fi
  echo "Activating snapshot ${CBIO_DB_SNAPSHOT} (active before: ${cur:-none})"
  rm -rf "${DATA}/clickhouse.new"
  cp_db "${SNAP}/clickhouse" "${DATA}/clickhouse.new"
  rm -f "${DATA}/clickhouse.new/status"                    # the builder's server status file
  echo "${CBIO_DB_SNAPSHOT}" > "${DATA}/clickhouse.new/.snapshot_id"
  if [ -n "$(ls -A "${DATA}/clickhouse" 2>/dev/null)" ]; then
    rm -rf "${DATA}/clickhouse.prev"                        # only the last one is kept (rollback = old snapshot id)
    mv "${DATA}/clickhouse" "${DATA}/clickhouse.prev"
    echo "Previous DB kept in ${DATA}/clickhouse.prev (${cur:-not from a snapshot})"
  else
    rm -rf "${DATA}/clickhouse"
  fi
  mv "${DATA}/clickhouse.new" "${DATA}/clickhouse"
  echo "Active: ${CBIO_DB_SNAPSHOT} ($(du -sh "${DATA}/clickhouse" | cut -f 1))"
}

## publish_snapshot <manifest>: build - copy the stopped DB + reports + logs to SNAPSHOTS/<id>.partial, rename, READY last
publish_snapshot() {
  local manifest=$1 final part sid n
  final=${SNAPSHOTS}/${CBIO_SNAPSHOT_ID}
  part=${final}.partial
  log "Publish snapshot ${final}"
  mkdir "${part}"
  cp_db "${DATA}/clickhouse" "${part}/clickhouse"
  rm -f "${part}/clickhouse/status"
  mkdir -p "${part}/reports" "${part}/logs"
  for sid in "${IMPORTED_IDS[@]}"; do
    [ -d "${REPORTS}/${sid}" ] || continue
    mkdir -p "${part}/reports/${sid}"
    find "${REPORTS}/${sid}" -maxdepth 1 -type f -name '*.html' -exec cp -t "${part}/reports/${sid}/" {} +
    n=$(find "${part}/reports/${sid}" -maxdepth 1 -type f | wc -l)
    echo "reports/${sid}: ${n} file(s)"
  done
  cp "${LOGS}"/import_*.log "${LOGS}"/import_validation_*.html "${LOGS}/dumpPortalInfo.log" "${part}/logs/" 2>/dev/null || true
  cp "${CONF}/studies.tsv" "${part}/studies.tsv"             # written by ch_studies_tsv while ClickHouse was up
  python3 -I - "${part}/BUILD_INFO.json" "${CBIO_SNAPSHOT_ID}" "${CBIO_VERSION}" "${CBIO_IMAGE_REF}" \
      "$("${CH_BIN}" --version 2>/dev/null | head -n 1)" "${manifest}" "${CBIO_REPORTS_URL}" "${CONF}/studies.tsv" \
      "${CONF}/db_info.json" "${STUDY_SUMMARY}" <<'PYEOF'
import json, sys, datetime
out, sid, cbio, image, ch, manifest, rurl, studies_tsv, dbinfo, summary = sys.argv[1:11]
studies = []
for line in open(studies_tsv, encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 3:
        studies.append({"study_id": f[0], "name": f[1], "import_date": f[2]})
folders = {}
for line in open(summary, encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if len(f) == 2:
        folders[f[1]] = f[0]
for s in studies:
    s["folder"] = folders.get(s["study_id"], "")
try:
    db = [json.loads(l) for l in open(dbinfo, encoding="utf-8") if l.strip()]
except (OSError, ValueError):
    db = []
info = {"snapshot_id": sid, "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "cbio_version": cbio, "image": image, "clickhouse": ch, "manifest": manifest,
        "reports_url": rurl, "db_info": db, "studies": studies}
with open(out, "x", encoding="utf-8") as fh:
    json.dump(info, fh, indent=2)
    fh.write("\n")
PYEOF
  mv "${part}" "${final}"
  date '+%Y-%m-%d %H:%M:%S' > "${final}/READY"
  echo "Snapshot ready: ${final} ($(du -sh "${final}" | cut -f 1))"
}

## ch_studies_tsv: studies in the DB -> CONF/studies.tsv (id, name, import date), DB info table -> CONF/db_info.json
ch_studies_tsv() {
  ch_client --database "${CH_DB}" --query \
    "SELECT cancer_study_identifier, name, import_date FROM cancer_study ORDER BY cancer_study_identifier FORMAT TabSeparated" \
    > "${CONF}/studies.tsv"
  ch_client --database "${CH_DB}" --query "SELECT * FROM info FORMAT JSONEachRow" > "${CONF}/db_info.json" 2>/dev/null || true
  cat "${CONF}/studies.tsv"
}

build_exit() {   # build: stop ClickHouse, say what is left
  local rc=${1:-0}
  trap - EXIT TERM INT
  set +e
  stop_service "${CH_PID}" "ClickHouse" 120
  if [ "${rc}" -ne 0 ]; then
    echo -e "\n BUILD FAILED (exit code ${rc}) - no snapshot published."
    [ ! -d "${SNAPSHOTS}/${CBIO_SNAPSHOT_ID}.partial" ] || echo " Left unfinished (no READY, never served): ${SNAPSHOTS}/${CBIO_SNAPSHOT_ID}.partial"
    echo " Scratch with logs: ${DATA}/logs/"
  fi
  exit "${rc}"
}


################################################################################
### Subcommands

do_start() {
  log "c3g_cbioportal_instance: start ($(date '+%Y-%m-%d %H:%M:%S'))"
  check_auth
  check_snapshot
  check_reports
  prepare_dirs host
  load_env
  write_client_config
  write_app_properties

  ## From here on, any failure / podman stop shuts the started services down in order
  trap 'shutdown $?' EXIT
  trap 'exit 0' TERM INT

  log "1/7 Snapshot ${CBIO_DB_SNAPSHOT} (from ${SNAPSHOTS}, read-only)"; activate_snapshot
  log "2/7 ClickHouse";      start_clickhouse; check_seed; migrate_schema
  log "3/7 Study access (${AUTHZ})"
  locked_sync 60 verbose || echo "WARNING: studies stay hidden until OPA answers (retried every ${CBIO_OPA_SYNC_SECS} s)"
  rm -f "${STALE_FLAG}"      # the webapp is not up yet: it reads the current access when it starts
  log "4/7 MongoDB";         start_mongo
  log "5/7 session-service"; start_session
  log "6/7 cBioPortal webapp (port ${CBIO_PORT}, login: ${CBIO_AUTH}, access: ${AUTHZ})"; start_webapp
  log "7/7 Report server (port ${CBIO_REPORTS_PORT}, public URL ${CBIO_REPORTS_URL}, embedded by ${CBIO_PORTAL_ORIGIN})"; start_reports
  log "All services up, serving snapshot ${CBIO_DB_SNAPSHOT}. Logs: ${LOGS}/
 New / updated studies: build a new snapshot on the Build VM, set CBIO_DB_SNAPSHOT, restart (README)."

  ## Stay in the foreground. Every CBIO_OPA_SYNC_SECS: re-apply OPA's decisions and refresh the webapp
  ## if studies/access changed. If any service exits on its own, stop the others and exit 1
  ## (systemd / podman restart policy brings the container back).
  local done_pid
  while true; do
    sleep "${CBIO_OPA_SYNC_SECS}" & SLEEP_PID=$!
    done_pid=""
    wait -n -p done_pid "${SLEEP_PID}" "${CH_PID}" "${MONGO_PID}" "${SESSION_PID}" "${WEB_PID}" "${REPORTS_PID}" || true
    if [ "${done_pid}" != "${SLEEP_PID}" ]; then
      kill "${SLEEP_PID}" 2>/dev/null || true
      echo "ERROR: a service exited unexpectedly - see ${LOGS}/"
      exit 1
    fi
    SLEEP_PID=""
    locked_sync 0 || true
    refresh_webapp || echo "ERROR: webapp restart failed - see ${LOGS}/cbioportal.log"
  done
}

## import_study <study_dir>: build only - offline-validate + import one study folder into the builder's ClickHouse.
## Access is NOT decided here: the host writes OPA's groups into the DB at start (fail closed).
import_study() {
  local study_dir=$1 study rc allowed
  [ -d "${study_dir}" ] || die "${study_dir} not found inside the container (study folders go in <shared>/studies/, mounted at ${STUDIES})"
  study_dir=$(realpath "${study_dir}")
  [ -s "${study_dir}/meta_study.txt" ] || die "no meta_study.txt in ${study_dir} (pipeline output complete?)"
  study=$(basename "${study_dir}")
  study_id=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' "${study_dir}/meta_study.txt" | tr -d '[:space:]')
  [ -n "${study_id}" ] || die "no cancer_study_identifier in ${study_dir}/meta_study.txt"
  [[ "${study_id}" =~ ${SAFE_ID_RE} ]] || die "cancer_study_identifier '${study_id}' has characters other than letters, digits, _ . -"

  log "Import ${study_dir}"
  cat "${study_dir}/meta_study.txt"; echo

  ## Access: only a warning here (the host hides any study OPA does not list)
  if [ -n "${OPA_URL_FROM_ENV}" ]; then
    if allowed=$(opa_has_study "${study_id}"); then
      echo "OPA (${OPA_URL}): study ${study_id} visible to: ${allowed}"
    else
      echo "WARNING: OPA gives no group access to '${study_id}' (${allowed:-no rule}) - it will be HIDDEN on the host
         until it is added to c3g_cbioportal/data.json in c3g-opa-policies"
    fi
  fi
  grep -qE '^groups:[[:space:]]*[^[:space:]]' "${study_dir}/meta_study.txt" \
    || echo "NOTE: no 'groups:' in meta_study.txt - fine for OPA hosts (OPA decides); hidden on a CBIO_AUTHZ=meta_study host"

  ## Offline validation: dump gene/cancer-type info from the DB instead of -u <url>
  ## (re-dumped for every study: a study imported before can add cancer types)
  log "Dump portal info (offline validation)"
  rm -rf "${PORTALINFO}"; mkdir -p "${PORTALINFO}"
  java ${CBIO_IMPORT_JAVA_OPTS} -cp "${IMPORTER_JAR}" org.mskcc.cbio.portal.scripts.DumpPortalInfo "${PORTALINFO}" \
    > "${LOGS}/dumpPortalInfo.log" 2>&1 || die "DumpPortalInfo failed - see ${LOGS}/dumpPortalInfo.log"

  ## PCGR reports -> resource files in a staging copy (sets IMPORT_DIR; = study_dir when there are none)
  stage_reports "${study_dir}" "${study_id}" "${study}"

  ## = docker compose run cbioportal metaImport.py -u http://cbioportal:8080 -s study/... -o
  log "Validate + import ${study}"
  [ "${IMPORT_DIR}" == "${study_dir}" ] || echo "(from ${IMPORT_DIR} = ${study_dir} + report resource files)"
  set +e
  metaImport.py -p "${PORTALINFO}" -s "${IMPORT_DIR}" -o \
    -jvo "${CBIO_IMPORT_JAVA_OPTS}" \
    -jar "${IMPORTER_JAR}" \
    --derived-table-sql "${DB_SCRIPTS}/populate_derived_tables.sql" \
    -html "${LOGS}/import_validation_${study}.html" \
    2>&1 | tee "${LOGS}/import_${study}.log"
  rc=${PIPESTATUS[0]}
  set -e
  echo -e "\n Validation report: ${LOGS}/import_validation_${study}.html \n Import log:        ${LOGS}/import_${study}.log"
  [ "${rc}" -eq 0 ] || die "metaImport.py exited with code ${rc} for ${study}"

  IMPORTED_IDS+=("${study_id}")
  printf '%s\t%s\n' "${study}" "${study_id}" >> "${STUDY_SUMMARY}"
}

do_build() {
  local manifest=${1:-} line folder ids="" i=0
  local -a folders=()
  [ -n "${manifest}" ] || die "Usage: /app/entrypoint.sh build /manifests/<name>.txt (one study folder of ${STUDIES} per line)"
  [ -s "${manifest}" ] || die "manifest ${manifest} not found or empty"
  log "c3g_cbioportal_instance: build snapshot ${CBIO_SNAPSHOT_ID} ($(date '+%Y-%m-%d %H:%M:%S'))"

  ## Inputs: manifest lines (# comments and blank lines ignored) = folder names in STUDIES
  while IFS= read -r line || [ -n "${line}" ]; do
    line=${line%%#*}
    line=$(echo "${line}" | tr -d '[:space:]')
    [ -n "${line}" ] || continue
    [[ "${line}" =~ ${SAFE_ID_RE} ]] || die "manifest line '${line}': must be a study folder name (letters, digits, _ . -), not a path"
    [ -s "${STUDIES}/${line}/meta_study.txt" ] || die "manifest: ${STUDIES}/${line}/meta_study.txt not found"
    folders+=("${line}")
  done < "${manifest}"
  [ "${#folders[@]}" -gt 0 ] || die "manifest ${manifest} lists no study folder"
  for folder in "${folders[@]}"; do
    line=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' "${STUDIES}/${folder}/meta_study.txt" | tr -d '[:space:]')
    [[ " ${ids} " != *" ${line} "* ]] || die "two manifest folders have the same cancer_study_identifier '${line}'"
    ids="${ids} ${line}"
  done
  echo "Studies (${#folders[@]}): ${folders[*]}"

  ## Output: a writable shared snapshots folder, a new id, an empty local scratch
  [ -d "${SNAPSHOTS}" ] && [ -w "${SNAPSHOTS}" ] || die "${SNAPSHOTS} is not a writable folder - mount <shared>/snapshots there"
  [[ "${CBIO_SNAPSHOT_ID}" =~ ${SAFE_ID_RE} ]] && [[ "${CBIO_SNAPSHOT_ID}" != *.partial ]] \
    || die "CBIO_SNAPSHOT_ID '${CBIO_SNAPSHOT_ID}' is not a valid id (letters, digits, _ . -)"
  [ ! -e "${SNAPSHOTS}/${CBIO_SNAPSHOT_ID}" ] && [ ! -e "${SNAPSHOTS}/${CBIO_SNAPSHOT_ID}.partial" ] \
    || die "${SNAPSHOTS}/${CBIO_SNAPSHOT_ID} already exists - snapshots are never overwritten; use a new CBIO_SNAPSHOT_ID"
  [ -z "$(ls -A "${DATA}/clickhouse" 2>/dev/null)" ] || die "${DATA}/clickhouse is not empty - a build needs an empty scratch folder at ${DATA}"
  [ "${CBIO_VERSION}" != "unknown" ] || die "CBIO_VERSION is not set in the image (Containerfile ENV) - cannot label the snapshot"

  ## The importer needs no login: application.properties without OIDC
  CBIO_AUTH=false
  check_reports
  prepare_dirs build
  load_env
  write_client_config
  write_app_properties
  build_importer_jar
  : > "${STUDY_SUMMARY}"

  trap 'build_exit $?' EXIT
  trap 'exit 1' TERM INT

  log "1/4 ClickHouse (${DATA}/clickhouse, local scratch)"; start_clickhouse; init_db
  for folder in "${folders[@]}"; do
    i=$((i + 1))
    log "2/4 Study ${i}/${#folders[@]}: ${folder}"
    import_study "${STUDIES}/${folder}"
  done
  log "3/4 Studies in the snapshot"
  ch_studies_tsv
  stop_service "${CH_PID}" "ClickHouse" 120; CH_PID=""     # clean stop before the DB folder is copied
  log "4/4 Publish"
  publish_snapshot "$(basename "${manifest}")"
  trap - EXIT TERM INT
  log "Build done: ${SNAPSHOTS}/${CBIO_SNAPSHOT_ID}
 Host VM: set CBIO_DB_SNAPSHOT=${CBIO_SNAPSHOT_ID} in the unit, then restart (README 'Add / update a study').
 The scratch folder (${DATA} here) is no longer needed."
}

do_snapshots() {   # list SNAPSHOTS: id, READY, cBioPortal version, size, studies; * = active on this host
  local active=""
  active=$(cat "${DATA}/clickhouse/.snapshot_id" 2>/dev/null || true)
  [ -d "${SNAPSHOTS}" ] || die "${SNAPSHOTS} not mounted"
  log "Snapshots in ${SNAPSHOTS} (* = active here; this image: cBioPortal ${CBIO_VERSION})"
  python3 -I - "${SNAPSHOTS}" "${active}" <<'PYEOF'
import json, os, sys
root, active = sys.argv[1:3]
print(f"  {'id':<24} {'ready':<6} {'cbio':<8} {'size':>8}  studies")
for d in sorted(os.listdir(root)):
    p = os.path.join(root, d)
    if not os.path.isdir(p):
        continue
    ready = "yes" if os.path.exists(os.path.join(p, "READY")) else "NO"
    try:
        info = json.load(open(os.path.join(p, "BUILD_INFO.json")))
    except (OSError, ValueError):
        info = {}
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs
               if not os.path.islink(os.path.join(r, f)))
    studies = ", ".join(s.get("study_id", "?") for s in info.get("studies", []))
    mark = "*" if d == active else " "
    print(f"{mark} {d:<24} {ready:<6} {info.get('cbio_version', '?'):<8} {size / 1e6:>6.0f}MB  {studies}")
PYEOF
}

do_sync_access() {
  load_env
  write_client_config
  if [ "${AUTHZ}" != "opa" ]; then
    echo "Access mode '${AUTHZ}': nothing to sync (access comes from meta_study.txt 'groups:')"; exit 0
  fi
  ch_client --query "SELECT 1" >/dev/null 2>&1 || die "ClickHouse is not answering - is the container started (podman ps)?"
  exec 9> "${SYNC_LOCK}"
  flock -w 600 9 || die "another import or access sync is still running - try again later"
  log "Sync study access from OPA (${OPA_URL}, ${OPA_POLICY_PATH})"
  local rc=0
  sync_access verbose || rc=1
  report_refresh
  do_studies
  exit "${rc}"
}

do_studies() {
  load_env
  write_client_config
  log "Studies in the portal (groups = who can see them; access decided by: ${AUTHZ}; ${OPA_DENY_GROUP} = hidden)"
  ch_client --database "${CH_DB}" --query \
    "SELECT cancer_study_identifier AS study_id, name, groups, import_date FROM cancer_study ORDER BY cancer_study_identifier FORMAT PrettyCompactMonoBlock"
}

do_healthcheck() {
  load_env
  [ -s "${CONF}/clickhouse/client.xml" ] || exit 1
  ch_client --query "SELECT 1" >/dev/null 2>&1           || { echo "ClickHouse down"; exit 1; }
  tcp_up "${MONGO_PORT}"                                   || { echo "MongoDB down"; exit 1; }
  http_up "http://127.0.0.1:${SESSION_PORT}/"              || { echo "session-service down"; exit 1; }
  http_up "http://127.0.0.1:${CBIO_PORT}/api/health"       || { echo "cBioPortal webapp down"; exit 1; }
  http_up "http://127.0.0.1:${CBIO_REPORTS_PORT}/reports/health" || { echo "report server down"; exit 1; }
  echo "healthy"
}


case "${CMD}" in
  build)       do_build "${2:-}" ;;
  start)       do_start ;;
  snapshots)   do_snapshots ;;
  studies)     do_studies ;;
  sync-access) do_sync_access ;;
  healthcheck) do_healthcheck ;;
  import)      die "the portal no longer imports: studies go into a snapshot made on the Build VM
       (deploy/c3g-cbioportal-build.sh -> /app/entrypoint.sh build <manifest>), README 'Add / update a study'" ;;
  *)           echo "Usage: /app/entrypoint.sh {build /manifests/<name>.txt|start|snapshots|studies|sync-access|healthcheck}"; exit 1 ;;
esac


### How to run: ###
# (full commands in README.md; <shared> = the SD4H storage mounted on both VMs)
# --- Build VM: study folders + PCGR reports on the shared storage, one manifest per build
# cp -r <study_folder> <shared>/studies/
# mkdir -p <shared>/reports/<cancer_study_identifier> && cp <group>.pcgr_acmg.grch38.flexdb.html ... <shared>/reports/<cancer_study_identifier>/
# echo <study_folder> >> <shared>/manifests/portal.txt        # every study the portal should serve
# ./deploy/c3g-cbioportal-build.sh portal.txt                  # = podman run --rm ... build /manifests/portal.txt
# --- Host VM (as user genome via `sudo machinectl shell genome@`)
# systemctl --user enable --now c3g-cbioportal-opa.service    # OPA first (policy bundle from c3g-opa-policies)
# (set -e CBIO_DB_SNAPSHOT=<id> in c3g-cbioportal.service; systemctl --user daemon-reload)
# systemctl --user restart c3g-cbioportal.service             # copies the snapshot to /data/clickhouse, serves it
# podman logs -f c3g-cbioportal
# podman exec c3g-cbioportal /app/entrypoint.sh snapshots      # which snapshots exist, which one is active
# podman exec c3g-cbioportal /app/entrypoint.sh studies
# podman exec c3g-cbioportal /app/entrypoint.sh sync-access   # after an OPA policy change, instead of waiting 5 min
# podman healthcheck run c3g-cbioportal
# systemctl --user stop c3g-cbioportal.service              # clean, ordered shutdown (--stop-timeout 300)
