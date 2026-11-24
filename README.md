# c3g_cbioportal_instance
_Last Modified:_ 2026-11-24

**Authors:** Gerardo Zapata

Private [cBioPortal](https://www.cbioportal.org/) 7.1.2 for C3G client studies (GRCh38): one podman image holding the webapp, ClickHouse, MongoDB and session-service.
Login through C3G COmanage (OIDC/CILogon). The app's own **OPA** decides which COmanage group sees which study; a person's groups come from their login token ([Who can see what](#who-can-see-what)).
Each sample's **PCGR report** opens as a tab in the patient view, with the same access.

- URL: https://cbioportal.c3g-app.sd4h.ca
- Image: `ghcr.io/c3g/c3g_cbioportal_instance` (private: `podman login ghcr.io` first)

<br/>

---

<br/>

> ⚠️ **AI-written.** This README and the code in this repo (`entrypoint.sh`, `reports_server.py`, `Containerfile`, `run.sh`, `deploy/`, the OPA policy) were written with an AI assistant (Claude, Anthropic). Check it against the code and test it before relying on it, especially access control. The Builder / Hosting split has not been run on the VMs yet, and OPA mode has not been run end to end yet (first real test: SD4H Slurm test).

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

Login is **OIDC through C3G COmanage / CILogon**. COmanage proves who the person is, and its token carries their **groups** (claim `groups`). The app's own **OPA** says which groups may see which study. A person sees a study when one of their token groups is one of that study's groups.

```
STUDY side   c3g-opa-policies  c3g_cbioportal/data.json  (OPA bundle, private repo)
             {"admin_groups": ["<C3G admins group>"],
              "study_groups": {"<study_id>": ["<project group>", ...]}}

PEOPLE side  COmanage: membership of the project's group  -> 'groups' claim in the login token

At sync:     OPA's study -> groups table is written into the host's DB copy (cancer_study.groups)
At login:    the token's groups are compared with each study's groups (ignoring case)
```

| To... | Do | Rebuild? |
|-------|----|----------|
| Let a person see a project | Add them to the project's COmanage group | No. Effective at their next login |
| Remove a person | Remove them from the COmanage group | No. Their open session keeps its groups until it expires |
| Let a group see a study / stop it | Edit the study's line in `c3g_cbioportal/data.json` (c3g-opa-policies) | No. Applied within 5 min, or now with `sync-access` |
| Give C3G staff access to everything | Put their COmanage group in `admin_groups` | No. Admins see every study OPA **lists** |

- **Fail closed.** A study OPA doesn't list gets the group `C3G_OPA_DENY`, so nobody sees it. If OPA doesn't answer (3 tries, 10 s apart), **every** study gets it until OPA is back. Never create a COmanage group called `C3G_OPA_DENY`.
- **When it is applied:** at host start (before the webapp), every `CBIO_SYNC_SECS` (5 min) and on `sync-access`. Then cBioPortal's cache is cleared. (`main` re-applies it at its fixed sync times, 06:00 and 18:00, and after each snapshot switch instead.)
- **Group strings** must match the token exactly as COmanage sends them (full COmanage name or short name: check one real token). They may not contain `;`, quotes or backslashes.
- **`meta_study.txt` `groups:`** is replaced on the host. The image built from this branch's code doesn't need it at build time. An older image (v2.1.0) still refuses a study without it.
- **The policy:** a copy for development is in [`opa/c3g_cbioportal/`](opa/c3g_cbioportal/); the real one lives in c3g-opa-policies. Test it with `opa test opa/ -v` (from the repo root).
- **How it works inside:** cBioPortal reads the user's groups from the token (`spring.security.oauth2.client.jwt-roles-path=groups`, `filter_groups_by_appname=false`). `entrypoint.sh sync_opa` asks OPA `POST /v1/data/c3g_cbioportal/authz/study_access` and writes the answer into `cancer_study.groups`.
- **Users-file mode (off, kept).** cBioPortal's own authorization (`CBIO_AUTHZ=cbioportal`: `/data/access/users.tsv` + `meta_study.txt` groups, `authorization=true`) is still in the code but not used.

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
- Access isn't decided at build time: OPA decides on the host. With `OPA_URL=http://<opa_host>:8181` the build warns about studies OPA doesn't list (those would be hidden).
- Snapshots and scratch folders are never deleted automatically.

### Start the portal (Host VM)

```bash
cp deploy/c3g-cbioportal-opa.service deploy/c3g-cbioportal.service ~/.config/systemd/user/.
systemctl --user enable --now c3g-cbioportal-opa.service c3g-cbioportal.service
podman logs -f c3g-cbioportal                               # ready at "All services up, serving snapshot <id>"
```

- Before the first start, fill the `<...>` placeholders in the units: bundle URL (**ASK**, not ready yet), issuer URL, client ID, ports, snapshots path, snapshot id. Start OPA first ([Who can see what](#who-can-see-what)).
- Startup order: copy the snapshot (if new) → ClickHouse → OPA's groups → MongoDB → session-service → webapp → report server.
- It refuses to start without the OIDC settings, or without a snapshot that has `READY` and matches the image's cBioPortal version.
- OPA not answering → the portal starts, but **every study is hidden** (fail closed) until a sync reaches OPA.
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

`groups` = the groups that can see the study, as last written from OPA. `C3G_OPA_DENY` = hidden (OPA doesn't list it, or OPA was down).

### Apply an OPA policy change now

```bash
curl -s -X POST http://127.0.0.1:8181/v1/data/c3g_cbioportal/authz/study_access   # what OPA allows now (on the VM)
podman exec c3g-cbioportal /app/entrypoint.sh sync-access
```

This asks OPA, prints each study whose groups change (`old -> new`), writes them, and clears cBioPortal's cache. The same sync runs on its own every 5 min.

### Health check, stop, start

```bash
podman healthcheck run c3g-cbioportal                    # every service answers
systemctl --user stop c3g-cbioportal.service             # ordered shutdown, ClickHouse last (up to 5 min)
systemctl --user start c3g-cbioportal.service
```

### SD4H Slurm test (Cardinal; branch `sd4h_test`)

Runs both VM roles one after the other in one Slurm job, with the same image, rootless podman, `deploy/c3g-cbioportal-build.sh` and `run.sh` flags. Only the things a Slurm node forces are different (listed at the top of the script): `127.0.0.1` ports reached by an SSH tunnel, no systemd, host volume on the node's local disk.

- **Login:** the same COmanage OIDC client, with the tunnel's callback `http://localhost:28080/login/oauth2/code/cbio-idp` registered on it. It is on when the issuer, client id and client secret are in `secrets/` (otherwise the job runs without login and without OPA, and says so).
- **Access (OPA):** with login on, the job starts its own OPA container (`c3g-cbioportal-opa`, `127.0.0.1:28181`). There is no bundle URL yet, so OPA reads a local copy instead: the repo's `opa/c3g_cbioportal/authz.rego` plus your `secrets/opa_data.json`, which stands in for `c3g_cbioportal/data.json` in c3g-opa-policies. This is the first end-to-end test of OPA mode.
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

- At step 2/6 the job checks the `.sha256`, loads the newest `*_amd64.tar` in `${TEST_DIR}/image/`, and logs its release, commit and architecture. To pick another file, set `IMAGE_ARCHIVE=<file>` at step 5.
- **Other sources, for later:**
  - `IMAGE_SOURCE=build` builds on Cardinal from this clone. It needs a subuid range for your account (ask the SD4H admins).
  - `IMAGE_SOURCE=pull IMAGE=ghcr.io/c3g/c3g_cbioportal_instance:<release>` needs `podman login ghcr.io --authfile ~/.config/containers/auth.json` with a classic token (`read:packages`, authorized for the c3g org).

**3. Secrets.** Each template in `sd4h_slurm/secrets.example/` holds one commented, made-up example. Add the real value on a new line under it; `#` lines are ignored.

```bash
cp c3g_cbioportal_instance/sd4h_slurm/secrets.example/* ${T}/secrets/ && chmod 600 ${T}/secrets/*
nano ${T}/secrets/oidc_client_secret     # COmanage client secret
nano ${T}/secrets/oidc_issuer            # issuer URL
nano ${T}/secrets/oidc_client_id         # client id
nano ${T}/secrets/opa_data.json          # study ids -> COmanage groups (JSON, no comments; see below)
```

| File | Holds | Example line (made up) |
|------|-------|------------------------|
| `oidc_client_secret` | COmanage client secret | `cKKG4l-5U8WCUsOjs_bkkNXnlS9p7hUtYlG51ovik...` |
| `oidc_issuer` | issuer URL | `https://idp.example.org/oidc` |
| `oidc_client_id` | client id | `cilogon:/client_id/7855a3979be3004da4ecdfcc6c7f5923` |
| `opa_data.json` | which COmanage groups see which study (OPA data) | `{"admin_groups": ["c3g-cbioportal-admins"], "study_groups": {"<study_id>": ["c3g-cbioportal-<project>"]}}` |

- `opa_data.json` replaces the template's placeholders entirely (it's JSON, so no `#` lines). Use the real `cancer_study_identifier`s and the group names **exactly as COmanage puts them in the token**. You must be in one of them, or you'll log in and see no study.
- The COmanage client must release the `groups` claim (ask the COmanage admins if your groups don't show up).
- The job checks the file's shape before anything starts. At step 3/6 it prints, for each study in the manifest, the groups OPA gives it, or `NOT LISTED -> hidden`.
- `secrets.example/users.tsv` belongs to the users-file mode (off) and isn't used.

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
#   groups: <PROJECT>;C3G_ADMINS             replaced on the host by OPA's groups (opa_data.json)
```

- **I GZ had to add this by hand - to test - CHECK_HERE**
- With OPA, the `groups:` line doesn't decide access. The v2.1.0 image's build still stops without one, so keep it until an image from this branch's code is used.
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
echo <study_folder> >> ${T}/shared/manifests/test.txt
cat ${T}/shared/manifests/test.txt
```

** I CHANGED HERE **
```bash
echo <study_folder> >> ${T}/shared/manifests/test.txt
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

Expect one line per study, with an `id` (the same one as in `opa_data.json`) and the number of reports you copied.

**5. Submit** (from the repo root; build + serve in one job)

```bash
cd ${T}/c3g_cbioportal_instance && mkdir -p job_outs
sbatch sd4h_slurm/c3g-cbioportal-slurm.sh test.txt
# IMAGE_ARCHIVE=${T}/image/<file>.tar sbatch sd4h_slurm/c3g-cbioportal-slurm.sh test.txt   # a given image file (step 2)
# CBIO_DB_SNAPSHOT=<id> sbatch sd4h_slurm/c3g-cbioportal-slurm.sh         # serve / roll back to an existing snapshot
tail -f job_outs/cbio_sd4h_test_<jobid>.o                                # steps 1/6 ... 6/6
```

**6. Open it.** At step 6/6 the log prints the exact SSH tunnel command for your laptop (with the node name). Run it, then open `http://localhost:28080`. Use `localhost`, not `127.0.0.1`: the OIDC callback must match.

- **What to check (OPA):** with your project group you see the study; without it you don't. With `C3G_OPA_DENY` in `studies`, nobody does. To test fail closed, stop OPA on the node (`podman stop c3g-cbioportal-opa`, then `sync-access`): every study must disappear. Start it again and run `sync-access` to bring them back.
- **No study visible after login:** check that your token's groups reached cBioPortal: `podman exec c3g-cbioportal grep -i 'client roles' /data/logs/cbioportal.log` (an error there means the `groups` claim is missing).

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
| Units | [`deploy/c3g-cbioportal.service`](deploy/c3g-cbioportal.service), and [`deploy/c3g-cbioportal-opa.service`](deploy/c3g-cbioportal-opa.service) (start it first), installed to `~/.config/systemd/user/` |
| Updates | `--label io.containers.autoupdate=registry`: a published GitHub Release (`latest`) is picked up within ~15 min. Roll back by pinning a release tag (`:v1.0.0`). A release that changes cBioPortal's version also needs a new snapshot, so pin the old tag until the new snapshot is ready |
| Volume | "Reserve space" in the template, `APPNAME=cbioportal` (XFS label ≤ 12 characters) → `/home/genome/cbioportal-volume:/data:Z`. Must be local/block disk (ClickHouse runs on it) |
| Shared storage | `snapshots/` mounted read-only on the webapp VM; the whole folder read-write on the Build VM. Storage type, mount point, same `genome` uid/gid on both VMs: **ASK** SD4H admins. Mounted without `:Z` (never relabel shared storage) |
| Secrets | Prefixed podman secrets, passed as env vars:<br/>`printf '%s' '<value>' \| podman secret create C3G_CBIOPORTAL_OIDC_CLIENT_SECRET -`<br/>`python3 -c 'import secrets; print(secrets.token_hex(16), end="")' \| podman secret create C3G_CBIOPORTAL_CH_PASSWORD -`<br/>To change one: `podman secret rm`, create again, restart the unit |
| Database | None on the shared Postgres: ClickHouse + MongoDB run inside the container |
| OIDC client | From the COmanage admins. Redirect URI `https://cbioportal.c3g-app.sd4h.ca/login/oauth2/code/cbio-idp`, `authorization_code` / `client_secret_basic`, scopes `openid profile email org.cilogon.userinfo`, claims `email name` **and `groups`** (the COmanage project groups; study access depends on them) |
| Auth tier | 3b shape: cBioPortal's own OIDC login + the app's own OPA. No oauth2-proxy: nginx goes straight to the app |
| OPA | Own container `c3g-cbioportal-opa`, pinned `openpolicyagent/opa`, `-p 127.0.0.1:8181:8181` (**ASK** port), policy `c3g_cbioportal/` in c3g-opa-policies, `--bundle <bundle_url>` (**ASK**: not ready yet). The portal reaches it at `http://10.0.2.2:8181` (`CBIO_AUTHZ=opa`, `OPA_URL`) |
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
- Login is cBioPortal's own OIDC, and OPA's decision is written into cBioPortal's database (every 5 min) instead of being asked per request; there is no oauth2-proxy or Flask OPA library.
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
| Host | Its local copy only: schema migration at start, and `cancer_study.groups` from OPA (every 5 min) |
| Webapp | Nothing (users' saved sessions go to MongoDB, not ClickHouse) |

**Adding more studies:** the database is **rebuilt from scratch on every build**. Studies are never added to the running database.

```
manifests/portal.txt                    build                          host
  study_A          ─┐
  study_B           ├──►  empty DB + seed + A + B + C  ──►  snapshots/<new id>/  ──►  CBIO_DB_SNAPSHOT=<new id>, restart
  study_C  (new)   ─┘
```

1. Copy the new study folder to `studies/`, its PCGR reports to `reports/<cancer_study_identifier>/`. Add the study to `c3g_cbioportal/data.json` in c3g-opa-policies.
2. Add one line to `manifests/portal.txt`. Keep the existing lines.
3. Build → a new snapshot holding all the studies, old and new.
4. Switch the host to the new snapshot and restart. The previous snapshot stays as the rollback.

- **Replace a study:** update its folder, then build. **Remove a study:** delete its line, then build.
- **Why a full rebuild:** each snapshot is exactly its manifest, so it can be rebuilt and nothing drifts. cBioPortal can't add PCGR report links to an existing study anyway.
- **Cost:** every build reloads the seed (~10–15 min), plus each study's import (usually minutes). Long imports usually mean a problem in the pipeline output. On Narval, duplicate gene/sample rows in `data_cna_long.txt` took 68 of 70 minutes.
- **Access:** never in a snapshot. The host writes OPA's groups into its copy at start and every 5 min, so changing access never needs a rebuild.
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
