# c3g_cbioportal_instance
_Last Modified:_ 2026-11-27

**Authors:** Gerardo Zapata

Private [cBioPortal](https://www.cbioportal.org/) 7.1.2 for C3G client studies (GRCh38): one podman image holding the webapp, ClickHouse, MongoDB and session-service.
Login through C3G COmanage (OIDC/CILogon). The app's own **OPA** decides which COmanage group sees which study; a person's groups come from their login token ([Who can see what](#who-can-see-what)).
Each sample's **PCGR report** opens as a tab in the patient view, with the same access.
Home page: the full C3G logo with a welcome and contact text (`CBIO_SKIN_BLURB`). Header: the C3G emblem, left of the login button (`CBIO_RIGHT_LOGO`).

- URL: https://cbioportal.c3g-app.sd4h.ca
- Image: `ghcr.io/c3g/c3g_cbioportal_instance` (private: `podman login ghcr.io` first)

<br/>

---

<br/>

> ⚠️ **AI-written.** This README and the code in this repo (`entrypoint.sh`, `reports_server.py`, `Containerfile`, `run.sh`, `deploy/`, the OPA policy) were written with an AI assistant (Claude, Anthropic). Check it against the code and test it before relying on it, especially access control. The one-VM setup (host pod + builder pod) has not been run on the VM yet. OPA + COmanage login was verified end to end on the `sd4h_test` branch (2026-11-25).

<br/>

---

<br/>

## How it works

![overview of c3g_cbioportal_instance](overview.png)

<sub>Diagram source: [`overview.svg`](overview.svg).</sub>

One image, two jobs, on **one SD4H VM**, in **two podman pods**:

| Pod | Holds | Runs | Resources |
|-----|-------|------|-----------|
| **host pod** `c3g-cbioportal` | the portal + its OPA | always (systemd) | no cap: the whole VM is available to it |
| **builder pod** `c3g-cbioportal-build` | one build container | only during a build, then removed | capped: own cores, hard memory limit, killed first if the VM runs short |

The data is dropped into a **drop folder** on the VM (`<shared>`, location still to be set). The **builder pod** turns it into a ready-to-serve database (a **snapshot**). The **host pod** serves that snapshot and controls who sees what. The host pod only reads `<shared>/snapshots/`, and the builder is capped, so a build can't slow down or break the portal ([Resources](#resources)).

1. **Data in.** The C3G analyst copies the pipeline output to the drop folder:
   - each cBioPortal study (a **cohort**) is one folder in `studies/`. Every folder there is served;
   - PCGR reports go to `reports/<cancer_study_identifier>/`.
2. **Check + build (builder pod).** Once the transfer has finished, `deploy/c3g-cbioportal-check.sh`:
   - compares every cohort with the one in `CURRENT` (file fingerprints) and lists it as `NEW`, `CHANGED`, `SAME` or `REMOVED`;
   - asks y/N, then builds in the capped builder pod. An **incremental** build takes a copy of `CURRENT`'s database and re-imports only the `NEW` and `CHANGED` cohorts. A changed cohort is always re-imported **whole**, even when only one sample was added or updated. A **full** build starts from an empty database: the first time, after an image upgrade, or with `FULL=true` ([Incremental builds](#incremental-builds));
   - the build validates and imports, adds the PCGR report tabs and publishes `snapshots/<YYYYmmdd-HHMMSS>/`, writing `READY` last. ClickHouse runs in the build's own **scratch** folder, never in the drop folder.
3. **Promote (builder side).** `deploy/c3g-cbioportal-promote.sh <id>`:
   - checks the snapshot (`READY` present, same cBioPortal version);
   - shows what changes against `CURRENT`: studies added, removed or rebuilt, and changed groups;
   - asks, then writes `snapshots/CURRENT`.
4. **Host sync (host pod).** The host mounts `snapshots/` read-only. At **06:00 and 18:00** (`CBIO_SYNC_TIMES`), or right away with `sync-now`, it copies the snapshot named in `CURRENT` to its local `/data` volume and switches to it in place, **without a restart**.
5. **Authorization (OPA).** At the same sync, the host asks its own OPA container (same pod, `127.0.0.1:8181`) which COmanage groups may see each study. The answer comes from `c3g_cbioportal/data.json` in the c3g-opa-policies bundle, and the host writes it into its copy (`cancer_study.groups`). A study that OPA doesn't list is hidden from everyone. If OPA is down, every study is hidden.
6. **User.** The web browser reaches the portal over HTTPS through C3G's nginx proxy (`cbioportal.c3g-app.sd4h.ca`). Requests under `/reports/` go to the PCGR report gatekeeper.
7. **Authentication (COmanage / CILogon).** cBioPortal's own OIDC login sends the person to COmanage / CILogon. Their token carries their COmanage groups (the `groups` claim).
   - A person sees a study only when one of their groups is one of that study's groups.
   - A PCGR report is served only when the portal says that person may see its study.

More detail: [Who can see what](#who-can-see-what) and [The ClickHouse database](#the-clickhouse-database).

- **During a switch:** the new snapshot is copied while the old one still serves. Then only ClickHouse restarts (~10–20 s of page errors); logins, the webapp and saved sessions stay up. If the new database doesn't come up, the old one is put back.
- **Roll back:** promote the previous snapshot id.
- **A snapshot that doesn't come up** (at a switch or at start) is put aside as `/data/clickhouse.failed`. The previous copy keeps serving, and that id is not tried again. Build a new snapshot and promote it.
- Both pods use the **same image** (one image store on the VM; the builder takes `:latest`, which auto-update also gives the host). The host and `promote` refuse a snapshot built with another cBioPortal version.

<br/>

---

<br/>

## Step by step

`S=/Path/to/YOUR/cbioportal_drop` = the drop folder on the VM (layout in [How it works](#how-it-works)). Commands run from the repo root, on the VM, as `genome`.

### For updating: add, update or remove a study (builder pod)

**1. Study folder.** Copy the pipeline's cBioPortal study folder as it is: one folder per study (cohort). No symlinks: only `studies/`, `reports/` and `snapshots/` are mounted.

```bash
S=/Path/to/YOUR/cbioportal_drop
cp -r <pipeline_output>/<study_folder> ${S}/studies/
grep -E '^(cancer_study_identifier|groups):' ${S}/studies/<study_folder>/meta_study.txt
#   cancer_study_identifier: <study_id>
#   groups: <PROJECT>;C3G_ADMINS          ignored on the host: OPA decides (step 6)
```

- **Update a cohort** (samples added or re-run): replace its whole folder. **Remove a cohort:** delete its folder (the check asks for a typed `yes`).
- Every folder in `studies/` must be a complete cBioPortal study with a `meta_study.txt`; the check stops on any other folder.

**2. PCGR reports (optional).** One flat folder per study, named after its `cancer_study_identifier`.

```bash
SID=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' ${S}/studies/<study_folder>/meta_study.txt | tr -d '[:space:]')
mkdir -p ${S}/reports/${SID}
find <pipeline_output> -name '*.pcgr_acmg.grch38.flexdb.html' -exec cp {} ${S}/reports/${SID}/ \;
```

**3. Check, then build** (only after the transfer has finished). It shows what changed since `CURRENT`, asks, then builds only the new and changed cohorts. A build can take hours, so run it inside `tmux`.

```bash
tmux new -s cbio-build
SHARED=${S} SCRATCH_ROOT=/Path/to/YOUR/BuilderScratch ./deploy/c3g-cbioportal-check.sh
#   status   action   study_id      samples  detail
#   CHANGED  import   cohort_a      83 (+5)  +5 sample(s): S101, ...; 6 file(s) changed: ...; 5 report(s) added: ...
#   SAME     keep     cohort_b      78       unchanged
# Build snapshot <id> as planned above? [y/N]
# -> Snapshot ready: .../snapshots/<id>
```

- Nothing changed → no build. The portal keeps serving the old snapshot during the build.

**4. Promote** it: shows `ADDED` / `REMOVED` / `groups` changes against `CURRENT`, asks, writes `CURRENT`.

```bash
SHARED=${S} ./deploy/c3g-cbioportal-promote.sh <id>
```

**5. Live.** The host switches at **06:00 or 18:00**, without a restart. To switch now, on the host: `sync-now` (For hosting, step 5). Roll back: promote the previous id.

**6. Access.** A new study is **hidden from everyone** until it is in OPA's policy: add `"<study_id>": ["<COmanage group>"]` to `c3g_cbioportal/data.json` in c3g-opa-policies, and put the people in that COmanage group ([Who can see what](#who-can-see-what)). Applied at 06:00 / 18:00 or with `sync-access`.

### For hosting: run the portal (host pod)

**1. Volume.** Local disk, mounted as `/data`.

```bash
VOL=/Path/to/YOUR/HostData
mkdir -p ${VOL}
```

**2. Secrets and image login.**

```bash
printf '%s' '<oidc_client_secret>' | podman secret create C3G_CBIOPORTAL_OIDC_CLIENT_SECRET -
python3 -c 'import secrets; print(secrets.token_hex(16), end="")' | podman secret create C3G_CBIOPORTAL_CH_PASSWORD -
podman login ghcr.io                  # classic token with read:packages, authorized for the c3g org
```

**3. Units.** The pod unit, then its two containers (OPA, portal). Fill the `<...>` placeholders: host ports (pod unit), bundle URL (OPA unit), issuer URL, client ID, `<shared>` (portal unit). Keep `CBIO_DB_SNAPSHOT=current` and `CBIO_AUTHZ=opa`.

```bash
cp deploy/c3g-cbioportal-pod.service deploy/c3g-cbioportal-opa.service deploy/c3g-cbioportal.service ~/.config/systemd/user/
nano ~/.config/systemd/user/c3g-cbioportal-pod.service      # host ports
nano ~/.config/systemd/user/c3g-cbioportal-opa.service      # <bundle_url> (ASK: not ready yet)
nano ~/.config/systemd/user/c3g-cbioportal.service          # <issuer_url>, <client_id>, <shared>
```

- `snapshots/CURRENT` must exist before the first start: do For updating steps 1–6 once.

**4. Start.**

```bash
systemctl --user daemon-reload
systemctl --user enable c3g-cbioportal-opa.service c3g-cbioportal.service
systemctl --user enable --now c3g-cbioportal-pod.service     # creates the pod, starts OPA, then the portal
podman ps --pod                                              # c3g-cbioportal-opa + c3g-cbioportal in pod c3g-cbioportal
podman logs -f c3g-cbioportal                                # ready at "All services up, serving snapshot <id>"
podman exec c3g-cbioportal /app/entrypoint.sh snapshots      # CURRENT, served, next sync
```

**5. Day to day** (no restarts needed).

```bash
podman exec c3g-cbioportal /app/entrypoint.sh sync-now       # take a promoted snapshot now (else 06:00 / 18:00)
podman exec c3g-cbioportal /app/entrypoint.sh sync-access    # apply an OPA policy change now (always after removing a group)
podman exec c3g-cbioportal /app/entrypoint.sh studies        # studies + their groups (C3G_OPA_DENY = hidden)
```

**6. Stop cleanly** (ordered shutdown, ClickHouse last).

```bash
systemctl --user stop c3g-cbioportal-pod.service             # the whole host pod (portal + OPA)
```

<br/>

---

<br/>

## Incremental builds

`deploy/c3g-cbioportal-check.sh` decides what a build must do. It runs `/app/entrypoint.sh check` → `cohort_plan.py` in a small container on the builder's cores.

**Cohort = one folder of `studies/` = one cBioPortal study**, plus its reports in `reports/<cancer_study_identifier>/`. Each cohort gets a **fingerprint**: the sha256 of every file in its study folder and of every report. The fingerprints are stored in each snapshot's `BUILD_INFO.json` (`cohorts`).

| Compared with `CURRENT` | Status | The build |
|---|---|---|
| Not in `CURRENT` | `NEW` | imports it |
| Any file added, changed or removed (a sample added, updated or dropped; a report changed) | `CHANGED` | removes it and re-imports the **whole cohort** |
| Same fingerprint | `SAME` | keeps it as it is in `CURRENT`'s database (reports copied from `CURRENT`) |
| In `CURRENT`, no folder any more | `REMOVED` | removes it (the check asks for a typed `yes`) |

- **Incremental build:** copy of `CURRENT`'s database → `remove-study` for `REMOVED` cohorts → import of each `NEW` / `CHANGED` cohort. cBioPortal's `metaImport.py` removes the old version of a study before importing it again, so a changed cohort never ends up twice. Then the deleted rows are compacted (`APPLY DELETED MASK`), so snapshots don't grow with every rebuild. Derived tables are rebuilt for all studies after each import.
- **Full build** (empty database, every cohort imported): when there is no usable `CURRENT` (the first build), when `CURRENT` was built before incremental builds (no fingerprints), with `FULL=true`, or when a setting the snapshot depends on changed: **another image than `CURRENT` was built with (image upgrade)**, the cBioPortal version, the report URL or report settings.
- **Base = `CURRENT`**, the snapshot being served, never a newer unpromoted one. If you built a snapshot but didn't promote it, the next check compares against `CURRENT` again, so that snapshot's changes are included again.
- **The plan:** `<SCRATCH_ROOT>/plans/<snapshot id>.json` (+ `.check.log`), copied into the snapshot as `logs/plan.json`. Before importing, the build re-checks the fingerprints of the cohorts to import and the image. If either changed since the check, it stops: run the check again.
- **Check that the build matches the plan:** after the imports, the studies in the database must be exactly the plan's imported + kept cohorts, or the build fails.
- **Time:** a build costs about one changed cohort instead of all of them. With today's converter that's ~1 min per sample of the cohort: ~20 min for a ~20-sample cohort, against ~16–17 h for a full build at 1,000 samples ([Resources](#resources)).
- **Removing a study needs a ClickHouse cluster named `default`.** cBioPortal's remove-study (`ClickHouseBulkDeleter`) checks every replica with `clusterAllReplicas('default', ...)`. [`config/clickhouse-config.xml`](config/clickhouse-config.xml) defines it as this one server; without it a changed or removed cohort fails with "Requested cluster 'default' not found". Full builds never remove anything, so they don't need it.
- **Tested on a laptop (2026-11-27, public datahub studies):**
  - a full build;
  - a check with nothing changed (no build);
  - a changed cohort re-imported whole plus a new cohort;
  - a removal-only build;
  - a full build after an image upgrade;
  - a build refused because the drop folder changed after the check.

  After the incremental builds, a `FULL=true` rebuild of the same data gave the same row count in all 63 data tables, and the edited value, mutations, CNA and report links matched. Only cBioPortal's ID counters differ, because the IDs of deleted versions are never reused.
- **Run the check only after a transfer has finished.** It can't tell a half-copied folder from an updated one.
- Promote shows kept cohorts as `same` and re-imported ones as `rebuilt`.

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
| Let a group see a study / stop it | Edit the study's line in `c3g_cbioportal/data.json` (c3g-opa-policies) | No. Applied at 06:00 / 18:00, or now with `sync-access` |
| Give C3G staff access to everything | Put their COmanage group in `admin_groups` | No. Admins see every study OPA **lists** |

- **Fail closed.** A study OPA doesn't list gets the group `C3G_OPA_DENY`, so nobody sees it. If OPA doesn't answer (3 tries, 10 s apart), **every** study gets it until OPA is back. Never create a COmanage group called `C3G_OPA_DENY`.
- **When it is applied:** at host start (before the webapp), after every snapshot switch (each snapshot starts with the pipeline's groups), at each sync time (06:00 and 18:00), and on `sync-access`. Then cBioPortal's cache is cleared.
- **Group strings** must match the token exactly as COmanage sends them (full COmanage name or short name: check one real token). They may not contain `;`, quotes or backslashes.
- **`meta_study.txt` `groups:`** is still accepted by the build but replaced on the host. The build doesn't need it.
- **The build** asks OPA only when `OPA_URL` is passed to it, and then only warns about studies OPA doesn't list.
- **The policy:** a copy for development is in [`opa/c3g_cbioportal/`](opa/c3g_cbioportal/); the real one lives in c3g-opa-policies. Test it with `opa test opa/ -v` (from the repo root, never the policy folder itself, because OPA names the data after its folder).
- **How it works inside:** cBioPortal reads the user's groups from the token (`spring.security.oauth2.client.jwt-roles-path=groups`). `entrypoint.sh sync_opa` asks OPA `POST /v1/data/c3g_cbioportal/authz/study_access` and writes the answer into `cancer_study.groups` with `ALTER TABLE ... UPDATE`.
- **Users-file mode (off, kept).** cBioPortal's own authorization (`CBIO_AUTHZ=cbioportal`: `/data/access/users.tsv` + `meta_study.txt` groups, `authorization=true`) is still in the code but not used.

<br/>

---

<br/>

## Commands

### Check and build a snapshot (builder pod)

```bash
SHARED=/Path/to/YOUR/cbioportal_drop \
SCRATCH_ROOT=/Path/to/YOUR/BuilderScratch \
IMAGE=ghcr.io/c3g/c3g_cbioportal_instance:latest \
  ./deploy/c3g-cbioportal-check.sh                           # NEW / CHANGED / SAME / REMOVED, asks, then builds
FULL=true SHARED=... ./deploy/c3g-cbioportal-check.sh        # full rebuild (empty DB, every cohort)
SHARED=... ./deploy/c3g-cbioportal-build.sh <SCRATCH_ROOT>/plans/<id>.json   # build a plan you declined earlier
podman pod ps; podman stats --no-stream                      # from another terminal: the builder pod and its usage
```

- The check: [Incremental builds](#incremental-builds). `--yes` skips the question; it refuses when cohorts would be removed unless `CBIO_ALLOW_REMOVE=true`.
- The build creates pod `c3g-cbioportal-build`, runs the build in it, and removes the pod at the end (also after a failure or Ctrl-C). **One build at a time:** while the pod exists, a second build is refused.
- **Caps** (variables at the top of the script): own cores `BUILD_CPUSET=6-7`, memory `MEMORY=10g` with no swap (importer `-Xmx4G`, ClickHouse 4 GB), CPU weight `BUILD_CPU_SHARES=128` (default 1024), `BUILD_OOM_SCORE_ADJ=800` (if the VM runs out of memory, the build is killed, not the portal). Optional disk I/O weight `BUILD_IO_WEIGHT`. Exit 137 = killed, usually the memory cap.
- It refuses to build when cgroup v2 or the `cpu` / `cpuset` / `memory` controllers are not delegated to `genome`, because the caps would then do nothing ([For web app maintainers](#for-web-app-maintainers)).

- Incremental: starts from a copy of `CURRENT`'s database and imports only the new / changed cohorts. Full: empty database, schema + seed (~2 min on Cardinal), then every cohort.
- ClickHouse runs in the `SCRATCH_ROOT` folder (local disk), never in the drop folder.
- PCGR reports in `reports/<cancer_study_identifier>/` are linked to their samples (`<SAMPLE_ID or PATIENT_ID>.pcgr_acmg.grch38.flexdb.html`) and copied into the snapshot. The study folder is never changed.
- Success: `snapshots/<id>/` with `READY` written last. Failure: only `<id>.partial/` is left, and the host refuses it.
- Access isn't decided at build time: OPA decides on the host. With `OPA_URL=http://10.0.2.2:8181` (the host pod's OPA) the build warns about studies OPA doesn't list (those would be hidden).
- Snapshots and scratch folders are never deleted automatically. Remove `SCRATCH_ROOT/build_<id>/` after a good build, and old snapshots once they're no longer needed for a rollback ([Resources](#resources)).
- A new snapshot is **not** live until it is promoted (next section). `PROMOTE=true ./deploy/c3g-cbioportal-check.sh` runs the promote right after a good build.

### Put a snapshot live: promote (builder side)

```bash
SHARED=/Path/to/YOUR/cbioportal_drop ./deploy/c3g-cbioportal-promote.sh 20261120-143000
```

- Checks the snapshot (READY, same cBioPortal version), then shows each study against the current `CURRENT`: `ADDED`, `REMOVED`, `groups` changed (old → new), `rebuilt`, `same`, with the number of PCGR reports. The groups shown are the pipeline's `meta_study.txt` ones; on the host OPA replaces them.
- Asks `y/N`. If a study would **disappear** (a folder deleted from `studies/`?), you have to type `yes`.
- Writes `snapshots/CURRENT` in one step and adds a line to `snapshots/promote.log` (date, old → new id, who).
- `--yes` skips the question (scripts); it refuses when a study would be removed unless `CBIO_ALLOW_REMOVE=true`.
- **Roll back:** promote the previous id the same way.
- It runs as a small one-off container on the builder's cores (`BUILD_CPUSET`, 1 GB), because the host pod only reads `snapshots/`.

### Start the portal (host pod)

```bash
cp deploy/c3g-cbioportal-pod.service deploy/c3g-cbioportal-opa.service deploy/c3g-cbioportal.service ~/.config/systemd/user/.
systemctl --user enable c3g-cbioportal-opa.service c3g-cbioportal.service
systemctl --user enable --now c3g-cbioportal-pod.service    # pod -> OPA -> portal
podman logs -f c3g-cbioportal                               # ready at "All services up, serving snapshot <id>"
```

- Before the first start, fill the `<...>` placeholders in the units: ports (pod unit), bundle URL, issuer URL, client ID, `<shared>`. Promote a first snapshot (so `snapshots/CURRENT` exists).
- The pod unit creates pod `c3g-cbioportal` (network + ports: 8080, 8090, `127.0.0.1:8181`) and starts OPA, then the portal, inside it. The portal reaches OPA at `127.0.0.1:8181`. Stopping the pod unit stops both.
- The host pod has no resource cap (the builder is the one capped). The portal has `--memory-reservation 12g` (cgroup `memory.low`).
- Startup order: copy the snapshot (if new) → ClickHouse → OPA's groups → MongoDB → session-service → webapp → report server. Then it waits for the next sync time.
- It refuses to start without the OIDC settings. If `CURRENT` is missing or not usable (no `READY`, other cBioPortal version), it keeps serving its local copy and warns; it only refuses when it has no local copy yet.
- `CBIO_DB_SNAPSHOT=<id>` instead of `current` **pins** the host to that snapshot: it never follows `CURRENT` (for debugging).
- OPA not answering → the portal starts, but **every study is hidden** (fail closed) until the next sync that reaches OPA (or `sync-access`).
- The same command without systemd is in [`run.sh`](run.sh).

### Switch to the promoted snapshot now (host pod)

```bash
podman exec c3g-cbioportal /app/entrypoint.sh sync-now
```

- Runs the scheduled sync right away instead of waiting for 06:00 / 18:00: switch to `CURRENT` if it changed, re-apply OPA's groups, clear cBioPortal's cache. Prints the result.
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

`groups` = the groups that can see the study, as last written from OPA. `C3G_OPA_DENY` = hidden (OPA doesn't list it, or OPA was down).

### Apply an OPA policy change now

```bash
curl -s -X POST http://127.0.0.1:8181/v1/data/c3g_cbioportal/authz/study_access   # what OPA allows now (on the VM)
podman exec c3g-cbioportal /app/entrypoint.sh sync-access
```

This asks OPA, prints each study whose groups change (`old -> new`), writes them, and clears cBioPortal's cache. The same sync runs on its own at 06:00 and 18:00, so **run `sync-access` after taking a group off a study**. Whether OPA has the new policy yet depends on its bundle polling.

### Health check, stop, start

```bash
podman healthcheck run c3g-cbioportal                    # every service answers
systemctl --user stop c3g-cbioportal-pod.service         # whole host pod: ordered shutdown, ClickHouse last (up to 5 min)
systemctl --user start c3g-cbioportal-pod.service
systemctl --user restart c3g-cbioportal.service          # the portal only (OPA keeps running)
```

### Local test (laptop, no login, never on the VM)

```bash
podman build -t c3g_cbioportal_instance:dev -f Containerfile .
mkdir -p shared/{studies,reports,snapshots} scratch host     # one folder per study in shared/studies + its reports
# builder pod (podman machine: no cpuset controller -> no pinning, no cgroup check; no SELinux label on a laptop mount)
SHARED=./shared SCRATCH_ROOT=./scratch IMAGE=c3g_cbioportal_instance:dev BUILD_CPUSET= CHECK_CGROUPS=false SHARED_LABEL= \
  MEMORY=8g CBIO_REPORTS_URL=http://localhost:8090/reports ./deploy/c3g-cbioportal-check.sh
SHARED=./shared SHARED_LABEL= BUILD_CPUSET= IMAGE=c3g_cbioportal_instance:dev ./deploy/c3g-cbioportal-promote.sh <id>
# host pod
podman pod create --replace --name cbio-test -p 127.0.0.1:8080:8080 -p 127.0.0.1:8090:8090
podman run -d --pod cbio-test --name cbio-test-portal --stop-timeout=300 -e CBIO_AUTH=false -e CBIO_DB_SNAPSHOT=current \
  -e CBIO_REPORTS_URL=http://localhost:8090/reports -e CBIO_PORTAL_ORIGIN=http://localhost:8080 \
  -v ./host:/data:Z -v ./shared/snapshots:/snapshots:ro c3g_cbioportal_instance:dev
podman pod stop -t 300 cbio-test && podman pod rm cbio-test
```

Every other setting (`-e VAR=...`) is listed with its default at the top of [`entrypoint.sh`](entrypoint.sh) (`## CHANGE HERE ##`).

<br/>

---

<br/>

## For web app maintainers

From the C3G [web-app-template](https://github.com/c3g/web-app-template/blob/main/for-maintainers.md), what this app needs. Items marked **ASK** are still open.

| Item | This app |
|------|----------|
| VM | **One** SD4H VM for both pods (host pod + builder pod), host name **ASK**. Size: 8 vCPU, 32 GB RAM, ~100 GB data disk ([Resources](#resources)) |
| Login | `bastion_ssh <you>@<VM>` → `sudo machinectl shell genome@` (not `sudo -s`) |
| Units | Host pod: [`deploy/c3g-cbioportal-pod.service`](deploy/c3g-cbioportal-pod.service) (pod, network, ports; `enable --now` this one) + its members [`deploy/c3g-cbioportal-opa.service`](deploy/c3g-cbioportal-opa.service) and [`deploy/c3g-cbioportal.service`](deploy/c3g-cbioportal.service) (`enable`), installed to `~/.config/systemd/user/`. Template unit style (`podman generate systemd` shape, no Quadlet). The builder pod has no unit: [`deploy/c3g-cbioportal-build.sh`](deploy/c3g-cbioportal-build.sh) makes it for one build |
| Updates | `--label io.containers.autoupdate=registry`: a published GitHub Release (`latest`) is picked up within ~15 min. Roll back by pinning a release tag (`:v1.0.0`). A release that changes cBioPortal's version also needs a new snapshot, so pin the old tag until the new snapshot is ready. A unit from before the promote / fixed-time sync (pinned `CBIO_DB_SNAPSHOT=<id>`, `CBIO_SYNC_SECS`) keeps working with a newer image: it stays pinned and warns |
| Volume | "Reserve space" in the template, `APPNAME=cbioportal` (XFS label ≤ 12 characters) → `/home/genome/cbioportal-volume:/data:Z`. Must be local/block disk (ClickHouse runs on it) |
| Drop folder | `<shared>` = where the pipeline data is dropped on the VM: **ASK** (not set yet). Builder pod: `studies/`, `reports/` read-only, `snapshots/` read-write; host pod: `snapshots/` read-only. Seen by both pods, so mounted with `:z` (shared SELinux label); if it turns out to be NFS, `SHARED_LABEL=` and `:ro` only (never relabel NFS) |
| cgroups | cgroup v2 with the `cpu cpuset memory` (and ideally `io`) controllers delegated to `genome`, or the builder's caps do nothing (the build script refuses to run). Check: `podman info --format '{{.Host.CgroupControllers}}'`. Fix (root): `/etc/systemd/system/user@.service.d/delegate.conf` → `[Service]` `Delegate=cpu cpuset io memory pids`, then `systemctl daemon-reload` and log in again. Optional: `MemoryLow=12G` there too, so the portal's `--memory-reservation` also counts on the user level |
| Secrets | Prefixed podman secrets, passed as env vars:<br/>`printf '%s' '<value>' \| podman secret create C3G_CBIOPORTAL_OIDC_CLIENT_SECRET -`<br/>`python3 -c 'import secrets; print(secrets.token_hex(16), end="")' \| podman secret create C3G_CBIOPORTAL_CH_PASSWORD -`<br/>To change one: `podman secret rm`, create again, restart the unit |
| Database | None on the shared Postgres: ClickHouse + MongoDB run inside the container |
| OIDC client | From the COmanage admins. Redirect URI `https://cbioportal.c3g-app.sd4h.ca/login/oauth2/code/cbio-idp`, `authorization_code` / `client_secret_basic`, scopes `openid profile email org.cilogon.userinfo`, claims `email name` **and `groups`** (the COmanage project groups; study access depends on them) |
| Auth tier | 3b shape: cBioPortal's own OIDC login + the app's own OPA. No oauth2-proxy: nginx goes straight to the app |
| OPA | Own container `c3g-cbioportal-opa` **inside the host pod**, pinned `openpolicyagent/opa`, policy `c3g_cbioportal/` in c3g-opa-policies, `--bundle <bundle_url>` (**ASK**: not ready yet). The portal reaches it at `http://127.0.0.1:8181` (same pod; `CBIO_AUTHZ=opa`, `OPA_URL`). The pod also publishes it on the VM's `127.0.0.1:8181` (**ASK** port) for `curl` checks and the build's optional warnings (`http://10.0.2.2:8181`) |
| Ports | On the host pod: `8080` portal, `8090` PCGR report server: **ASK** which host ports. The builder pod publishes none |
| nginx | Template server block (`*.c3g-app.sd4h.ca` certificate), `server_name cbioportal.c3g-app.sd4h.ca;`, `proxy_pass http://<VM_IP>:<portal_port>;` (**ASK** the VM's IP; the template's `172.16.8.75` is the shared webapp VM) plus the block below (same host name, so the login cookie reaches the report server) |
| Stop timeout | `--stop-timeout=300` / `TimeoutStopSec=330`: ClickHouse needs time to stop cleanly |
| CPU / RAM split | Host pod: no cap (all 8 cores), portal `--memory-reservation 12g`. Builder pod: cores 6–7 only (`BUILD_CPUSET`), 10 GB hard cap, no swap, `oom-score-adj 800`. Total 32 GB = host ~16 + builder 10 + OS / page cache |

```nginx
location /reports/ {
    proxy_pass http://<VM_IP>:<reports_port>;   # 8090
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

Departures from the template that need maintainer sign-off:
- ClickHouse and MongoDB run inside the container instead of the shared Postgres.
- Login is cBioPortal's own OIDC, and OPA's decision is written into cBioPortal's database (twice a day) instead of being asked per request; there is no oauth2-proxy or Flask OPA library.
- The imports run in a second, capped pod on the same VM (the builder pod), made by a script, not by a unit.
- The app runs as a pod (portal + OPA), so OPA has no `-p`/`--network` of its own.
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
- The internal links are absolute (`/data/clickhouse/store/...`), so the folder only works at `/data/clickhouse` (`CBIO_DATA_DIR` must be the same in both pods).
- Only one ClickHouse server may use a folder at a time. That's why the host serves a **copy** of the snapshot, and why ClickHouse never runs in the drop folder.

**Who writes it:**

| Who | Writes |
|-----|--------|
| Builder | Full build: schema, seed, every cohort, derived tables. Incremental: a copy of `CURRENT`'s database, minus removed cohorts, plus the new / changed ones re-imported whole |
| Host | Its local copy only: schema migration at start and after a switch, and `cancer_study.groups` from OPA (at each sync) |
| Webapp | Nothing (users' saved sessions go to MongoDB, not ClickHouse) |

**Adding more studies:** never into the running database. Every build publishes a new, complete snapshot; the host switches to it after promote.

```
studies/                              build (builder pod)                                   host
  cohort_A  (SAME)      ─┐
  cohort_B  (CHANGED)    ├──►  copy of CURRENT's DB − B + B (whole) + C  ──►  snapshots/<new id>/ ──► promote (CURRENT) ──► switch at 06:00 / 18:00
  cohort_C  (NEW)       ─┘
```

- How the build decides: [Incremental builds](#incremental-builds). Full rebuild after an image upgrade or with `FULL=true`.
- **Cost:** each imported cohort costs ~1 min per sample with today's converter, almost all of it `data_cna_long.txt` (one line per gene and sample, ~25 k per sample, imported at ~440 lines/s).
- **Access:** never in a snapshot. The host writes OPA's groups into its copy after each switch, so changing access never needs a rebuild.
- **Why promote is a separate step:** a build that *runs* fine isn't always *right* (a folder deleted by mistake). Promote shows the difference and asks before anything goes live.
- Each snapshot is a full copy, so delete old ones by hand once they're no longer needed for a rollback.

<br/>

---

<br/>

## Open questions

- **What about the POST verification? Where should it go?** The idea is an authenticated POST: an app key in a request header, checked as in `require_appkey` in run_processing_dashboard's `API.py`. It would check the drop folder against what the portal displays. Not implemented yet. Still open:
  - who sends the POST;
  - what it checks;
  - whether it also triggers the sync;
  - where the endpoint runs.
- **Where is the data dropped on the VM** (`<shared>`), and is it local disk or NFS? Set once the VM is ready.

<br/>

---

<br/>

## Resources

### Measured on SD4H Cardinal

**Test setup.** The `sd4h_test` branch ran on Cardinal on 2026-11-23: build and host in one Slurm job, with 8 CPUs and 24 GB requested. The manifest held 3 studies, giving snapshot `20261123-152401`. The job's cgroup was sampled every 15 s, and the importer log gave the timings.

**What one build needs.** These builds were full builds: an empty database, then **every study** re-imported. So a full build takes the sum of all its studies, plus ~2 min to create the empty database (schema + seed) and ~15 s to publish. The two examples:

| | `mohq_cm_5` (small) | `HellenKuasne_WES_Paired_Test` (large) |
|---|---|---|
| Samples | 1 | 86 |
| Input data | 2.6 MB | 111 MB |
| Import time | 2.3 min (~1.5 min of it is the offline validation) | **82.3 min** (81.1 min is one file, `data_cna_long.txt`, 2.14 M lines) |
| Whole build, this study alone | **~5 min** | **~85 min** |
| CPU, average / max | 1.6 / 2.1 cores | 1.0 / 2.5 cores (single-threaded import) |
| RAM, real (programs) | 2.1 GB | **2.7 GB** |
| RAM, cgroup incl. page cache | 6.7 GB | 7.1 GB |

- All 3 studies together: 87 min of imports. The whole job peaked at 7.3 GB of memory, but no more than 2.7 GB of it was real program memory; the rest was page cache, which the system can reclaim.
- **Enough for one build:** 2–4 CPUs and 8 GB RAM (8 CPUs / 24 GB was oversized). Extra cores don't make it faster, because the import runs on one core.
- **Speed-up:** the import runs at ~440 lines/s of `data_cna_long.txt`, which has one line per gene and sample (2.14 M lines for 86 samples). Its duplicated gene × sample lines are only ~1–2 % of them, so removing them saves little. What would help in the converter: a wide `data_cna.txt` matrix (one line per gene for the whole cohort; import speed not measured yet), or only the non-neutral calls (but a missing gene × sample then shows as "not profiled"). In this repo: incremental builds ([Incremental builds](#incremental-builds)). More RAM or cores don't help: the import is single-threaded and used 2.7 GB.

**Disk.** Only one snapshot has been measured so far. It has not been split per study.

| What | Where | Size |
|------|-------|------|
| Image | the VM (podman storage, shared by both pods) | 2.1 GB as an amd64 `.tar` archive |
| Snapshot, 3 studies (`20261123-152401`) | drop folder, `snapshots/<id>/` | **138 MB** |
| Writes per study during the import | build scratch | 5–33 MB |
| Build scratch (`build_<id>/`) | `SCRATCH_ROOT`, local disk | about one snapshot + logs, kept until removed by hand |
| Host copy | host pod `/data`: `clickhouse/` + `clickhouse.prev/` | about 2 × one snapshot, + MongoDB |

- Every build adds a full snapshot to `snapshots/`, and old ones are only deleted by hand. With these 3 studies that's ~138 MB per build.
- To check the space used: `du -sh <shared>/snapshots/*`.

### Projection: 1,000 samples in ~50 cohorts, a build every ~5 new samples

Extrapolated from the Cardinal numbers above (~20 samples per cohort). Not measured.

| | Projection |
|---|---|
| Builds over the project | 1,000 / 5 ≈ **200** |
| Full build at 1,000 samples, current converter | ~1 min per sample (almost all `data_cna_long.txt`) → **~16–17 h** |
| Incremental build (5 samples added to one ~20-sample cohort) | that cohort re-imported whole → **~20–25 min** |
| Builder memory | per study, not the sum: studies import one after the other, so ~2–3 GB real per ~20-sample cohort (the 1-sample study already used 2.1 GB) |
| Builder CPU | ~1 core (single-threaded import), 2.5 at most |
| Snapshot at 1,000 samples | ~1.5–2 GB (~1.6 MB per sample) |
| Snapshots if never deleted | the sum over 200 growing builds ≈ **150–200 GB**, plus the same again in build scratch |
| Host `/data` | 2 × one snapshot (`clickhouse/` + `clickhouse.prev/`) + MongoDB + logs ≈ 6 GB |

- **Build time:** incremental builds keep the usual build at about one cohort (~20–25 min). A full build (first build, image upgrade, `FULL=true`) takes the whole ~16–17 h at 1,000 samples, so plan image upgrades for a quiet period. A second build is refused while one runs. The portal is not slowed down either way: the builder has its own cores.
- **Not yet measured:** after each import, the derived tables are rebuilt for **all** studies. That step wasn't timed separately, so with ~50 cohorts it may add a fixed cost to every incremental build on top of the ~20–25 min.
- **Disk:** keep `CURRENT` + ~2 older snapshots for rollback, and remove each `build_<id>/` scratch after a good build. That's ~5–6 GB of snapshots at 1,000 samples. Never deleting them (~150–200 GB) would not fit on the ~100 GB data disk ([VM size](#vm-size-and-how-it-is-split)).

### VM size and how it is split

**One VM: 8 vCPU, 32 GB RAM, ~100 GB data disk** (room for the drop folder, including the PCGR reports, which haven't been measured yet).

| | Host pod `c3g-cbioportal` | Builder pod `c3g-cbioportal-build` |
|---|---|---|
| Cores | all 8 (no cap) | **6–7 only** (`--cpuset-cpus`), CPU weight 128 vs 1024 |
| Memory | portal `--memory-reservation 12g` (cgroup `memory.low`), no hard cap; ≥ 16 GB in use with ClickHouse, the webapp JVM (4 GB), MongoDB and session-service | **10 GB hard cap, no swap**: importer JVM `-Xmx4G` + ClickHouse 4 GB + slack (~2× the measured 2.7 GB) |
| Out of memory on the VM | kept | killed first (`--oom-score-adj 800`) |
| Disk I/O | normal | optional lower weight (`BUILD_IO_WEIGHT`, needs the `io` controller + BFQ scheduler) |
| Lifetime | always on | one build, then removed; one at a time |

- The guarantee is on the **builder** side: the host never competes for cores 0–5, and the builder can't use more than 10 GB. The host can still use cores 6–7 when no build runs.
- A different VM size: change `BUILD_CPUSET`, `MEMORY`, `CH_MAX_MEMORY` and `CBIO_IMPORT_JAVA_OPTS` at the top of `deploy/c3g-cbioportal-build.sh` together (and `BUILD_CPUSET` in the promote script).

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
