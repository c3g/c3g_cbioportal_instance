# c3g_cbioportal_instance
_Last Modified:_ 2026-11-20

**Authors:** Gerardo Zapata

> ⚠️ **AI-written.** This README and the code in this repo (`entrypoint.sh`, `reports_server.py`, `Containerfile`, OPA policy, `run.sh`, `deploy/`) were written with an AI assistant (Claude, Anthropic). Check it against the code and test before relying on it, especially access control.

Private [cBioPortal](https://www.cbioportal.org/) 7.1.2 for C3G client studies, in **one container**: webapp + ClickHouse + MongoDB + session-service, run by `entrypoint.sh`.
Login: C3G COmanage (OIDC). Study access: decided by **OPA**, per COmanage group.
Per-sample **PCGR reports** open as a tab in the patient view, with the same study access ([PCGR reports](#pcgr-reports)).

**Two VMs, one image:**

| Role | Command | Does | Never |
|------|---------|------|-------|
| **Build VM** | `deploy/c3g-cbioportal-build.sh <manifest>` (= `entrypoint.sh build`) | Imports every study of a manifest into a fresh ClickHouse DB on **local** scratch, publishes it as a **snapshot** on shared SD4H storage | Serves anything |
| **Host VM** (webapp VM) | systemd unit (= `entrypoint.sh start`) | Copies the snapshot named by `CBIO_DB_SNAPSHOT` (read-only mount) to its local `/data/clickhouse` and serves it | Imports |

```
<shared> (SD4H storage, mounted on both VMs)
├── studies/<folder>/            study folders (pipeline output)            ← you copy in
├── reports/<study_id>/*.html    PCGR reports                               ← you copy in
├── manifests/<name>.txt         one study folder per line = one build      ← you edit
└── snapshots/<YYYYmmdd-HHMMSS>/ clickhouse/ reports/ logs/ BUILD_INFO.json studies.tsv READY   ← builder only
```

- ClickHouse **never runs on the shared storage** (it's only the hand-off area), so NFS is fine there.
- A snapshot is never changed after `READY`. The host's own DB writes (schema migration, OPA groups) go to its local copy.
- Update = new snapshot + restart (~2–3 min down). Rollback = previous snapshot id + restart.

- URL: https://cbioportal.c3g-app.sd4h.ca 
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
| **Shared SD4H storage** | Mounted on the Build VM (read-write) and the Host VM (snapshots read-only). Layout above. Type / mount point **ASK** the SD4H admins |
| **Host VM** volume `/home/genome/cbioportal-volume` | XFS label `cbioportal`, **local/block disk** (ClickHouse runs here). Active DB copy, previous copy, MongoDB, config, logs |
| Host VM RAM | ≥ 16 GB (no imports here) |
| **Build VM** | podman, ghcr.io login, ≥ 20 GB RAM (build container capped at 18 GB: importer JVM 8 GB + ClickHouse 8 GB), local scratch disk (`SCRATCH_ROOT`, ~1 GB per build + study size) |
| Image tag | **Same on both VMs**: the host refuses a snapshot built with another cBioPortal version |
| Host ports | `8080` (portal) + `8090` (PCGR reports) in the unit — **ASK** the maintainer |
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

**Per study:** the study folder (pipeline output) on the shared storage, its line in the manifest, and its entry in `c3g_cbioportal/data.json` in c3g-opa-policies.

---

## How to Run

### Build VM

**B1. Shared storage** (once): mount it, then create `studies/ reports/ manifests/ snapshots/` under `<shared>`.

**B2. Registry login** (once): `podman login ghcr.io -u <github_user>` (token with `read:packages` only).

**B3. Build a snapshot**: [`deploy/c3g-cbioportal-build.sh`](deploy/c3g-cbioportal-build.sh). Set `SHARED`, `SCRATCH_ROOT` and `IMAGE` at the top (same tag as the host):

```bash
SHARED=<shared> ./c3g-cbioportal-build.sh portal.txt          # manifest = <shared>/manifests/portal.txt
```

- **Full rebuild every time:** empty DB → schema + seed (~10–15 min) → every study in the manifest → snapshot `<shared>/snapshots/<YYYYmmdd-HHMMSS>/`. The manifest lists **every** study the portal should serve.
- Each build gets a new scratch folder `SCRATCH_ROOT/build_<id>/`. Logs end up in the snapshot's `logs/` and in the scratch folder; remove the scratch folder by hand after a good build.
- **Failed build:** at most `<id>.partial/` is left (no `READY`). The host refuses it. Remove it by hand.
- **Optional:** `OPA_URL=http://<opa>:8181` prints a warning for studies OPA doesn't list. It never blocks the build: the host hides them anyway.
- `CBIO_REPORTS_URL` (public report URL) is written into the snapshot. Use the production value for VM builds.

### Host VM

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

**4. Portal**: in [`deploy/c3g-cbioportal.service`](deploy/c3g-cbioportal.service), set `<issuer_url>`, `<client_id>`, the host ports, `<shared_snapshots>` (= `<shared>/snapshots` on this VM, mounted `:ro`) and `<snapshot_id>` (a snapshot from the Build VM):

```bash
cp c3g-cbioportal.service ~/.config/systemd/user/.
systemctl --user enable --now c3g-cbioportal.service
podman logs -f c3g-cbioportal              # ready at "All services up, serving snapshot <id>"
```

- Start: ~2–3 min. A new snapshot is copied first (seconds for ~50 MB).
- Refuses to start without `OIDC_ISSUER` / `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET`, and without a usable `CBIO_DB_SNAPSHOT`: the snapshot must exist, have `READY`, and be built with the same cBioPortal version.
- OPA not answering → starts, but **every study is hidden** until OPA is back.
- Same commands without systemd: [`run.sh`](run.sh).

**5. nginx** (proxy VM, once): template server block, `server_name cbioportal.c3g-app.sd4h.ca;`, `proxy_pass http://172.16.8.75:<host_port>;`. Straight to the app, no oauth2-proxy.
Plus, in the same server block, the PCGR reports (same host name, so the portal login cookie reaches it):

```nginx
location /reports/ {
    proxy_pass http://172.16.8.75:<reports_host_port>;   # 8090
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

**6. Operate:**

```bash
podman exec c3g-cbioportal /app/entrypoint.sh snapshots     # snapshots on the shared storage, * = active
podman exec c3g-cbioportal /app/entrypoint.sh studies       # studies + groups
podman exec c3g-cbioportal /app/entrypoint.sh sync-access   # apply an OPA change now (else ≤ 5 min)
podman healthcheck run c3g-cbioportal
systemctl --user stop|start c3g-cbioportal.service          # ordered, clean shutdown
```

- **Image update:** a published GitHub Release → auto-update pulls `latest` within ~15 min. **A release that changes `CBIO_VERSION` makes the host refuse its current snapshot.** Before publishing it, pin the old tag in the unit, build a new snapshot with the new image, then switch both together.
- **Roll back the image:** pin a release tag in the unit (`:v1.0.0`), `systemctl --user daemon-reload && systemctl --user restart c3g-cbioportal.service`.

### Add / update a study

1. Copy the study folder to `<shared>/studies/` and its PCGR reports to `<shared>/reports/<cancer_study_identifier>/` ([PCGR reports](#pcgr-reports)).
2. Add the study's entry to `c3g_cbioportal/data.json` in c3g-opa-policies. Without it the study is built but **hidden** on the host.
3. Add the folder name to the manifest (`<shared>/manifests/portal.txt`). To replace a study, update its folder. To remove one, drop its line.
4. Build VM: `./c3g-cbioportal-build.sh portal.txt` → note the snapshot id it prints.
5. Host VM: set `-e CBIO_DB_SNAPSHOT=<id>` in the unit, then `systemctl --user daemon-reload && systemctl --user restart c3g-cbioportal.service`.
6. Check with `podman exec c3g-cbioportal /app/entrypoint.sh studies`.

**Roll back:** put the previous id back in the unit and restart.
- The last DB copy is also kept as `/data/clickhouse.prev/`.
- Restarting with the snapshot that is already active keeps the local copy as it is.
- MongoDB (users' saved sessions and virtual studies) stays on the host, whichever snapshot is served.

**Local test** (laptop, no login — never on the VMs). Put a study and its reports in `./shared/{studies,reports}/` and the manifest in `./shared/manifests/test.txt`, then:

```bash
mkdir -p shared/{studies,reports,manifests,snapshots} scratch host
SHARED=./shared SCRATCH_ROOT=./scratch IMAGE=c3g_cbioportal_instance:dev MEMORY=12g \
  CBIO_REPORTS_URL=http://localhost:8090/reports ./deploy/c3g-cbioportal-build.sh test.txt
podman run -d --name cbio-test --stop-timeout=300 -e CBIO_AUTH=false -e CBIO_DB_SNAPSHOT=<id> \
  -e CBIO_REPORTS_URL=http://localhost:8090/reports -e CBIO_PORTAL_ORIGIN=http://localhost:8080 \
  -v ./host:/data:Z -v ./shared/snapshots:/snapshots:ro \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8090:8090 c3g_cbioportal_instance:dev
```

---

## Access control

| Step | By |
|------|----|
| Authentication + groups | cBioPortal's OIDC login → COmanage `groups` claim |
| Decision | OPA, policy `c3g_cbioportal/authz` + `data.json` (c3g-opa-policies) |
| Enforcement | cBioPortal's study filter (user group ∈ study `groups`) |
| Bridge | `entrypoint.sh` (host) writes OPA's groups per study into its local DB copy: at start (before the webapp), every 5 min, on `sync-access`. Builds decide nothing about access |

**Fail closed:** studies OPA does not list → group `C3G_OPA_DENY` (nobody). OPA down or bad answer → every study `C3G_OPA_DENY`. Never create that group in COmanage.

`c3g_cbioportal/data.json` (real one in c3g-opa-policies; placeholder in [`opa/`](opa/c3g_cbioportal/data.json)):

```json
{ "admin_groups": ["c3g-cbioportal-admins"],
  "study_groups": { "<cancer_study_identifier>": ["c3g-cbioportal-<group>"] } }
```

No outer `"c3g_cbioportal"` key: OPA files `data.json` under its folder name (`c3g_cbioportal/` → `data.c3g_cbioportal`). Wrapping it again, or loading the folder on its own, gives every study no groups → all hidden.

- `admin_groups` see every listed study.
- Group strings must match the token's `groups` claim exactly — **confirm format on first login**.
- Real group/study names only in c3g-opa-policies, never in this repo.
- Test the policy from the **parent** folder: `opa test opa/ -v` (local server: `opa run --server --watch -b opa/`).
- **Fallback** `CBIO_AUTHZ=meta_study` (tests without OPA): `groups:` in `meta_study.txt` decides. Not for the VM.

**Onboard:** PI approves in writing → user enrols in COmanage → sysadmin adds to `c3g-cbioportal-<group>` + access register → user checks what they see.
**Offboard:** remove from the group, end-date the register (effective next login). Reconcile quarterly.
**New study:** add to `data.json` (new COmanage group if needed) → bundle updates → build a snapshot with it → serve it ([Add / update a study](#add--update-a-study)). A study OPA does not list is in the snapshot but hidden.
**Revoke a study:** remove it / its group from `data.json` → ≤ 5 min or `sync-access`.

The access register holds personal data and is **never** in this repo.

---

## PCGR reports

Each sample's PCGR flexdb report (`<group>.pcgr_acmg.grch38.flexdb.html`, self-contained HTML) opens as a **"PCGR report"** tab in the patient view.

| Step | How |
|------|-----|
| Files | `<shared>/reports/<cancer_study_identifier>/`, copied by hand (not part of the pipeline output) |
| Link | The build matches `<SAMPLE_ID><CBIO_REPORT_SUFFIX>`, else `<PATIENT_ID><CBIO_REPORT_SUFFIX>` (PCGR names reports by oncoanalyser group = `PATIENT_ID`) |
| Into cBioPortal | The build writes cBioPortal **resource** files (`meta/data_resource_definition.txt`, `meta/data_resource_sample.txt`, resource `PCGR_REPORT`, URL `CBIO_REPORTS_URL/<study_id>/<file>`) into a staging copy in its scratch `config/staging/<folder>/` (symlinks to the study + those 4 files) and imports that. **The study folder is never changed.** |
| Into the snapshot | The study's `*.html` files are copied to `snapshots/<id>/reports/<study_id>/`, so each snapshot serves exactly the reports it was built with |
| Serving | `reports_server.py` (port `8090`, nginx `/reports/`), from the active snapshot's `reports/` (read-only) |
| Access | Per request, it asks cBioPortal `GET /api/studies/<study_id>` with the viewer's own session cookie: `200` → file; not logged in → `401`; anything else (no access, unknown, portal down) → `404`. Same per-study access as the portal (OPA → study `groups`). |
| Hardening | Only `<study_id>/<name>.html` in that folder (letters, digits, `_ . -`); `Cache-Control: private, no-store`; CSP `sandbox` (report JS cannot reach portal cookies) + `frame-ancestors <CBIO_PORTAL_ORIGIN>`; log `logs/reports.log` (no cookies) |

- Resources cannot be loaded incrementally in cBioPortal: adding/replacing reports = copy files + **build a new snapshot**.
- A study that already has `resource_type:` meta files (e.g. from a future pipeline version) is imported as is; nothing is generated.
- The build prints for each study: reports found, samples linked, samples without a report, reports matching no sample.
- `CBIO_REPORTS_URL` is written into the snapshot: build again after changing it.

Hellen Kuasne WES example (on Narval, then copy `reports/` to `<shared>/reports/`):

```bash
P=/lustre06/project/6007512/C3G/projects/Park_Hellen_WES_Round2
D=<dest>/reports/hellenkuasne_wes_paired_test          # = cancer_study_identifier in meta_study.txt
mkdir -p "$D"
find "$P"/paired/nfcore_oncoanalyser_Both -path '*/pcgr_pcgr103/*.pcgr_acmg.grch38.flexdb.html' -exec cp -t "$D"/ {} +
ls "$D" | wc -l                                        # 84 expected
```

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
| `CBIO_DATA_DIR` | `/data` | Local app data. **Same on both VMs** (ClickHouse symlinks are absolute) |
| `CBIO_DB_SNAPSHOT` | **required** (host) | Snapshot id the host serves (folder in `/snapshots`) |
| `CBIO_SNAPSHOTS_DIR` | `/snapshots` | Shared snapshots folder (host: read-only; build: writable) |
| `CBIO_SNAPSHOT_ID` | `YYYYmmdd-HHMMSS` | Build: id of the new snapshot (set by the build script) |
| `CBIO_IMAGE_REF` | `unknown` | Build: image tag recorded in `BUILD_INFO.json` (set by the build script) |
| `CBIO_STUDIES_DIR` / `CBIO_BUILD_REPORTS_DIR` | `/studies` / `/reports` | Build inputs (read-only mounts) |
| `CBIO_REPORTS_URL` | `https://cbioportal.c3g-app.sd4h.ca/reports` | Public base URL of the reports (absolute; written into the snapshot at build) |
| `CBIO_PORTAL_ORIGIN` | scheme + host of `CBIO_REPORTS_URL` | Origin allowed to embed the reports (CSP `frame-ancestors`) |
| `CBIO_REPORTS_PORT` | `8090` | Report gatekeeper port |
| `CBIO_REPORT_SUFFIX` | `.pcgr_acmg.grch38.flexdb.html` | Report file = `<SAMPLE_ID or PATIENT_ID><suffix>` |
| `CBIO_REPORT_NAME` / `CBIO_REPORT_DESCRIPTION` | `PCGR report` / `Personal Cancer Genome Reporter (PCGR) report for this sample` | Tab name / description |
| `CBIO_REPORT_OPEN_BY_DEFAULT` | `true` | Tab opens with the patient view (`false` = from the resources table) |
| `CBIO_NCBI_BUILD` / `CBIO_UCSC_BUILD` | `38` / `hg38` | Genome |
| `CBIO_SKIN_TITLE` / `CBIO_RIGHT_LOGO` | `C3G cBioPortal` / `c3g_logo.svg` | Header |
| `CBIO_JAVA_OPTS` / `CBIO_IMPORT_JAVA_OPTS` / `SESSION_JAVA_OPTS` | `-Xms2g -Xmx4g` / `-Xms2G -Xmx8G` / `-Xms256m -Xmx1g` | Heaps |
| `CH_MAX_MEMORY` / `MONGO_CACHE_GB` | 8 GB / `1` | DB memory |
| `CBIO_FORWARD_HEADERS` | `framework` | Trust nginx `X-Forwarded-*` |
| `CBIO_PORT` | `8080` | Container port |
| `CH_HTTP_PORT` / `CH_NATIVE_PORT` / `SESSION_PORT` / `MONGO_PORT` | `8123` / `9000` / `5001` / `27017` | Internal (127.0.0.1) |

---

## Data

**Host VM `/data`** (= `/home/genome/cbioportal-volume`, local disk):

| Folder | Content |
|--------|---------|
| `clickhouse/` | Copy of the active snapshot's DB (`.snapshot_id` = which one) + the host's own writes (OPA groups, migration) |
| `clickhouse.prev/` | The DB served before the last switch (one kept) |
| `mongo/` | Session-service DB: users' saved sessions / virtual studies (host only, never in a snapshot) |
| `config/` | Generated configs, credentials (chmod 600) |
| `logs/` | Per-service logs, `access_sync.log`, `reports.log` |

**Snapshot `<shared>/snapshots/<id>/`** (written once by the build):

| Item | Content |
|------|---------|
| `clickhouse/` | Stopped ClickHouse folder: schema + seed + the manifest's studies (~50 MB for seed + 1 WES study) |
| `reports/<study_id>/` | PCGR reports linked in this build |
| `logs/` | `build.log`, `import_<study>.log` + validation HTML, `dumpPortalInfo.log` |
| `BUILD_INFO.json` / `studies.tsv` | Id, date, cBioPortal + ClickHouse version, image, manifest, studies |
| `READY` | Written last; no `READY` = unfinished, never served |

**Build scratch `SCRATCH_ROOT/build_<id>/`** (= the builder's `/data`): the DB while building, `config/staging/`, importer JAR, `portalinfo/`, logs. No longer needed after a good build.

- **Back up:** the snapshots are the study data. The host volume only holds `mongo/` that you can't rebuild (stop the unit, copy, start).
- **Start over on the host:** stop, empty `clickhouse/`, start (copies `CBIO_DB_SNAPSHOT` again; OPA groups re-applied at start).
- Snapshots and scratch folders are **never deleted automatically**. Clean up by hand.

---

## Handing off to a maintainer

| Item | Value |
|------|-------|
| `podman run` | [`run.sh`](run.sh); units in [`deploy/`](deploy/) |
| Image | `ghcr.io/c3g/c3g_cbioportal_instance` (private) |
| Trigger | Published Release → `latest` + `<release>` |
| Database | No Postgres |
| Secrets | `C3G_CBIOPORTAL_OIDC_CLIENT_SECRET` → `OIDC_CLIENT_SECRET`; `C3G_CBIOPORTAL_CH_PASSWORD` → `CLICKHOUSE_PASSWORD` |
| Volume | `/home/genome/cbioportal-volume` → `/data` (label `cbioportal`, local/block disk) |
| Shared storage | `<shared>/snapshots` → `/snapshots:ro` on the host; whole `<shared>` on the Build VM — **ASK** the SD4H admins |
| Build VM | Second VM: podman + ghcr.io login, ≥ 20 GB RAM, runs [`deploy/c3g-cbioportal-build.sh`](deploy/c3g-cbioportal-build.sh) on demand (no service, no ports) |
| Auth | Tier 3b: in-app OIDC + OPA `c3g-cbioportal-opa` (`127.0.0.1:8181`) |
| OPA policy | `c3g_cbioportal/` in c3g-opa-policies; bundle URL **ASK** |
| nginx | `proxy_pass http://172.16.8.75:<host_port>` + `location /reports/` → `<reports_host_port>` (8090) |
| Ports | `8080` portal, `8090` PCGR report gatekeeper (checks access itself) |

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
| One VM per app | Build VM + Host VM, same image; DB snapshots handed over on shared storage | Imports (≤ 16 GB RAM, long) never run on the webapp VM; the host only serves |

---

## Repo contents

| File | Purpose |
|------|---------|
| `Containerfile` | cBioPortal 7.1.2 + MongoDB 8.0 + ClickHouse 24.10 + session-service 0.6.4 + logo |
| `entrypoint.sh` | `build` (Build VM) / `start` / `snapshots` / `studies` / `sync-access` / `healthcheck` (Host VM) |
| `deploy/c3g-cbioportal-build.sh` | Exact one-off `podman run ... build` for the Build VM (scratch per build, mounts, memory cap) |
| `reports_server.py` | PCGR report gatekeeper (Python stdlib; access asked from cBioPortal per request) |
| `config/clickhouse-*.xml` | Static ClickHouse configs (values from env) |
| `run.sh` | Exact `podman run` commands (OPA + portal) |
| `deploy/*.service` | systemd user units (portal, OPA) |
| `opa/c3g_cbioportal/` | Policy, tests, placeholder data |
| `.github/workflows/publish-container.yml` | Release workflow (docker build amd64 → ghcr.io; adapted from snv-benchmarking-dashboard) |

Adapted from `<client_project>/6_cbioInstance.sh` (Narval) and [cbioportal-docker-compose](https://github.com/cBioPortal/cbioportal-docker-compose).

---

## Still to verify

1. session-service 0.6.4 on Java 21 + MongoDB 8.0.
2. COmanage login; `groups` claim read and its format.
3. Offline validation (`DumpPortalInfo` + `metaImport.py -p`).
4. Clean ClickHouse after `systemctl --user stop`.
5. Logo shows.
6. Release workflow builds + pushes amd64 to ghcr.io (arm64 dropped).
7. Logout behaviour (CILogon session may persist).
8. OPA: the c3g-opa-policies bundle is built from its repo root, so `c3g_cbioportal/data.json` lands at `data.c3g_cbioportal` (assumed; compare `project_tracking/data.json`: no outer app key). `--bundle <URL>` vs remote-bundle config.
9. `ALTER TABLE cancer_study UPDATE "groups"` works; no derived copy of `groups`.
10. `DELETE /api/cache` refreshes the webapp (else it restarts after each change, ~2–3 min down).
11. `C3G_OPA_DENY` studies hidden everywhere (study list, counts).
12. Reports: cBioPortal 7.1.2 `GET /api/studies/<id>` answers 200 / 403 (or 404) / 401-302 for allowed / not allowed / logged out, with only the session cookie forwarded.
13. Reports: the PCGR flexdb dashboard works inside the CSP `sandbox` (no `allow-same-origin`); if not, relax it in `reports_server.py`.
14. Reports: the 7.1.2 importer + patient view accept the resource files (tab shows, ~9 MB per report).
15. Snapshots: a ClickHouse folder copied with `cp -a` after a clean stop starts on another machine (same image, same `/data` path) with all 63 tables.
16. Snapshots: the copy to and from the SD4H shared storage (`cp -dR --preserve=mode,timestamps`, no ownership) keeps ClickHouse's symlinks (NFS/CephFS), and the Host VM's `genome` user can read files written by the Build VM's `genome` (same uid/gid on both VMs, or a shared group): **ASK** the SD4H admins.
17. Shared storage mounted `:ro` without `:Z`: SELinux on the VMs allows the container to read it (otherwise ask the admins for a matching context, never relabel shared storage).
18. The webapp writes nothing to ClickHouse other than what the host already does (migration, groups), so the host copy stays a faithful snapshot copy.

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
| Build: "OPA gives no group access" (warning) | Add study to `data.json`, wait for bundle; it's hidden until then (no rebuild needed) |
| Host: "CBIO_DB_SNAPSHOT is not set" / "not found" | Unit `-e CBIO_DB_SNAPSHOT=<id>`; shared storage mounted at `/snapshots`; `entrypoint.sh snapshots` |
| Host: "has no READY file" | That build failed or is still running: serve another id |
| Host: "built with cBioPortal X, this image is Y" | Rebuild the snapshot with the host's image tag (or pin the host to the old tag) |
| Host: "no seed data" | The local copy is broken: stop, empty `clickhouse/`, start (copies the snapshot again) |
| Build: "already exists" / "not empty" | New `SNAPSHOT_ID` / new scratch folder (the script makes one per run) |
| Report tab: 401 | Not logged in, or `CBIO_REPORTS_URL` host ≠ portal host (cookie not sent) |
| Report tab: 404 | No access to the study, file missing in `reports/<study_id>/`, or portal down: `logs/reports.log` |
| Report tab blank / refused to frame | `CBIO_PORTAL_ORIGIN` ≠ the portal's address |
| Build: "samples without a report" | File name ≠ `<SAMPLE_ID or PATIENT_ID><CBIO_REPORT_SUFFIX>` |

---

## References

- C3G web-app-template: https://github.com/c3g/web-app-template
- cBioPortal: https://github.com/cBioPortal/cbioportal · https://docs.cbioportal.org
- Cerami E. *et al.* *Cancer Discovery* 2012;2(5):401–404.
- Gao J. *et al.* *Science Signaling* 2013;6(269):pl1.
- de Bruijn I. *et al.* *Cancer Research* 2023;83(23):3861–3867.

License: AGPL-3.0.
