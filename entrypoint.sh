#!/bin/bash
################################################################################
### c3g_cbioportal_instance - container entrypoint
### One container = cBioPortal 7.1.2 webapp + ClickHouse server + MongoDB + session-service.
### Logic adapted from cbioportal-docker-compose:
###   ClickHouse -> schema/seed/derived tables (first launch only) -> schema migration
###   -> mongod -> session-service -> cBioPortal webapp (login through OIDC)
###
### Subcommands:
###   start             (default CMD) start every service, webapp last. First launch also loads the DB.
###                     On SIGTERM (podman stop) stops webapp -> session-service -> mongod -> ClickHouse.
###   import <study>    offline-validate + import a study folder from /data/studies (podman exec)
###   studies           list the studies in the DB with their access groups (podman exec)
###   sync-access       re-apply OPA's study -> groups decisions now (podman exec; also runs every CBIO_OPA_SYNC_SECS)
###   healthcheck       exit 0 when every service answers (image HEALTHCHECK)
###
### Access:   authentication = cBioPortal's OIDC login (COmanage); decisions = OPA (the app's own OPA container,
###           policy c3g_cbioportal/authz from c3g-opa-policies); enforcement = cBioPortal's study filter, fed by
###           writing OPA's answer into cancer_study.groups. OPA unreachable -> every study hidden (fail closed).
###           CBIO_AUTHZ=meta_study = fallback for tests without OPA (meta_study.txt 'groups:' decides).
###
### Data:     /data (CBIO_DATA_DIR) = the app volume, as in the C3G web-app-template:
###           studies/ (cBioPortal study folders), config/, clickhouse/, mongo/, logs/, portalinfo/
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

## Fixed paths / names (DATA itself can be moved with CBIO_DATA_DIR)
DATA=${CBIO_DATA_DIR:-/data}                       # C3G web-app-template: app data under /data
STUDIES=${DATA}/studies
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
CH_PID=""; MONGO_PID=""; SESSION_PID=""; WEB_PID=""; SLEEP_PID=""


################################################################################
### Helpers

log() { echo -e "\n ${DIVIDER} \n $* \n"; }
die() { echo "ERROR: $*" >&2; exit 1; }

