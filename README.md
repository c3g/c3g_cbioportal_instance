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
| Let a person see a project | Add a line to `users.tsv` (or add the project's group to their line) | No. Applied within 5 min (or `sync-access`), effective at their next login |
| Remove a person | Delete their line | No. They can't log in again (an open session lasts until it expires) |
| Change which groups can see a study | Edit `groups:` in the study's `meta_study.txt` **in the pipeline** | Yes: build a new snapshot and switch |
| Give C3G staff access to everything | Every study's `groups:` includes `C3G_ADMINS`; staff carry `C3G_ADMINS` in `users.tsv` | No (for people) |

- **`users.tsv`:** tab-separated, one person per line (`email`, `name`, `groups` separated by `;`), `#` for comments.
  - Group names may only use letters, digits and `_ . : -`, and are matched ignoring case.
  - It holds personal data, so it lives only on the host volume (`/data/access/users.tsv`), **never in git or a snapshot**.
- **Missing file:** nobody can log in (fail closed).
- **Invalid file:** nothing changes, and `sync-access` prints the line that's wrong.
- **The build** refuses a study without a `groups:` line, and warns when `C3G_ADMINS` is missing from it.
- **How it works inside:** `authorization=true`. At start (and every 5 min) the host loads `users.tsv` into cBioPortal's `users` and `authorities` tables in its local database copy. Because each snapshot starts empty, the people list is always re-applied from the host file.
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

### Start the portal (Host VM)

```bash
cp deploy/c3g-cbioportal.service ~/.config/systemd/user/.
systemctl --user enable --now c3g-cbioportal.service
podman logs -f c3g-cbioportal                               # ready at "All services up, serving snapshot <id>"
```

- Before the first start, fill the `<...>` placeholders in the unit: issuer URL, client ID, ports, snapshots path, snapshot id. Then put the people list in `/home/genome/cbioportal-volume/access/users.tsv` ([Who can see what](#who-can-see-what)).
- Startup order: copy the snapshot (if new) → ClickHouse → load `users.tsv` → MongoDB → session-service → webapp → report server.
- It refuses to start without the OIDC settings, or without a snapshot that has `READY` and matches the image's cBioPortal version.
- No `users.tsv` → the portal starts, but **nobody can log in** (fail closed).
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

This checks the file, then swaps it into the `users` / `authorities` tables. Added, removed and changed people are printed, and an invalid line stops the update. The same sync also runs on its own every 5 min. Changes apply at each person's next login.

### Health check, stop, start

```bash
podman healthcheck run c3g-cbioportal                    # every service answers
systemctl --user stop c3g-cbioportal.service             # ordered shutdown, ClickHouse last (up to 5 min)
systemctl --user start c3g-cbioportal.service
```

### SD4H Slurm test (Cardinal; branch `sd4h_test`)

Runs both VM roles one after the other in one Slurm job, with the same image, rootless podman, `deploy/c3g-cbioportal-build.sh` and `run.sh` flags. Only the things a Slurm node forces are different (listed at the top of the script): `127.0.0.1` ports reached by an SSH tunnel, no systemd, host volume on the node's local disk.

- **Login:** the same COmanage OIDC client, with the tunnel's callback `http://localhost:28080/login/oauth2/code/cbio-idp` registered on it. It is on when the issuer, client id and client secret are in `secrets/` (otherwise the job runs without login and says so).
- **Test folder:** `/Path/to/YOUR/test_dir` = any throwaway folder on Cardinal's `/project`, passed to the job as `TEST_DIR`. It holds `shared/` (the VMs' shared storage) and `secrets/`.
- **Secrets (temporary):** `/Path/to/YOUR/test_dir/secrets/` (chmod 700, files 600). The job refuses secrets that group or others can read.

**1. Repo and folders** (Cardinal login node)

```bash
export TEST_DIR=/Path/to/YOUR/test_dir      # also read by the job (step 5)
cd ${TEST_DIR}
git clone -b sd4h_test git@github.com:c3g/c3g_cbioportal_instance.git     # or: git fetch && git switch sd4h_test
T=${TEST_DIR}
mkdir -p ${T}/shared/{studies,reports,manifests,snapshots} && mkdir -p -m 700 ${T}/secrets
```

**2. Image**: built **off Cardinal** and copied there as a file. On Cardinal, `podman build` fails: there's only one user id for your account, so the MongoDB install can't `chown` to its `mongodb` user. There's no ghcr login there either. Loading a finished image works.

*On the Mac* (repo clone, podman machine running): build the latest release for amd64 and save it as a `.tar`.

```bash
cd /Path/to/YOUR/c3g_cbioportal_instance
git fetch --tags
./sd4h_slurm/build-image-archive.sh                     # newest v* release tag; or: ./sd4h_slurm/build-image-archive.sh v2.1.0
# -> image_archives/c3g_cbioportal_instance_<release>_<commit>_amd64.tar (+ .sha256), git-ignored
```

- It builds exactly the release's code (`git archive <tag>` into a temp folder), with `--platform linux/amd64 --format docker`. Uncommitted changes and macOS `Icon` files never get in.
- It stops if the result isn't amd64. It prints the cBioPortal version and whether the HEALTHCHECK is kept.
- Emulated build: allow some time. The `.tar` is a few GB.
- Rebuild only when a new release changes the image: `Containerfile`, `entrypoint.sh`, `reports_server.py`, `config/`, the logo. Changes to the Slurm script or the README need no new image.

*Copy it to Cardinal:*

```bash
ssh <user>@cardinal.sd4h.ca "mkdir -p ${TEST_DIR}/image"      # TEST_DIR as in step 1 (or type the path)
scp image_archives/c3g_cbioportal_instance_<release>_<commit>_amd64.tar{,.sha256} <user>@cardinal.sd4h.ca:/Path/to/YOUR/test_dir/image/
```

- At step 2/5 the job checks the `.sha256`, loads the newest `*_amd64.tar` in `${TEST_DIR}/image/`, and logs its release, commit and architecture. To pick another file, set `IMAGE_ARCHIVE=<file>` at step 5.
- **Other sources, for later:**
  - `IMAGE_SOURCE=build` builds on Cardinal from this clone. It needs a subuid range for your account (ask the SD4H admins).
  - `IMAGE_SOURCE=pull IMAGE=ghcr.io/c3g/c3g_cbioportal_instance:<release>` needs `podman login ghcr.io --authfile ~/.config/containers/auth.json` with a classic token (`read:packages`, authorized for the c3g org).

**3. Secrets.** Each template in `sd4h_slurm/secrets.example/` holds one commented, made-up example. Add the real value on a new line under it; `#` lines are ignored.

```bash
cp c3g_cbioportal_instance/sd4h_slurm/secrets.example/* ${T}/secrets/ && chmod 600 ${T}/secrets/*
nano ${T}/secrets/oidc_client_secret     # COmanage client secret
nano ${T}/secrets/oidc_issuer            # issuer URL
nano ${T}/secrets/oidc_client_id         # client id
nano ${T}/secrets/users.tsv              # your CILogon email <TAB> name <TAB> C3G_ADMINS
```

| File | Holds | Example line (made up) |
|------|-------|------------------------|
| `oidc_client_secret` | COmanage client secret | `cKKG4l-5U8WCUsOjs_bkkNXnlS9p7hUtYlG51ovik...` |
| `oidc_issuer` | issuer URL | `https://idp.example.org/oidc` |
| `oidc_client_id` | client id | `cilogon:/client_id/7855a3979be3004da4ecdfcc6c7f5923` |
| `users.tsv` | who can log in (TAB-separated) | `jane.doe@example.org  Jane Doe  C3G_ADMINS;PROJECT_X` |

**4. Study, reports, manifest**: the Build VM's inputs. Only `shared/` is mounted in the container (read-only), so **copy** files in; don't symlink. A symlink to a folder outside `shared/` is broken inside the container.

```
${T}/shared/
├── studies/<study_folder>/                          4a  the pipeline's cBioPortal study folder
├── reports/<cancer_study_identifier>/*.html         4b  PCGR reports, flat, named after the samples
└── manifests/test.txt                               4c  which study folders go into the snapshot
```

*4a. Study folder.* Copy the whole folder as the pipeline wrote it (`meta_study.txt`, `meta_*`/`data_*`, `case_lists/`).

```bash
cp -r <pipeline_output>/<study_folder> ${T}/shared/studies/
grep -E '^(cancer_study_identifier|groups):' ${T}/shared/studies/<study_folder>/meta_study.txt
#   cancer_study_identifier: <study_id>      letters, digits, _ . - only
#   groups: <PROJECT>;C3G_ADMINS             one or more groups, separated by ;
```

- **I GZ had to add this by hand - to test - CHECK_HERE**
- **No `groups:` line:** the build stops. **No `C3G_ADMINS` in it:** the build warns, and people with only `C3G_ADMINS` won't see the study.
- These lines come from the pipeline. If they're wrong, fix the pipeline and re-run it; don't edit `meta_study.txt` by hand.
- The folder name and `cancer_study_identifier` can differ. The manifest uses the **folder name**, `reports/` uses the **`cancer_study_identifier`**.

*4b. PCGR reports (optional).* One folder per study, named after its `cancer_study_identifier`. Files sit directly in it (no sub-folders) and are named `<SAMPLE_ID>` or `<PATIENT_ID>` + `.pcgr_acmg.grch38.flexdb.html`, matching the study's `data_clinical_sample.txt`.

```bash
SID=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' ${T}/shared/studies/<study_folder>/meta_study.txt | tr -d '[:space:]')
mkdir -p ${T}/shared/reports/${SID}
find <pipeline_output> -name '*.pcgr_acmg.grch38.flexdb.html' -exec cp {} ${T}/shared/reports/${SID}/ \;
ls ${T}/shared/reports/${SID} | head
```

- A report is linked to the sample whose `SAMPLE_ID` (or else `PATIENT_ID`) + suffix matches its file name. The build log lists samples without a report and reports that match no sample.
- File names may only use letters, digits and `_ . -`. Other names, and symlinks, are skipped with a warning.
- No `reports/<study_id>/` folder, or no match at all: the study is imported without report tabs, and the build goes on.
- The study folder itself is never changed: the report links are added in a staging copy inside the build.

*4c. Manifest.* One study **folder name** per line (not a path); `#` lines are comments. It's the full list of studies in the snapshot.

```bash
echo <study_folder> > ${T}/shared/manifests/test.txt
cat ${T}/shared/manifests/test.txt
```

*4d. Check before submitting.* These are the build's first checks, so a typo fails here instead of after the job starts.

```bash
for f in $(grep -vE '^[[:space:]]*(#|$)' ${T}/shared/manifests/test.txt); do
  m=${T}/shared/studies/${f}/meta_study.txt
  [ -s "${m}" ] || { echo "MISSING ${m}"; continue; }
  id=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' "${m}" | tr -d '[:space:]')
  echo "${f}: id=${id} groups=$(sed -n 's/^groups:[[:space:]]*//p' "${m}") reports=$(ls ${T}/shared/reports/${id}/*.pcgr_acmg.grch38.flexdb.html 2>/dev/null | wc -l)"
done
```

Expect one line per study, with an `id`, `groups` that include `C3G_ADMINS`, and the number of reports you copied.

**5. Submit** (from the repo root; build + serve in one job)

```bash
cd ${T}/c3g_cbioportal_instance && mkdir -p job_outs
sbatch sd4h_slurm/c3g-cbioportal-slurm.sh test.txt
# IMAGE_ARCHIVE=${T}/image/<file>.tar sbatch sd4h_slurm/c3g-cbioportal-slurm.sh test.txt   # a given image file (step 2)
# CBIO_DB_SNAPSHOT=<id> sbatch sd4h_slurm/c3g-cbioportal-slurm.sh         # serve / roll back to an existing snapshot
tail -f job_outs/cbio_sd4h_test_<jobid>.o                                # steps 1/5 ... 5/5
```

**6. Open it.** At step 5/5 the log prints the exact SSH tunnel command for your laptop (with the node name). Run it, then open `http://localhost:28080`. Use `localhost`, not `127.0.0.1`: the OIDC callback must match.

**7. Stop cleanly** (ordered shutdown, logs copied to `${T}/shared/test_logs/<jobid>/`)

```bash
scancel --signal=TERM --batch <jobid>        # plain scancel kills it after 30 s
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
| Updates | `--label io.containers.autoupdate=registry`: a published GitHub Release (`latest`) is picked up within ~15 min. Roll back by pinning a release tag (`:v1.0.0`). A release that changes cBioPortal's version also needs a new snapshot, so pin the old tag until the new snapshot is ready |
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
| Host | Its local copy only: schema migration at start, and the `users` / `authorities` tables from `users.tsv` (every 5 min) |
| Webapp | Nothing (users' saved sessions go to MongoDB, not ClickHouse) |

**Adding more studies:** the database is **rebuilt from scratch on every build**. Studies are never added to the running database.

```
manifests/portal.txt                    build                          host
  study_A          ─┐
  study_B           ├──►  empty DB + seed + A + B + C  ──►  snapshots/<new id>/  ──►  CBIO_DB_SNAPSHOT=<new id>, restart
  study_C  (new)   ─┘
```

1. Copy the new study folder to `studies/`, its PCGR reports to `reports/<cancer_study_identifier>/`, with `groups: <PROJECT>;C3G_ADMINS` in its `meta_study.txt` (pipeline). Add the people to `users.tsv` on the host.
2. Add one line to `manifests/portal.txt`. Keep the existing lines.
3. Build → a new snapshot holding all the studies, old and new.
4. Switch the host to the new snapshot and restart. The previous snapshot stays as the rollback.

- **Replace a study:** update its folder, then build. **Remove a study:** delete its line, then build.
- **Why a full rebuild:** each snapshot is exactly its manifest, so it can be rebuilt and nothing drifts. cBioPortal can't add PCGR report links to an existing study anyway.
- **Cost:** every build reloads the seed (~10–15 min), plus each study's import (usually minutes). Long imports usually mean a problem in the pipeline output. On Narval, duplicate gene/sample rows in `data_cna_long.txt` took 68 of 70 minutes.
- **Access:** the study's groups come with the snapshot, from `meta_study.txt`. The people (`users`/`authorities`) are never in a snapshot: the host loads them from `users.tsv` after each switch, so adding a person never needs a rebuild.
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
