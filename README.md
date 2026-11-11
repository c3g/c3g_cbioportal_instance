# c3g_cbioportal_instance
_Last Modified:_ 2026-11-11

**Authors:** Gerardo Zapata

Private [cBioPortal](https://www.cbioportal.org/) 7.1.2 for C3G client studies, in **one container**: webapp + ClickHouse + MongoDB + session-service, run by `entrypoint.sh`.
Login: C3G COmanage (OIDC). Study access: decided by **OPA**, per COmanage group.

- URL: https://cbioportal.c3g-app.sd4h.ca · Genome: **GRCh38**
- Follows the C3G [web-app-template](https://github.com/c3g/web-app-template); exceptions in [Differences](#differences-from-the-web-app-template).

---

## Installation

Published to ghcr.io on each GitHub Release (tags `latest` + `<release>`). Repo and image are **private**: `podman login ghcr.io` first.

```bash
podman pull ghcr.io/c3g/c3g_cbioportal_instance:latest
# or build locally
podman build -t c3g_cbioportal_instance:dev -f Containerfile .
```

---

## Requirements

| What | Detail |
|------|--------|
| Volume `/home/genome/cbioportal-volume` | XFS label `cbioportal`. Database + study folders |
| RAM | ≥ 16 GB (24 GB when importing large studies while up) |
| Host port | `8080` in the unit — **ASK** the maintainer |
| OPA container `c3g-cbioportal-opa` | Pinned `openpolicyagent/opa`, `127.0.0.1:8181`, bundle from c3g-opa-policies — bundle URL **ASK** |
| Database | None on the shared Postgres (ClickHouse + MongoDB are inside the container) |

**COmanage OIDC client** (from the COmanage admins, once) → issuer URL, client ID, client secret:

| Setting | Value |
|---------|-------|
| Redirect URI | `https://cbioportal.c3g-app.sd4h.ca/login/oauth2/code/cbio-idp` |
| Grant / auth method | `authorization_code` / `client_secret_basic` |
| Scopes | `openid profile email org.cilogon.userinfo` |
| Claims | `email`, `name`, `groups` |

**Podman secrets:**

| Secret | `target=` | Value |
|--------|-----------|-------|
| `C3G_CBIOPORTAL_OIDC_CLIENT_SECRET` | `OIDC_CLIENT_SECRET` | From COmanage |
| `C3G_CBIOPORTAL_CH_PASSWORD` | `CLICKHOUSE_PASSWORD` | Random string |

**Per study:** the study folder (pipeline output) + its entry in `c3g_cbioportal/data.json` in c3g-opa-policies.

---

## How to Run

On the VM, as `genome`: `bastion_ssh <you>@prod-appserver-podman-1` → `sudo machinectl shell genome@`.

**1. Volume** (root, once): template [for-maintainers.md](https://github.com/c3g/web-app-template/blob/main/for-maintainers.md) "Reserve space", `APPNAME=cbioportal`.

**2. Secrets + registry login** (once):

```bash
read -rs S && printf '%s' "$S" | podman secret create C3G_CBIOPORTAL_OIDC_CLIENT_SECRET - ; unset S
python3 -c 'import secrets; print(secrets.token_hex(16), end="")' | podman secret create C3G_CBIOPORTAL_CH_PASSWORD -
podman login ghcr.io -u <github_user>      # token with read:packages only
```

**3. OPA** (once): add the `c3g_cbioportal/` policy to c3g-opa-policies (start from [`opa/c3g_cbioportal/`](opa/c3g_cbioportal/)), set `<bundle_url>` in [`deploy/c3g-cbioportal-opa.service`](deploy/c3g-cbioportal-opa.service):

```bash
cp c3g-cbioportal-opa.service ~/.config/systemd/user/.
systemctl --user enable --now c3g-cbioportal-opa.service
curl -s -X POST http://127.0.0.1:8181/v1/data/c3g_cbioportal/authz/study_access   # study -> groups
```

**4. Portal**: set `<issuer_url>`, `<client_id>`, host port in [`deploy/c3g-cbioportal.service`](deploy/c3g-cbioportal.service):

```bash
cp c3g-cbioportal.service ~/.config/systemd/user/.
systemctl --user enable --now c3g-cbioportal.service
podman logs -f c3g-cbioportal              # ready at "All services up"
```

- First launch loads the DB: ~10–15 min. Later starts: ~2–3 min.
- Refuses to start without `OIDC_ISSUER` / `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET`.
- OPA not answering → starts, but **every study is hidden** until OPA is back.
- Same commands without systemd: [`run.sh`](run.sh).

**5. nginx** (proxy VM, once): template server block, `server_name cbioportal.c3g-app.sd4h.ca;`, `proxy_pass http://172.16.8.75:<host_port>;`. Straight to the app, no oauth2-proxy.

**6. Import a study** (after its OPA entry exists):

```bash
cp -r <study_folder> /home/genome/cbioportal-volume/studies/
podman exec c3g-cbioportal /app/entrypoint.sh import /data/studies/<study_folder>
```

Refuses studies OPA has no rule for. Re-run to replace a study.

**7. Operate:**

```bash
podman exec c3g-cbioportal /app/entrypoint.sh studies       # studies + groups
podman exec c3g-cbioportal /app/entrypoint.sh sync-access   # apply an OPA change now (else ≤ 5 min)
podman healthcheck run c3g-cbioportal
systemctl --user stop|start c3g-cbioportal.service          # ordered, clean shutdown
```

- **Update:** publish a GitHub Release → auto-update pulls `latest` within ~15 min. Schema migrates on start. **Back up the volume before a release that changes `CBIO_VERSION`** (migrations are one-way).
- **Roll back:** pin a release tag in the unit (`:v1.0.0`), `systemctl --user daemon-reload && systemctl --user restart c3g-cbioportal.service`.

**Local test** (laptop, no login — never on the VM):

```bash
podman run -d --name cbio-test --stop-timeout=300 -e CBIO_AUTH=false \
  -v ./data:/data:Z -p 127.0.0.1:8080:8080 c3g_cbioportal_instance:dev
```

---

## Access control

| Step | By |
|------|----|
| Authentication + groups | cBioPortal's OIDC login → COmanage `groups` claim |
| Decision | OPA, policy `c3g_cbioportal/authz` + `data.json` (c3g-opa-policies) |
| Enforcement | cBioPortal's study filter (user group ∈ study `groups`) |
| Bridge | `entrypoint.sh` writes OPA's groups per study into the DB: at start, after `import`, every 5 min, on `sync-access` |

**Fail closed:** studies OPA does not list → group `C3G_OPA_DENY` (nobody). OPA down or bad answer → every study `C3G_OPA_DENY`. Never create that group in COmanage.

`data.json` (real one in c3g-opa-policies; placeholder in [`opa/`](opa/c3g_cbioportal/data.json)):

```json
{ "c3g_cbioportal": {
    "admin_groups": ["c3g-cbioportal-admins"],
    "study_groups": { "<cancer_study_identifier>": ["c3g-cbioportal-<group>"] } } }
```

- `admin_groups` see every listed study.
- Group strings must match the token's `groups` claim exactly — **confirm format on first login**.
- Real group/study names only in c3g-opa-policies, never in this repo.
- Test the policy: `opa test opa/c3g_cbioportal/ -v`.
- **Fallback** `CBIO_AUTHZ=meta_study` (tests without OPA): `groups:` in `meta_study.txt` decides. Not for the VM.

**Onboard:** PI approves in writing → user enrols in COmanage → sysadmin adds to `c3g-cbioportal-<group>` + access register → user checks what they see.
**Offboard:** remove from the group, end-date the register (effective next login). Reconcile quarterly.
**New study:** add to `data.json` (new COmanage group if needed) → bundle updates → `import`.
**Revoke a study:** remove it / its group from `data.json` → ≤ 5 min or `sync-access`.

The access register holds personal data and is **never** in this repo.

---

## Configuration

`-e VAR=value` in the unit; credentials only via `--secret`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `OIDC_ISSUER` / `OIDC_CLIENT_ID` | **required** | From COmanage |
| `OIDC_CLIENT_SECRET` | **required** (secret) | From COmanage |
| `CLICKHOUSE_PASSWORD` | secret; else generated in `/data/config/.ch_password` | Internal DB password |
| `OIDC_REDIRECT_URI` | `https://cbioportal.c3g-app.sd4h.ca/login/oauth2/code/cbio-idp` | Must match registration |
| `OIDC_SCOPES` | `openid,profile,email,org.cilogon.userinfo` | |
| `OIDC_CLIENT_AUTH_METHOD` | `client_secret_basic` | or `client_secret_post` |
| `OIDC_USERNAME_CLAIM` / `OIDC_ROLES_PATH` | `email` / `groups` | User name / groups claim |
| `CBIO_AUTH` | `oauth2` | `false` = no login (local test only) |
| `CBIO_AUTHZ` | `opa` | `meta_study` = fallback without OPA |
| `OPA_URL` | `http://10.0.2.2:8181` | App's OPA |
| `OPA_POLICY_PATH` | `c3g_cbioportal/authz` | Queries rule `study_access` |
| `CBIO_OPA_SYNC_SECS` | `300` | Sync interval (≥ 30) |
| `OPA_DENY_GROUP` | `C3G_OPA_DENY` | Group for denied studies |
| `CBIO_FILTER_GROUPS_BY_APPNAME` | `false` | Only `cbioportal:`-prefixed groups |
| `CBIO_ALWAYS_SHOW_STUDY_GROUP` | (empty) | Group visible to every logged-in user |
| `CBIO_DATA_DIR` | `/data` | All app data |
| `CBIO_NCBI_BUILD` / `CBIO_UCSC_BUILD` | `38` / `hg38` | Genome |
| `CBIO_SKIN_TITLE` / `CBIO_RIGHT_LOGO` | `C3G cBioPortal` / `c3g_logo.svg` | Header |
| `CBIO_JAVA_OPTS` / `CBIO_IMPORT_JAVA_OPTS` / `SESSION_JAVA_OPTS` | `-Xms2g -Xmx4g` / `-Xms2G -Xmx8G` / `-Xms256m -Xmx1g` | Heaps |
| `CH_MAX_MEMORY` / `MONGO_CACHE_GB` | 8 GB / `1` | DB memory |
| `CBIO_FORWARD_HEADERS` | `framework` | Trust nginx `X-Forwarded-*` |
| `CBIO_PORT` | `8080` | Container port |
| `CH_HTTP_PORT` / `CH_NATIVE_PORT` / `SESSION_PORT` / `MONGO_PORT` | `8123` / `9000` / `5001` / `27017` | Internal (127.0.0.1) |

---

## Data (`/data` = the volume)

| Folder | Content |
|--------|---------|
| `studies/` | Study folders to import |
| `config/` | Generated configs, importer JAR, credentials (chmod 600) |
| `clickhouse/`, `mongo/` | Databases |
| `logs/` | Per-service logs, `access_sync.log`, `import_<study>.log` + validation HTML |
| `portalinfo/` | Offline-validation dump |

- **Back up:** stop the unit, copy the volume, start.
- **Start over:** stop, empty `clickhouse/` + `mongo/`, start (studies must be re-imported).

---

## Handing off to a maintainer

| Item | Value |
|------|-------|
| `podman run` | [`run.sh`](run.sh); units in [`deploy/`](deploy/) |
| Image | `ghcr.io/c3g/c3g_cbioportal_instance` (private) |
| Trigger | Published Release → `latest` + `<release>` |
| Database | No Postgres |
| Secrets | `C3G_CBIOPORTAL_OIDC_CLIENT_SECRET` → `OIDC_CLIENT_SECRET`; `C3G_CBIOPORTAL_CH_PASSWORD` → `CLICKHOUSE_PASSWORD` |
| Volume | `/home/genome/cbioportal-volume` → `/data` (label `cbioportal`) |
| Auth | Tier 3b: in-app OIDC + OPA `c3g-cbioportal-opa` (`127.0.0.1:8181`) |
| OPA policy | `c3g_cbioportal/` in c3g-opa-policies; bundle URL **ASK** |
| nginx | `proxy_pass http://172.16.8.75:<host_port>` |

---

## Differences from the web-app-template

Need maintainer sign-off before the first deploy.

| Template | Here | Why |
|----------|------|-----|
| Postgres only | ClickHouse + MongoDB in the container | cBioPortal 7 needs ClickHouse; session-service needs MongoDB |
| App asks OPA per request | OPA decides per study; synced into cBioPortal ≤ 5 min; fail closed | cBioPortal is upstream Java, no OPA hook |
| 3b only for non-browser clients | In-app OIDC | cBioPortal's own login; needed for per-study access |
| Logged-in ≠ allowed in (Tier 2) | Any COmanage user can sign in, sees no study without a group | No group login gate in cBioPortal; no second auth layer allowed |
| 10 s stop timeout | `--stop-timeout=300` | Ordered shutdown, ClickHouse stops cleanly |
| App in `/app` | cBioPortal stays in the base image's paths | Upstream image layout |

---

## Repo contents

| File | Purpose |
|------|---------|
| `Containerfile` | cBioPortal 7.1.2 + MongoDB 8.0 + ClickHouse 24.10 + session-service 0.6.4 + logo |
| `entrypoint.sh` | `start` / `import` / `studies` / `sync-access` / `healthcheck` |
| `config/clickhouse-*.xml` | Static ClickHouse configs (values from env) |
| `run.sh` | Exact `podman run` commands (OPA + portal) |
| `deploy/*.service` | systemd user units (portal, OPA) |
| `opa/c3g_cbioportal/` | Policy, tests, placeholder data |
| `.github/workflows/publish-container.yml` | Template workflow (buildah amd64 + arm64 → ghcr.io) |

Adapted from `<client_project>/6_cbioInstance.sh` (Narval) and [cbioportal-docker-compose](https://github.com/cBioPortal/cbioportal-docker-compose).

---

## Still to verify

1. session-service 0.6.4 on Java 21 + MongoDB 8.0.
2. COmanage login; `groups` claim read and its format.
3. Offline validation (`DumpPortalInfo` + `metaImport.py -p`).
4. Clean ClickHouse after `systemctl --user stop`.
5. Logo shows.
6. amd64 + arm64 build fits GitHub Actions (else drop `arm64`).
7. Logout behaviour (CILogon session may persist).
8. OPA `data.json` layout in c3g-opa-policies; `--bundle <URL>` vs remote-bundle config.
9. `ALTER TABLE cancer_study UPDATE "groups"` works; no derived copy of `groups`.
10. `DELETE /api/cache` refreshes the webapp (else it restarts after each change, ~2–3 min down).
11. `C3G_OPA_DENY` studies hidden everywhere (study list, counts).

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Exits at once | `podman logs`: missing `OIDC_*` or secret |
| Webapp never up | `logs/cbioportal.log`; issuer reachable from the VM |
| Login loop / `redirect_uri` error | `OIDC_REDIRECT_URI` exact; nginx sends `X-Forwarded-Proto` |
| nginx 502 "too big header" | `proxy_buffer_size 32k;` |
| User sees no study | Token `groups` vs `studies` output vs `data.json` |
| All studies `C3G_OPA_DENY` | OPA down / wrong policy: `logs/access_sync.log`, `systemctl --user status c3g-cbioportal-opa` |
| `import`: "OPA gives no group access" | Add study to `data.json`, wait for bundle |
| "tables but no seed data" | Interrupted first launch: stop, empty `clickhouse/`, start |

---

## References

- C3G web-app-template: https://github.com/c3g/web-app-template
- cBioPortal: https://github.com/cBioPortal/cbioportal · https://docs.cbioportal.org
- Cerami E. *et al.* *Cancer Discovery* 2012;2(5):401–404.
- Gao J. *et al.* *Science Signaling* 2013;6(269):pl1.
- de Bruijn I. *et al.* *Cancer Research* 2023;83(23):3861–3867.

License: AGPL-3.0.