prepare_dirs() {
  mkdir -p "${CONF}/clickhouse" "${DATA}/clickhouse" "${DATA}/mongo" "${LOGS}" "${STUDIES}"
  chmod 700 "${CONF}"
  mountpoint -q "${DATA}" 2>/dev/null || echo "WARNING: ${DATA} is not a mounted volume - the database is lost when the container is removed"
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

init_db() {   # = data/init.sh + load_schema.sh + load_seed.sh + load_derived_tables.sh (first launch only)
  local n_tables n_toc
  n_tables=$(ch_client --query "SELECT count() FROM system.tables WHERE database = '${CH_DB}'")
  if [ "${n_tables}" -eq 0 ]; then
    log "First launch: load schema + seed + derived tables (takes several minutes)"
    ch_client --query "CREATE DATABASE IF NOT EXISTS ${CH_DB}"
    echo "Loading schema..."
    ch_client --database "${CH_DB}" --multiquery < "${DB_SCRIPTS}/init/schema.sql"
    echo "Loading seed data (${SEED_SQL})..."
    gunzip -c "${DB_SCRIPTS}/init/${SEED_SQL}" | ch_client --database "${CH_DB}" --multiquery
    echo "Populating derived tables..."
    ch_client --database "${CH_DB}" --multiquery --param_optimize_backoff_secs=0 < "${DB_SCRIPTS}/populate_derived_tables.sql"
  else
    n_toc=$(ch_client --query "SELECT COUNT(*) FROM ${CH_DB}.type_of_cancer")
    [ "${n_toc}" -gt 0 ] || die "database '${CH_DB}' has tables but no seed data (an earlier first launch was interrupted).
       Stop the container, empty ${DATA}/clickhouse/ on the host volume, and start again."
    echo "Database ${CH_DB} already loaded - skipping"
  fi
  ## docker-compose healthcheck - must be > 0
  echo "type_of_cancer rows: $(ch_client --query "SELECT COUNT(*) FROM ${CH_DB}.type_of_cancer")"

  ## = cbioportal-migration service (no-op when the schema is current; needed after an image upgrade)
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
### Subcommands

do_start() {
  log "c3g_cbioportal_instance: start ($(date '+%Y-%m-%d %H:%M:%S'))"
  check_auth
  prepare_dirs
  load_env
  write_client_config
  write_app_properties
  build_importer_jar

  ## From here on, any failure / podman stop shuts the started services down in order
  trap 'shutdown $?' EXIT
  trap 'exit 0' TERM INT

  log "1/5 ClickHouse";      start_clickhouse; init_db
  log "2/5 Study access (${AUTHZ})"
  locked_sync 60 verbose || echo "WARNING: studies stay hidden until OPA answers (retried every ${CBIO_OPA_SYNC_SECS} s)"
  rm -f "${STALE_FLAG}"      # the webapp is not up yet: it reads the current access when it starts
  log "3/5 MongoDB";         start_mongo
  log "4/5 session-service"; start_session
  log "5/5 cBioPortal webapp (port ${CBIO_PORT}, login: ${CBIO_AUTH}, access: ${AUTHZ})"; start_webapp
  log "All services up. Logs: ${LOGS}/
 Import a study:  podman exec <container> /app/entrypoint.sh import /data/studies/<study_folder>"

  ## Stay in the foreground. Every CBIO_OPA_SYNC_SECS: re-apply OPA's decisions and refresh the webapp
  ## if studies/access changed. If any service exits on its own, stop the others and exit 1
  ## (systemd / podman restart policy brings the container back).
  local done_pid
  while true; do
    sleep "${CBIO_OPA_SYNC_SECS}" & SLEEP_PID=$!
    done_pid=""
    wait -n -p done_pid "${SLEEP_PID}" "${CH_PID}" "${MONGO_PID}" "${SESSION_PID}" "${WEB_PID}" || true
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

do_import() {
  local study_dir=${1:-} study rc
  [ -n "${study_dir}" ] || die "Usage: /app/entrypoint.sh import /data/studies/<study_folder>"
  [ -d "${study_dir}" ] || die "${study_dir} not found inside the container (copy study folders to <volume>/studies/ on the VM)"
  study_dir=$(realpath "${study_dir}")
  [ -s "${study_dir}/meta_study.txt" ] || die "no meta_study.txt in ${study_dir} (pipeline output complete?)"
  study=$(basename "${study_dir}")
  study_id=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' "${study_dir}/meta_study.txt" | tr -d '[:space:]')
  [ -n "${study_id}" ] || die "no cancer_study_identifier in ${study_dir}/meta_study.txt"

  load_env
  ## One import / access sync at a time (lock released when this process exits)
  exec 9> "${SYNC_LOCK}"
  flock -w 600 9 || die "another import or access sync is still running - try again later"

  log "Import ${study_dir}"
  cat "${study_dir}/meta_study.txt"; echo

  ## Access control (decided before anything is loaded)
  case "${AUTHZ}" in
    opa)
      ## OPA must already allow the study, else it would be imported hidden
      local allowed
      allowed=$(opa_has_study "${study_id}") || die "OPA gives no group access to study '${study_id}' (${allowed:-no rule}).
       Add it to c3g_cbioportal/data.json in c3g-opa-policies, wait for the OPA bundle to update, import again."
      echo "OPA: study ${study_id} visible to: ${allowed}"
      if grep -qE '^groups:' "${study_dir}/meta_study.txt"; then
        echo "(meta_study.txt 'groups:' is replaced by OPA's decision right after the import)"
      fi
      ;;
    meta_study)
      ## Fallback: a study without 'groups:' is visible to no logged-in user (fix it in the pipeline, not by hand)
      grep -qE '^groups:[[:space:]]*[^[:space:]]' "${study_dir}/meta_study.txt" \
        || die "CBIO_AUTHZ=meta_study but meta_study.txt has no 'groups:' line - set the study group in the pipeline and re-run it"
      ;;
    off)
      grep -qE '^groups:[[:space:]]*[^[:space:]]' "${study_dir}/meta_study.txt" \
        || echo "WARNING: no 'groups:' in meta_study.txt (accepted only because CBIO_AUTH=false)"
      ;;
  esac

  write_client_config
  ch_client --query "SELECT 1" >/dev/null 2>&1 || die "ClickHouse is not answering - is the container started (podman ps)?"
  [ -s "${IMPORTER_JAR}" ] || die "${IMPORTER_JAR} missing - start the container once first"

  ## Offline validation: the portal API is behind login, so dump gene/cancer-type info from the DB instead of -u <url>
  log "Dump portal info (offline validation)"
  rm -rf "${PORTALINFO}"; mkdir -p "${PORTALINFO}"
  java ${CBIO_IMPORT_JAVA_OPTS} -cp "${IMPORTER_JAR}" org.mskcc.cbio.portal.scripts.DumpPortalInfo "${PORTALINFO}" \
    > "${LOGS}/dumpPortalInfo.log" 2>&1 || die "DumpPortalInfo failed - see ${LOGS}/dumpPortalInfo.log"

  ## = docker compose run cbioportal metaImport.py -u http://cbioportal:8080 -s study/... -o
  log "Validate + import ${study}"
  set +e
  metaImport.py -p "${PORTALINFO}" -s "${study_dir}" -o \
    -jvo "${CBIO_IMPORT_JAVA_OPTS}" \
    -jar "${IMPORTER_JAR}" \
    --derived-table-sql "${DB_SCRIPTS}/populate_derived_tables.sql" \
    -html "${LOGS}/import_validation_${study}.html" \
    2>&1 | tee "${LOGS}/import_${study}.log"
  rc=${PIPESTATUS[0]}
  set -e
  echo -e "\n Validation report: ${LOGS}/import_validation_${study}.html \n Import log:        ${LOGS}/import_${study}.log"
  [ "${rc}" -eq 0 ] || die "metaImport.py exited with code ${rc}"

  ## Apply OPA's decision to the new study at once (replaces the imported 'groups:'), then refresh the webapp
  if [ "${AUTHZ}" == "opa" ]; then
    sync_access verbose || echo "WARNING: access sync failed - see ${LOGS}/access_sync.log"
  else
    touch "${STALE_FLAG}"
  fi
  report_refresh

  do_studies
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
  echo "healthy"
}


