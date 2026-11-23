# c3g_cbioportal_instance
_Last Modified:_ 2026-11-23

**Authors:** Gerardo Zapata

Private [cBioPortal](https://www.cbioportal.org/) 7.1.2 for C3G client studies (GRCh38): one podman image holding the webapp, ClickHouse, MongoDB and session-service.
Login through C3G COmanage (OIDC). **cBioPortal itself** decides which person sees which study: a list of allowed people on the host, and groups on each study ([Who can see what](#who-can-see-what)).
Each sample's **PCGR report** opens as a tab in the patient view, with the same access.

- URL: https://cbioportal.c3g-app.sd4h.ca
- Image: `ghcr.io/c3g/c3g_cbioportal_instance` (private: `podman login ghcr.io` first)

<br/>

---

<br/>

> ⚠️ **AI-written.** This README and the code in this repo (`entrypoint.sh`, `reports_server.py`, `Containerfile`, `run.sh`, `deploy/`, the dormant OPA policy) were written with an AI assistant (Claude, Anthropic). Check it against the code and test it before relying on it, especially access control. The Builder / Hosting split has not been run on the VMs yet.

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
├── snapshots/<YYYYmmdd-HHMMSS>/           BUILDER OUTPUT   ready-to-serve database (+ reports, logs, READY)
└── snapshots/CURRENT                      PROMOTE          the snapshot id the host should serve
```

### 1. Builder (Build VM): imports, never serves

Imports every study in the manifest into a fresh database and writes it as a **snapshot**:

```bash
SHARED=/Path/to/YOUR/cBioPortal ./deploy/c3g-cbioportal-build.sh portal.txt
# -> /Path/to/YOUR/cBioPortal/snapshots/20261120-143000/
```

### 2. Hosting (webapp VM): serves, never imports

Serves the snapshot named in `snapshots/CURRENT`. It mounts the snapshots folder read-only, copies that snapshot to its own disk, and serves the copy:

```bash
podman run ... \
  -v /Path/to/YOUR/cBioPortal/HostData:/data:Z \
  -v /Path/to/YOUR/cBioPortal/snapshots:/snapshots:ro \
  -e CBIO_DB_SNAPSHOT=current -e TZ=America/Toronto -e CBIO_SYNC_TIMES="06:00 18:00" \
  ghcr.io/c3g/c3g_cbioportal_instance:latest          # full command: deploy/c3g-cbioportal.service
```

- **Add, update or remove a study:** edit the manifest → build → **promote** (moves `CURRENT`, after showing what changes and asking). The host switches at its next sync (**06:00 or 18:00**), **without a restart**, or right away with `sync-now`.
- **During a switch:** the new snapshot is copied while the old one still serves; then only ClickHouse restarts (~10–20 s of page errors). Logins, the webapp and saved sessions stay up. If the new database doesn't come up, the old one is put back.
- **Roll back:** promote the previous snapshot id.
- **A snapshot that doesn't come up** (at a switch or at start) is put aside as `/data/clickhouse.failed`, the previous copy keeps serving, and that id is not tried again. Build a new snapshot and promote it.
- Both VMs must run the **same image tag**. The host and `promote` refuse a snapshot built with another cBioPortal version.

<br/>

---

<br/>

## Step by step

`S=/Path/to/YOUR/cBioPortal` = the shared storage (layout in [How it works](#how-it-works)). Commands run from the repo root.

### For updating: add, update or remove a study (Build VM)

**1. Study folder.** Copy the pipeline's cBioPortal study folder as it is (no symlinks: only `studies/`, `reports/`, `manifests/` are mounted).

```bash
S=/Path/to/YOUR/cBioPortal
cp -r <pipeline_output>/<study_folder> ${S}/studies/
grep -E '^(cancer_study_identifier|groups):' ${S}/studies/<study_folder>/meta_study.txt
#   cancer_study_identifier: <study_id>
#   groups: <PROJECT>;C3G_ADMINS          set by the pipeline, never by hand
```

**2. PCGR reports (optional).** One flat folder per study, named after its `cancer_study_identifier`.

```bash
SID=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' ${S}/studies/<study_folder>/meta_study.txt | tr -d '[:space:]')
mkdir -p ${S}/reports/${SID}
find <pipeline_output> -name '*.pcgr_acmg.grch38.flexdb.html' -exec cp {} ${S}/reports/${SID}/ \;
```

**3. Manifest.** The **full** list of study folders the portal serves, one per line.

```bash
echo <study_folder> >> ${S}/manifests/portal.txt
cat ${S}/manifests/portal.txt
```

- Update a study: replace its folder. Remove one: delete its line.

**4. Check before building** (a typo fails here, not after a long build).

```bash
for f in $(grep -vE '^[[:space:]]*(#|$)' ${S}/manifests/portal.txt); do
  m=${S}/studies/${f}/meta_study.txt
  [ -s "${m}" ] || { echo "MISSING ${m}"; continue; }
  id=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' "${m}" | tr -d '[:space:]')
  echo "${f}: id=${id} groups=$(sed -n 's/^groups:[[:space:]]*//p' "${m}") reports=$(ls ${S}/reports/${id}/*.html 2>/dev/null | wc -l)"
done
```

**5. Build** a new snapshot (full rebuild; ClickHouse on local scratch).

```bash
SHARED=${S} SCRATCH_ROOT=/Path/to/YOUR/BuilderScratch ./deploy/c3g-cbioportal-build.sh portal.txt
# -> Snapshot ready: .../snapshots/<id>
```

**6. Promote** it: shows `ADDED` / `REMOVED` / `groups` changes against `CURRENT`, asks, writes `CURRENT`.

```bash
SHARED=${S} ./deploy/c3g-cbioportal-promote.sh <id>
```

**7. Live.** The host switches at **06:00 or 18:00**, without a restart. To switch now, on the host: `sync-now` (For hosting, step 5). Roll back: promote the previous id.

**8. People.** Give the project's group to the people who should see it, in `users.tsv` on the host (For hosting, step 1).

### For hosting: run the portal (webapp VM)

**1. Volume and people.** Local disk, mounted as `/data`. `users.tsv` = who can log in ([Who can see what](#who-can-see-what)).

```bash
VOL=/Path/to/YOUR/HostData
mkdir -p -m 700 ${VOL}/access
nano ${VOL}/access/users.tsv          # email <TAB> name <TAB> <PROJECT>;C3G_ADMINS
chmod 600 ${VOL}/access/users.tsv
```

**2. Secrets and image login.**

```bash
printf '%s' '<oidc_client_secret>' | podman secret create C3G_CBIOPORTAL_OIDC_CLIENT_SECRET -
python3 -c 'import secrets; print(secrets.token_hex(16), end="")' | podman secret create C3G_CBIOPORTAL_CH_PASSWORD -
podman login ghcr.io                  # classic token with read:packages, authorized for the c3g org
```

**3. Unit.** Fill the `<...>` placeholders: issuer URL, client ID, snapshots path, host ports. Keep `CBIO_DB_SNAPSHOT=current`.

```bash
cp deploy/c3g-cbioportal.service ~/.config/systemd/user/
nano ~/.config/systemd/user/c3g-cbioportal.service
```

- `snapshots/CURRENT` must exist before the first start: do For updating steps 1–6 once.

**4. Start.**

```bash
systemctl --user daemon-reload && systemctl --user enable --now c3g-cbioportal.service
podman logs -f c3g-cbioportal                                # ready at "All services up, serving snapshot <id>"
podman exec c3g-cbioportal /app/entrypoint.sh snapshots      # CURRENT, served, next sync
```

**5. Day to day** (no restarts needed).

```bash
podman exec c3g-cbioportal /app/entrypoint.sh sync-now       # take a promoted snapshot now (else 06:00 / 18:00)
podman exec c3g-cbioportal /app/entrypoint.sh sync-access    # apply a users.tsv change now (always after removing someone)
podman exec c3g-cbioportal /app/entrypoint.sh studies        # studies + their groups
podman exec c3g-cbioportal /app/entrypoint.sh users          # people + their groups
```

**6. Stop cleanly** (ordered shutdown, ClickHouse last).

```bash
systemctl --user stop c3g-cbioportal.service
```

<br/>

---

<br/>

## Who can see what

Login stays **OIDC through C3G COmanage**: COmanage proves who the person is (their email). After that, **cBioPortal's own authorization** decides what they see. No COmanage groups are needed.

```
STUDY side   meta_study.txt (pipeline output, built into the snapshot)
             groups: PROJECT_X;C3G_ADMINS

PEOPLE side  /Path/to/YOUR/cBioPortal/HostData/access/users.tsv   (host only)
             email               name          groups
             jane.doe@uni.ca     Jane Doe      PROJECT_X
             admin@mcgill.ca     C3G Admin     C3G_ADMINS

At login:    email not in users.tsv            → login refused
             email listed                      → sees every study that shares one of their groups
```

| To... | Do | Rebuild? |
|-------|----|----------|
| Let a person see a project | Add a line to `users.tsv` (or add the project's group to their line) | No. Applied at 06:00 / 18:00 (or now with `sync-access`), effective at their next login |
| Remove a person | Delete their line, then `sync-access` (otherwise it waits for 06:00 / 18:00) | No. They can't log in again (an open session lasts until it expires) |
| Change which groups can see a study | Edit `groups:` in the study's `meta_study.txt` **in the pipeline** | Yes: build a new snapshot and switch |
| Give C3G staff access to everything | Every study's `groups:` includes `C3G_ADMINS`; staff carry `C3G_ADMINS` in `users.tsv` | No (for people) |

- **`users.tsv`:** tab-separated, one person per line (`email`, `name`, `groups` separated by `;`), `#` for comments.
  - Group names may only use letters, digits and `_ . : -`, and are matched ignoring case.
  - It holds personal data, so it lives only on the host volume (`/data/access/users.tsv`), **never in git or a snapshot**.
- **Missing file:** nobody can log in (fail closed).
- **Invalid file:** nothing changes, and `sync-access` prints the line that's wrong.
- **The build** refuses a study without a `groups:` line, and warns when `C3G_ADMINS` is missing from it.
- **How it works inside:** `authorization=true`. At start, at each sync (06:00 and 18:00) and after every snapshot switch, the host loads `users.tsv` into cBioPortal's `users` and `authorities` tables in its local database copy. Because each snapshot starts empty, the people list is always re-applied from the host file.
- cBioPortal also accepts the authority `ALL` (sees every study) as an alternative to `C3G_ADMINS`.
- **Future: OPA.** The OPA setup (COmanage groups + the app's own OPA container + c3g-opa-policies) is still in the code and dormant: `CBIO_AUTHZ=opa`, `opa/`, `deploy/c3g-cbioportal-opa.service`. It isn't deployed for now.

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
- Each study's `meta_study.txt` must have a `groups:` line (set by the pipeline). The build stops on a study without one and warns when `C3G_ADMINS` is missing.
- Snapshots and scratch folders are never deleted automatically.
- A new snapshot is **not** live until it is promoted (next section). `PROMOTE=true ./deploy/c3g-cbioportal-build.sh portal.txt` runs the promote right after a good build.

### Put a snapshot live: promote (Build VM)

```bash
SHARED=/Path/to/YOUR/cBioPortal ./deploy/c3g-cbioportal-promote.sh 20261120-143000
```

- Checks the snapshot (READY, same cBioPortal version), then shows each study against the current `CURRENT`: `ADDED`, `REMOVED`, `groups` changed (old → new), `rebuilt`, `same`, with the number of PCGR reports. It warns when `C3G_ADMINS` is missing from a study's groups.
- Asks `y/N`. If a study would **disappear** (a line left out of the manifest?), you have to type `yes`.
- Writes `snapshots/CURRENT` in one step and adds a line to `snapshots/promote.log` (date, old → new id, who).
- `--yes` skips the question (scripts); it refuses when a study would be removed unless `CBIO_ALLOW_REMOVE=true`.
- **Roll back:** promote the previous id the same way.
- It runs on the Build VM because only that VM can write to `snapshots/`.

### Start the portal (Host VM)

```bash
cp deploy/c3g-cbioportal.service ~/.config/systemd/user/.
systemctl --user enable --now c3g-cbioportal.service
podman logs -f c3g-cbioportal                               # ready at "All services up, serving snapshot <id>"
```

- Before the first start, fill the `<...>` placeholders in the unit: issuer URL, client ID, ports, snapshots path. Promote a first snapshot on the Build VM (so `snapshots/CURRENT` exists). Then put the people list in `/home/genome/cbioportal-volume/access/users.tsv` ([Who can see what](#who-can-see-what)).
- Startup order: copy the snapshot (if new) → ClickHouse → load `users.tsv` → MongoDB → session-service → webapp → report server. Then it waits for the next sync time.
- It refuses to start without the OIDC settings. If `CURRENT` is missing or not usable (no `READY`, other cBioPortal version), it keeps serving its local copy and warns; it only refuses when it has no local copy yet.
- `CBIO_DB_SNAPSHOT=<id>` instead of `current` **pins** the host to that snapshot: it never follows `CURRENT` (for debugging).
- No `users.tsv` → the portal starts, but **nobody can log in** (fail closed).
- The same command without systemd is in [`run.sh`](run.sh).

### Switch to the promoted snapshot now (Host VM)

```bash
podman exec c3g-cbioportal /app/entrypoint.sh sync-now
```

- Runs the scheduled sync right away instead of waiting for 06:00 / 18:00: switch to `CURRENT` if it changed, reload `users.tsv`, clear cBioPortal's cache. Prints the result.
- No restart: the previous local copy is kept as `/data/clickhouse.prev/`. MongoDB (users' saved sessions and virtual studies) is not touched.
- Every sync is logged in `/data/logs/sync.log`, every switch in `/data/logs/snapshot_switch.log`.
- Times: `CBIO_SYNC_TIMES` (default `06:00 18:00`) in the container's time zone (`TZ=America/Toronto` in the unit).

### List snapshots

```bash
podman exec c3g-cbioportal /app/entrypoint.sh snapshots
```

Shows `CURRENT`, the snapshot served here, the last and next sync, then each snapshot's id, READY, cBioPortal version, size and studies. `*` marks the one being served, `>` the one in `CURRENT`.

### List studies and who can see them

```bash
podman exec c3g-cbioportal /app/entrypoint.sh studies
```

`groups` = the study's groups, from its `meta_study.txt`.

### List people who can log in

```bash
podman exec c3g-cbioportal /app/entrypoint.sh users
```

Shows each person's email, name and groups, as loaded from `users.tsv`.

### Apply a `users.tsv` change now

```bash
nano /home/genome/cbioportal-volume/access/users.tsv              # email <TAB> name <TAB> group1;group2
podman exec c3g-cbioportal /app/entrypoint.sh sync-access
```

This checks the file, then swaps it into the `users` / `authorities` tables. Added, removed and changed people are printed, and an invalid line stops the update. The same sync also runs on its own at 06:00 and 18:00, so **run `sync-access` when removing someone**. Changes apply at each person's next login.

### Health check, stop, start

```bash
podman healthcheck run c3g-cbioportal                    # every service answers
systemctl --user stop c3g-cbioportal.service             # ordered shutdown, ClickHouse last (up to 5 min)
systemctl --user start c3g-cbioportal.service
```

### Local test (laptop, no login, never on the VMs)

```bash
podman build -t c3g_cbioportal_instance:dev -f Containerfile .
mkdir -p shared/{studies,reports,manifests,snapshots} scratch host     # study (meta_study.txt with groups:) + reports + manifests/test.txt
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
| Units | [`deploy/c3g-cbioportal.service`](deploy/c3g-cbioportal.service), installed to `~/.config/systemd/user/` (`deploy/c3g-cbioportal-opa.service` is for the future OPA mode, not deployed now) |
| Updates | `--label io.containers.autoupdate=registry`: a published GitHub Release (`latest`) is picked up within ~15 min. Roll back by pinning a release tag (`:v1.0.0`). A release that changes cBioPortal's version also needs a new snapshot, so pin the old tag until the new snapshot is ready. A unit from before the promote / fixed-time sync (pinned `CBIO_DB_SNAPSHOT=<id>`, `CBIO_SYNC_SECS`) keeps working with a newer image: it stays pinned and warns |
| Volume | "Reserve space" in the template, `APPNAME=cbioportal` (XFS label ≤ 12 characters) → `/home/genome/cbioportal-volume:/data:Z`. Must be local/block disk (ClickHouse runs on it). Holds `access/users.tsv` (personal data: who can log in) |
| Shared storage | `snapshots/` mounted read-only on the webapp VM; the whole folder read-write on the Build VM. Storage type, mount point, same `genome` uid/gid on both VMs: **ASK** SD4H admins. Mounted without `:Z` (never relabel shared storage) |
| Secrets | Prefixed podman secrets, passed as env vars:<br/>`printf '%s' '<value>' \| podman secret create C3G_CBIOPORTAL_OIDC_CLIENT_SECRET -`<br/>`python3 -c 'import secrets; print(secrets.token_hex(16), end="")' \| podman secret create C3G_CBIOPORTAL_CH_PASSWORD -`<br/>To change one: `podman secret rm`, create again, restart the unit |
| Database | None on the shared Postgres: ClickHouse + MongoDB run inside the container |
| OIDC client | From the COmanage admins. Redirect URI `https://cbioportal.c3g-app.sd4h.ca/login/oauth2/code/cbio-idp`, `authorization_code` / `client_secret_basic`, scopes `openid profile email org.cilogon.userinfo`, claims `email name` (the **email** is what `users.tsv` is matched on; no groups claim needed) |
| Auth tier | cBioPortal's own OIDC login + cBioPortal's own per-user authorization (`users.tsv`). **No oauth2-proxy, no OPA container for now**: nginx goes straight to the app |
| OPA (future) | When COmanage groups exist: own container `c3g-cbioportal-opa`, pinned `openpolicyagent/opa`, `-p 127.0.0.1:8181:8181`, policy `c3g_cbioportal/` in c3g-opa-policies, `CBIO_AUTHZ=opa` |
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
- Login is cBioPortal's own OIDC, and access is cBioPortal's own authorization; there is no oauth2-proxy, OPA or Flask OPA library for now.
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
| Host | Its local copy only: schema migration at start and after a switch, and the `users` / `authorities` tables from `users.tsv` (at each sync) |
| Webapp | Nothing (users' saved sessions go to MongoDB, not ClickHouse) |

**Adding more studies:** the database is **rebuilt from scratch on every build**. Studies are never added to the running database.

```
manifests/portal.txt                    build                          host
  study_A          ─┐
  study_B           ├──►  empty DB + seed + A + B + C  ──►  snapshots/<new id>/  ──►  promote (CURRENT) ──► switch at 06:00 / 18:00
  study_C  (new)   ─┘
```

1. Copy the new study folder to `studies/`, its PCGR reports to `reports/<cancer_study_identifier>/`, with `groups: <PROJECT>;C3G_ADMINS` in its `meta_study.txt` (pipeline). Add the people to `users.tsv` on the host.
2. Add one line to `manifests/portal.txt`. Keep the existing lines.
3. Build → a new snapshot holding all the studies, old and new.
4. Promote it (`deploy/c3g-cbioportal-promote.sh <new id>`). The host switches at 06:00 or 18:00 (or `sync-now`), without a restart. The previous snapshot stays as the rollback.

- **Replace a study:** update its folder, then build. **Remove a study:** delete its line, then build.
- **Why a full rebuild:** each snapshot is exactly its manifest, so it can be rebuilt and nothing drifts. cBioPortal can't add PCGR report links to an existing study anyway.
- **Cost:** every build reloads the seed (~10–15 min), plus each study's import (usually minutes). Long imports usually mean a problem in the pipeline output. On Narval, duplicate gene/sample rows in `data_cna_long.txt` took 68 of 70 minutes.
- **Access:** the study's groups come with the snapshot, from `meta_study.txt`. The people (`users`/`authorities`) are never in a snapshot: the host loads them from `users.tsv` after each switch, so adding a person never needs a rebuild.
- **Why promote is a separate step:** a build that *runs* fine isn't always *right* (a study left out of the manifest, a wrong `groups:` line). Promote shows the difference and asks before anything goes live.
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
