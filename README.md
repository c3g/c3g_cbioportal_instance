# c3g_cbioportal_instance
_Last Modified:_ 2026-11-20

**Authors:** Gerardo Zapata

Private [cBioPortal](https://www.cbioportal.org/) 7.1.2 for C3G client studies (GRCh38): one podman image holding the webapp, ClickHouse, MongoDB and session-service.
Login through C3G COmanage (OIDC). Each study's access is decided by **OPA**, per COmanage group.
Each sample's **PCGR report** opens as a tab in the patient view, with the same access.

- URL: https://cbioportal.c3g-app.sd4h.ca
- Image: `ghcr.io/c3g/c3g_cbioportal_instance` (private: `podman login ghcr.io` first)

<br/>

---

<br/>

> ⚠️ **AI-written.** This README and the code in this repo (`entrypoint.sh`, `reports_server.py`, `Containerfile`, OPA policy, `run.sh`, `deploy/`) were written with an AI assistant (Claude, Anthropic). Check it against the code and test it before relying on it, especially access control. The Builder / Hosting split has not been run on the VMs yet.

<br/>

---

<br/>

## How it works

One image, two jobs, on two SD4H VMs. They share one storage folder:

```
/Path/to/YOUR/cBioPortal/                  ← shared SD4H storage (mounted on both VMs)
├── studies/<study_folder>/                INPUT   study folders (pipeline output)
├── reports/<cancer_study_identifier>/     INPUT   PCGR reports (*.pcgr_acmg.grch38.flexdb.html)
├── manifests/portal.txt                   INPUT   one study folder per line = what the portal serves
└── snapshots/<YYYYmmdd-HHMMSS>/           BUILDER OUTPUT   ready-to-serve database (+ reports, logs, READY)
```

### 1. Builder (Build VM): imports, never serves

Imports every study in the manifest into a fresh database and writes it as a **snapshot**:

```bash
SHARED=/Path/to/YOUR/cBioPortal ./deploy/c3g-cbioportal-build.sh portal.txt
# -> /Path/to/YOUR/cBioPortal/snapshots/20261120-143000/
```

### 2. Hosting (webapp VM): serves, never imports

Serves one snapshot. It mounts the snapshots folder read-only, copies the chosen snapshot to its own disk, and serves that copy:

```bash
podman run ... \
  -v /Path/to/YOUR/cBioPortal/HostData:/data:Z \
  -v /Path/to/YOUR/cBioPortal/snapshots:/snapshots:ro \
  -e CBIO_DB_SNAPSHOT=20261120-143000 \
  ghcr.io/c3g/c3g_cbioportal_instance:latest          # full command: deploy/c3g-cbioportal.service
```

- **Add, update or remove a study:** edit the manifest → build → set the new `CBIO_DB_SNAPSHOT` → restart (~2–3 min down).
- **Roll back:** set the previous snapshot id → restart.
- Both VMs must run the **same image tag**. The host refuses a snapshot built with another cBioPortal version.

<br/>

---

<br/>

## Commands

### Build a snapshot (Build VM)

```bash
SHARED=/Path/to/YOUR/cBioPortal \
SCRATCH_ROOT=/Path/to/YOUR/cBioPortal/BuilderScratch \
IMAGE=ghcr.io/c3g/c3g_cbioportal_instance:latest \
  ./deploy/c3g-cbioportal-build.sh portal.txt
```

- Each run starts from an empty database: schema + seed (~10–15 min), then every study in `manifests/portal.txt`. The manifest is the **full** list of studies, not just the new ones.
- ClickHouse runs on the local `SCRATCH_ROOT` disk, never on the shared storage. Needs ~18 GB RAM.
- PCGR reports in `reports/<cancer_study_identifier>/` are linked to their samples (`<SAMPLE_ID or PATIENT_ID>.pcgr_acmg.grch38.flexdb.html`) and copied into the snapshot. The study folder is never changed.
- Success: `snapshots/<id>/` with `READY` written last. Failure: only `<id>.partial/` is left, and the host refuses it.
- Optional: `OPA_URL=http://<opa_host>:8181` warns about studies OPA doesn't list (those would be hidden).
- Snapshots and scratch folders are never deleted automatically.

### Start the portal (Host VM)

```bash
cp deploy/c3g-cbioportal-opa.service deploy/c3g-cbioportal.service ~/.config/systemd/user/.
systemctl --user enable --now c3g-cbioportal-opa.service    # OPA first
systemctl --user enable --now c3g-cbioportal.service
podman logs -f c3g-cbioportal                               # ready at "All services up, serving snapshot <id>"
```

- Before the first start, fill the `<...>` placeholders in the unit: issuer URL, client ID, ports, snapshots path, snapshot id.
- Startup order: copy the snapshot (if new) → ClickHouse → OPA access → MongoDB → session-service → webapp → report server.
- It refuses to start without the OIDC settings, or without a snapshot that has `READY` and matches the image's cBioPortal version.
- OPA down → the portal starts, but **every study is hidden** (fail closed).
- The same command without systemd is in [`run.sh`](run.sh).

### Switch or roll back the snapshot (Host VM)

```bash
# in ~/.config/systemd/user/c3g-cbioportal.service:  -e CBIO_DB_SNAPSHOT=<new or previous id>
systemctl --user daemon-reload && systemctl --user restart c3g-cbioportal.service
```

The previous local copy is kept as `/data/clickhouse.prev/`. MongoDB (users' saved sessions and virtual studies) is not touched.

### List snapshots

```bash
podman exec c3g-cbioportal /app/entrypoint.sh snapshots
```

Shows each snapshot's id, READY, cBioPortal version, size and studies. `*` marks the one being served.

### List studies and who can see them

```bash
podman exec c3g-cbioportal /app/entrypoint.sh studies
```

`groups` = the COmanage groups allowed to see the study. `C3G_OPA_DENY` = hidden from everyone.

### Apply an access change now

```bash
podman exec c3g-cbioportal /app/entrypoint.sh sync-access
```

Re-reads OPA and writes each study's groups. This also runs on its own every 5 min. Access lives in `c3g_cbioportal/data.json` in c3g-opa-policies, so granting or revoking access needs no rebuild:

```json
{ "admin_groups": ["c3g-cbioportal-admins"],
  "study_groups": { "<cancer_study_identifier>": ["c3g-cbioportal-<group>"] } }
```

### Health check, stop, start

```bash
podman healthcheck run c3g-cbioportal                    # every service answers
systemctl --user stop c3g-cbioportal.service             # ordered shutdown, ClickHouse last (up to 5 min)
systemctl --user start c3g-cbioportal.service
```

### Local test (laptop, no login, never on the VMs)

```bash
podman build -t c3g_cbioportal_instance:dev -f Containerfile .
mkdir -p shared/{studies,reports,manifests,snapshots} scratch host     # study + reports + manifests/test.txt
SHARED=./shared SCRATCH_ROOT=./scratch IMAGE=c3g_cbioportal_instance:dev MEMORY=12g \
  CBIO_REPORTS_URL=http://localhost:8090/reports ./deploy/c3g-cbioportal-build.sh test.txt
podman run -d --name cbio-test --stop-timeout=300 -e CBIO_AUTH=false -e CBIO_DB_SNAPSHOT=<id> \
  -e CBIO_REPORTS_URL=http://localhost:8090/reports -e CBIO_PORTAL_ORIGIN=http://localhost:8080 \
  -v ./host:/data:Z -v ./shared/snapshots:/snapshots:ro \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8090:8090 c3g_cbioportal_instance:dev
```

Every other setting (`-e VAR=...`) is listed with its default at the top of [`entrypoint.sh`](entrypoint.sh) (`## CHANGE HERE ##`).

<br/>

---

<br/>

## For web app maintainers

From the C3G [web-app-template](https://github.com/c3g/web-app-template/blob/main/for-maintainers.md), what this app needs. Items marked **ASK** are still open.

| Item | This app |
|------|----------|
| Login | `bastion_ssh <you>@prod-appserver-podman-1` → `sudo machinectl shell genome@` (not `sudo -s`) |
| Units | [`deploy/c3g-cbioportal.service`](deploy/c3g-cbioportal.service) + [`deploy/c3g-cbioportal-opa.service`](deploy/c3g-cbioportal-opa.service), installed to `~/.config/systemd/user/` |
| Updates | `--label io.containers.autoupdate=registry`: a published GitHub Release (`latest`) is picked up within ~15 min. Roll back by pinning a release tag (`:v1.0.0`). A release that changes cBioPortal's version also needs a new snapshot, so pin the old tag until the new snapshot is ready |
| Volume | "Reserve space" in the template, `APPNAME=cbioportal` (XFS label ≤ 12 characters) → `/home/genome/cbioportal-volume:/data:Z`. Must be local/block disk (ClickHouse runs on it) |
| Shared storage | `snapshots/` mounted read-only on the webapp VM; the whole folder read-write on the Build VM. Storage type, mount point, same `genome` uid/gid on both VMs: **ASK** SD4H admins. Mounted without `:Z` (never relabel shared storage) |
| Secrets | Prefixed podman secrets, passed as env vars:<br/>`printf '%s' '<value>' \| podman secret create C3G_CBIOPORTAL_OIDC_CLIENT_SECRET -`<br/>`python3 -c 'import secrets; print(secrets.token_hex(16), end="")' \| podman secret create C3G_CBIOPORTAL_CH_PASSWORD -`<br/>To change one: `podman secret rm`, create again, restart the unit |
| Database | None on the shared Postgres: ClickHouse + MongoDB run inside the container |
| OIDC client | From the COmanage admins. Redirect URI `https://cbioportal.c3g-app.sd4h.ca/login/oauth2/code/cbio-idp`, `authorization_code` / `client_secret_basic`, scopes `openid profile email org.cilogon.userinfo`, claims `email name groups`. Confirm the exact `groups` string format |
| Auth tier | cBioPortal's own OIDC login + the app's own OPA (closest to 3b). **No oauth2-proxy**: nginx goes straight to the app |
| OPA | Own container `c3g-cbioportal-opa`, pinned `openpolicyagent/opa` version, `-p 127.0.0.1:8181:8181`, app reaches it at `10.0.2.2:8181`. Policy `c3g_cbioportal/` in c3g-opa-policies, `--bundle <bundle_url>`: **ASK** |
| Ports | `8080` portal, `8090` PCGR report server: **ASK** which host ports |
| nginx | Template server block (`*.c3g-app.sd4h.ca` certificate), `server_name cbioportal.c3g-app.sd4h.ca;`, `proxy_pass http://172.16.8.75:<portal_port>;` plus the block below (same host name, so the login cookie reaches the report server) |
| Stop timeout | `--stop-timeout=300` / `TimeoutStopSec=330`: ClickHouse needs time to stop cleanly |
| RAM | Webapp VM ≥ 16 GB; Build VM ≥ 20 GB |

```nginx
location /reports/ {
    proxy_pass http://172.16.8.75:<reports_port>;   # 8090
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

Departures from the template that need maintainer sign-off:
- ClickHouse and MongoDB run inside the container instead of the shared Postgres.
- Login is cBioPortal's own OIDC; there is no oauth2-proxy or Flask OPA library.
- A second VM (the Build VM) does the imports.
- The stop timeout is 300 s.

### The ClickHouse database

**What it is:** cBioPortal 7 keeps all study data in one ClickHouse database, `cbioportal` (63 tables).
- The webapp only reads it.
- Most of it is **seed** data loaded with every build: genes, gene sets, cancer types.
- Each study adds its own rows: samples, mutations, copy number, structural variants, case lists, PCGR report links.
- `*_derived` tables are precomputed for the study view and rebuilt after each import.

**On disk:** a ClickHouse database is a plain folder, the same in the snapshot and on the host:

```
clickhouse/
├── metadata/cbioportal/*.sql      table definitions ("ATTACH TABLE mutation ...")
├── store/<abc>/<uuid>/            one folder per table
│   └── all_1_1_0/                 one "part" per insert: one compressed .bin file per column
└── status, uuid, tmp/, ...        server bookkeeping
```

- Size: ~51 MB for the seed plus one WES study of 86 samples (Narval test). It grows with each study.
- The internal links are absolute (`/data/clickhouse/store/...`), so the folder only works at `/data/clickhouse` (`CBIO_DATA_DIR` must be the same on both VMs).
- Only one ClickHouse server may use a folder at a time. That's why the host serves a **copy** of the snapshot, and why ClickHouse never runs on the shared storage.

**Who writes it:**

| Who | Writes |
|-----|--------|
| Builder | Everything: schema, seed, every study in the manifest, derived tables |
| Host | Its local copy only: schema migration at start, and each study's `groups` from OPA (every 5 min) |
| Webapp | Nothing (users' saved sessions go to MongoDB, not ClickHouse) |

**Adding more studies:** the database is **rebuilt from scratch on every build**. Studies are never added to the running database.

```
manifests/portal.txt                    build                          host
  study_A          ─┐
  study_B           ├──►  empty DB + seed + A + B + C  ──►  snapshots/<new id>/  ──►  CBIO_DB_SNAPSHOT=<new id>, restart
  study_C  (new)   ─┘
```

1. Copy the new study folder to `studies/`, its PCGR reports to `reports/<cancer_study_identifier>/`, and add its access to `data.json` in c3g-opa-policies.
2. Add one line to `manifests/portal.txt`. Keep the existing lines.
3. Build → a new snapshot holding all the studies, old and new.
4. Switch the host to the new snapshot and restart. The previous snapshot stays as the rollback.

- **Replace a study:** update its folder, then build. **Remove a study:** delete its line, then build.
- **Why a full rebuild:** each snapshot is exactly its manifest, so it can be rebuilt and nothing drifts. cBioPortal can't add PCGR report links to an existing study anyway.
- **Cost:** every build reloads the seed (~10–15 min), plus each study's import (usually minutes). Long imports usually mean a problem in the pipeline output. On Narval, duplicate gene/sample rows in `data_cna_long.txt` took 68 of 70 minutes.
- **Access isn't decided by the build:** the host replaces every study's groups with OPA's answer before the webapp starts, and again every 5 min. A study OPA doesn't list is hidden, and access changes never need a rebuild.
- Each snapshot is a full copy, so delete old ones by hand once they're no longer needed for a rollback.

<br/>

---

<br/>

## References

- C3G web-app-template: https://github.com/c3g/web-app-template
- cBioPortal: https://github.com/cBioPortal/cbioportal · https://docs.cbioportal.org
- Cerami E. *et al.* *Cancer Discovery* 2012;2(5):401–404.
- Gao J. *et al.* *Science Signaling* 2013;6(269):pl1.
- de Bruijn I. *et al.* *Cancer Research* 2023;83(23):3861–3867.

License: AGPL-3.0.