case "${CMD}" in
  start)       do_start ;;
  import)      do_import "${2:-}" ;;
  studies)     do_studies ;;
  sync-access) do_sync_access ;;
  healthcheck) do_healthcheck ;;
  *)           echo "Usage: /app/entrypoint.sh {start|import /data/studies/<study_folder>|studies|sync-access|healthcheck}"; exit 1 ;;
esac


### How to run: ###
# (on the webapp VM, as user genome via `sudo machinectl shell genome@` - full commands in README.md)
# systemctl --user enable --now c3g-cbioportal-opa.service # OPA first (policy bundle from c3g-opa-policies)
# systemctl --user enable --now c3g-cbioportal.service     # = run.sh flags; CMD start
# podman logs -f c3g-cbioportal                             # first launch loads the DB
# cp -r <study_folder> /home/genome/cbioportal-volume/studies/
# podman exec c3g-cbioportal /app/entrypoint.sh import /data/studies/<study_folder>
# podman exec c3g-cbioportal /app/entrypoint.sh studies
# podman exec c3g-cbioportal /app/entrypoint.sh sync-access   # after an OPA policy change, instead of waiting 5 min
# podman healthcheck run c3g-cbioportal
# systemctl --user stop c3g-cbioportal.service              # clean, ordered shutdown (--stop-timeout 300)
