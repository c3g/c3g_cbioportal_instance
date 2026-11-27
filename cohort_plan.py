#!/usr/bin/env python3
################################################################################
### c3g_cbioportal_instance - which cohorts a build must (re)import (README "Incremental builds")
### A cohort = one folder in <shared>/studies/ = one cBioPortal study (its cancer_study_identifier),
### plus its reports (PCGR, ORANGE, ...: config/report_types.tsv) in <shared>/reports/<cancer_study_identifier>/.
###
###   plan    compare the drop folder with the base snapshot (CURRENT): every cohort gets a fingerprint
###           (sha256 of each file of its study folder + each report). Then
###             NEW      cohort not in CURRENT                     -> imported
###             CHANGED  any file added / changed / removed        -> the WHOLE cohort is removed and re-imported
###             SAME     same fingerprint                          -> kept as it is in CURRENT
###             REMOVED  in CURRENT, no folder any more            -> removed
###           FULL build (empty DB, every cohort imported) when asked (FULL=true), when there is no usable CURRENT,
###           when CURRENT has no fingerprints (built before incremental builds), or when a setting the snapshot
###           depends on changed (image = image upgrade, cBioPortal version, report URL / settings, data path).
###           Writes the plan (JSON) and prints a summary. Exit 0 = build, 3 = nothing to build,
###           10 = build that REMOVES cohorts (the wrapper asks for a typed 'yes'), 1 = error.
###   verify  at build start: settings unchanged and every cohort to import still has its planned fingerprint
###           (the drop folder changed after the check -> run the check again)
###   lines   the plan as shell-readable lines for entrypoint.sh: mode / base / import / remove / keep
###   resources         build: link a study's reports to its samples -> cBioPortal resource files in the staging copy
###                     (one patient-view tab per report type found; exit 3 = no report matches a sample)
###   snapshot-reports  build: put the reports of every cohort of the plan into the new snapshot (hard links to the
###                     base snapshot when a file is unchanged, else copied from the drop folder)
###   types-digest      validate config/report_types.tsv and print its sha256 (a build setting: changed -> full)
### Report types (suffix, tab name, ...) come from config/report_types.tsv (--report-types).
### Python standard library only (runs inside the image).
################################################################################
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import sys
from collections import Counter
from urllib.parse import quote

SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
## = reports_server.py FILE_RE: report files the gatekeeper serves (no '/', no leading '.')
REPORT_FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*\.(html|pdf)$")
RESOURCE_ID_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
TYPE_COLS = ["RESOURCE_ID", "SUFFIX", "DISPLAY_NAME", "DESCRIPTION", "OPEN_BY_DEFAULT", "PRIORITY", "ID_TAGS"]
EXIT_BUILD, EXIT_ERROR, EXIT_NOTHING, EXIT_REMOVALS = 0, 1, 3, 10
PLAN_VERSION = 1


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(EXIT_ERROR)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def meta_value(path, key):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith(key + ":"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return ""


def study_files(folder):
    """relative path -> sha256 of every file of the study folder (hidden files / folders skipped)"""
    out = {}
    for root, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            if name.startswith("."):
                continue
            path = os.path.join(root, name)
            if os.path.isfile(path):
                out[os.path.relpath(path, folder)] = sha256_file(path)
    return out


### Report types (config/report_types.tsv)

def load_report_types(path):
    """the report types, in PRIORITY order: [{RESOURCE_ID, SUFFIX, DISPLAY_NAME, ..., tags: [...]}]"""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = [l.rstrip("\r\n") for l in fh if l.strip() and not l.startswith("#")]
    except OSError as e:
        die(f"cannot read the report types {path}: {e}")
    if not lines or lines[0].split("\t") != TYPE_COLS:
        die(f"{path}: the first line must be the header {chr(9).join(TYPE_COLS)} (tab-separated)")
    types, seen_id, seen_suffix = [], set(), set()
    for n, line in enumerate(lines[1:], start=2):
        f = line.split("\t")
        if len(f) != len(TYPE_COLS):
            die(f"{path}: line {n} has {len(f)} column(s), {len(TYPE_COLS)} expected (tab-separated)")
        t = dict(zip(TYPE_COLS, (x.strip() for x in f)))
        rid, suffix = t["RESOURCE_ID"], t["SUFFIX"]
        if not RESOURCE_ID_RE.match(rid) or rid in seen_id:
            die(f"{path}: RESOURCE_ID '{rid}' must be unique, upper case letters, digits and _")
        if not re.match(r"^[A-Za-z0-9_.-]*\.(html|pdf)$", suffix) or suffix in seen_suffix:
            die(f"{path}: SUFFIX '{suffix}' ({rid}) must be unique and end in .html or .pdf (letters, digits, _ . -)")
        if not t["DISPLAY_NAME"] or not t["DESCRIPTION"]:
            die(f"{path}: {rid} needs a DISPLAY_NAME and a DESCRIPTION")
        if t["OPEN_BY_DEFAULT"] not in ("true", "false"):
            die(f"{path}: OPEN_BY_DEFAULT of {rid} must be true or false")
        if not t["PRIORITY"].isdigit():
            die(f"{path}: PRIORITY of {rid} must be a whole number")
        t["tags"] = [] if t["ID_TAGS"] in ("", "-") else [x.strip() for x in t["ID_TAGS"].split(",") if x.strip()]
        if any(not re.match(r"^[A-Za-z0-9_.-]+$", x) for x in t["tags"]):
            die(f"{path}: ID_TAGS of {rid} must be '-' or a comma-separated list like -T")
        t["label"] = re.sub(r"\s+report$", "", t["DISPLAY_NAME"], flags=re.I) or rid
        seen_id.add(rid)
        seen_suffix.add(suffix)
        types.append(t)
    if not types:
        die(f"{path}: no report type")
    return sorted(types, key=lambda t: (int(t["PRIORITY"]), t["RESOURCE_ID"]))


def types_digest(path):
    """sha256 of the report types file: part of the settings a snapshot depends on (changed -> full rebuild)"""
    load_report_types(path)
    return sha256_file(path)


def report_type(name, types):
    """the report type of a file name (longest matching suffix), or None"""
    hits = [t for t in types if name.endswith(t["SUFFIX"]) and len(name) > len(t["SUFFIX"])]
    return max(hits, key=lambda t: len(t["SUFFIX"])) if hits else None


def report_files(reports_root, study_id, types):
    """file name -> sha256 of the reports in reports/<study_id>/ (files with a report type's suffix)"""
    d = os.path.join(reports_root, study_id)
    if not os.path.isdir(d):
        return {}
    return {name: sha256_file(os.path.join(d, name)) for name in sorted(os.listdir(d))
            if not name.startswith(".") and report_type(name, types) and os.path.isfile(os.path.join(d, name))}


def clinical_samples(folder):
    """[(PATIENT_ID, SAMPLE_ID)] of the study's sample attribute file (meta with datatype SAMPLE_ATTRIBUTES),
    or None when the study has no such file"""
    data_file = None
    for name in sorted(os.listdir(folder)):
        if name.startswith("meta") and name.endswith(".txt") and os.path.isfile(os.path.join(folder, name)):
            meta = os.path.join(folder, name)
            if meta_value(meta, "datatype").upper() == "SAMPLE_ATTRIBUTES":
                data_file = meta_value(meta, "data_filename")
                break
    if not data_file:
        data_file = "data_clinical_sample.txt"
    path = os.path.join(folder, data_file)
    if not os.path.isfile(path):
        return None
    rows, ip, i_s = [], None, None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            fields = [f.strip() for f in line.rstrip("\r\n").split("\t")]
            if i_s is None:
                header = [f.upper() for f in fields]
                if "SAMPLE_ID" not in header or "PATIENT_ID" not in header:
                    return None
                ip, i_s = header.index("PATIENT_ID"), header.index("SAMPLE_ID")
                continue
            if len(fields) > max(ip, i_s) and fields[i_s]:
                rows.append((fields[ip], fields[i_s]))
    return rows


def sample_ids(folder):
    """SAMPLE_IDs of the study (for the summary only; the fingerprint decides)"""
    return sorted({s for _, s in (clinical_samples(folder) or [])})


def id_variants(ident, tags):
    """the ids a report file may be named after: the id itself, then with / without each tag (e.g. -T)"""
    out = [ident]
    for tag in tags:
        out.append(ident[:-len(tag)] if ident.endswith(tag) and len(ident) > len(tag) else ident + tag)
    return list(dict.fromkeys(v for v in out if v))


def match_reports(samples, names, rtype):
    """link one report type's files to the samples. First hit per sample: SAMPLE_ID, SAMPLE_ID +/- tag,
    PATIENT_ID, PATIENT_ID +/- tag. Returns (rows [(patient, sample, file)], samples without a report)"""
    rows, missing = [], []
    for patient, sample in samples:
        cands = [v + rtype["SUFFIX"] for i in (sample, patient) if i for v in id_variants(i, rtype["tags"])]
        hit = next((c for c in cands if c in names), None)
        if hit:
            rows.append((patient, sample, hit))
        else:
            missing.append(sample)
    return rows, missing


def type_names(names, types):
    """{RESOURCE_ID: set of file names of that type}"""
    out = {t["RESOURCE_ID"]: set() for t in types}
    for n in names:
        t = report_type(n, types)
        if t:
            out[t["RESOURCE_ID"]].add(n)
    return out


def report_summary(samples, names, types):
    """'PCGR 20/20, ORANGE 18/20' + per-type problems, for the check table"""
    by_type = type_names(names, types)
    counts, notes = [], []
    for t in types:
        files = by_type[t["RESOURCE_ID"]]
        if not files:
            continue
        rows, missing = match_reports(samples, files, t)
        counts.append(f"{t['label']} {len(rows)}/{len(samples)}")
        if missing:
            notes.append(f"no {t['label']}: {short(missing)}")
        unused = sorted(files - {r[2] for r in rows})
        if unused:
            notes.append(f"{t['label']} matching no sample: {short(unused)}")
    return (", ".join(counts) or "none"), notes


def fingerprint(files, reports):
    blob = json.dumps({"files": files, "reports": reports}, sort_keys=True).encode()
    return hashlib.sha256(blob).hexdigest()


def scan(studies_root, reports_root, types, only_ids=None):
    """study_id -> cohort {folder, fingerprint, files, reports, samples} for every folder of studies/"""
    if not os.path.isdir(studies_root):
        die(f"{studies_root} not found (the drop folder's studies/ is not mounted?)")
    cohorts = {}
    for folder in sorted(os.listdir(studies_root)):
        path = os.path.join(studies_root, folder)
        if folder.startswith(".") or not os.path.isdir(path):
            continue
        if not SAFE_ID.match(folder):
            die(f"studies/{folder}: folder names may only use letters, digits, _ . - (and not start with . _ -)")
        meta = os.path.join(path, "meta_study.txt")
        if not os.path.isfile(meta):
            die(f"studies/{folder} has no meta_study.txt - every folder in studies/ must be one complete cBioPortal study")
        sid = meta_value(meta, "cancer_study_identifier").replace(" ", "")
        if not sid or not SAFE_ID.match(sid):
            die(f"studies/{folder}/meta_study.txt: cancer_study_identifier '{sid}' missing or not letters, digits, _ . -")
        if sid in cohorts:
            die(f"studies/{folder} and studies/{cohorts[sid]['folder']} have the same cancer_study_identifier '{sid}'")
        if only_ids is not None and sid not in only_ids:
            cohorts[sid] = {"folder": folder}
            continue
        files = study_files(path)
        reports = report_files(reports_root, sid, types)
        cohorts[sid] = {"folder": folder, "fingerprint": fingerprint(files, reports),
                        "files": files, "reports": reports, "samples": sample_ids(path)}
    return cohorts


def load_base(snapshots_root):
    """(base id, BUILD_INFO dict) of CURRENT, or (id or None, None, why it can't be a base)"""
    try:
        with open(os.path.join(snapshots_root, "CURRENT"), encoding="utf-8") as fh:
            cur = fh.read().split()[0]
    except (OSError, IndexError):
        return None, None, "no CURRENT snapshot yet (first build)"
    if not SAFE_ID.match(cur):
        return None, None, f"CURRENT holds '{cur}', not a snapshot id"
    snap = os.path.join(snapshots_root, cur)
    if not os.path.exists(os.path.join(snap, "READY")):
        return cur, None, f"CURRENT={cur} has no READY file"
    try:
        with open(os.path.join(snap, "BUILD_INFO.json"), encoding="utf-8") as fh:
            info = json.load(fh)
    except (OSError, ValueError):
        return cur, None, f"CURRENT={cur} has no readable BUILD_INFO.json"
    if not os.path.isdir(os.path.join(snap, "clickhouse", "metadata")):
        return cur, None, f"CURRENT={cur} has no clickhouse/ database"
    return cur, info, None


def short(items, n=6):
    items = list(items)
    return ", ".join(items[:n]) + (f" (+{len(items) - n} more)" if len(items) > n else "")


def describe(old, new):
    """one-line detail of what changed in a cohort: samples, files, reports"""
    parts = []
    s_old, s_new = set(old.get("samples", [])), set(new.get("samples", []))
    if s_new - s_old:
        parts.append(f"+{len(s_new - s_old)} sample(s): {short(sorted(s_new - s_old))}")
    if s_old - s_new:
        parts.append(f"-{len(s_old - s_new)} sample(s): {short(sorted(s_old - s_new))}")
    for key, label in (("files", "file"), ("reports", "report")):
        o, n = old.get(key, {}), new.get(key, {})
        added = sorted(set(n) - set(o))
        gone = sorted(set(o) - set(n))
        changed = sorted(k for k in set(o) & set(n) if o[k] != n[k])
        if added:
            parts.append(f"{len(added)} {label}(s) added: {short(added)}")
        if gone:
            parts.append(f"{len(gone)} {label}(s) removed: {short(gone)}")
        if changed:
            parts.append(f"{len(changed)} {label}(s) changed: {short(changed)}")
    return "; ".join(parts) or "files changed"


def cmd_plan(a):
    config = json.loads(a.config)
    if not SAFE_ID.match(a.snapshot_id) or a.snapshot_id.endswith(".partial"):
        die(f"snapshot id '{a.snapshot_id}' is not valid")
    types = load_report_types(a.report_types)
    cohorts = scan(a.studies, a.reports, types)
    if not cohorts:
        die(f"no study folder in {a.studies} - nothing to build (drop folder mounted? transfer finished?)")

    base, info, why = load_base(a.snapshots)
    base_cohorts = (info or {}).get("cohorts") or {}
    full_reason = ""
    if a.full:
        full_reason = "FULL=true was asked for"
    elif info is None:
        full_reason = why
    elif "cohorts" not in info:
        full_reason = f"CURRENT={base} was built before incremental builds (no cohort fingerprints)"
    elif info.get("config") != config:
        old_cfg = info.get("config") or {}
        diffs = sorted(k for k in set(old_cfg) | set(config) if old_cfg.get(k) != config.get(k))
        names = {"image_id": "image upgraded", "cbio_version": "cBioPortal version changed"}
        full_reason = "settings differ from CURRENT=" + str(base) + ": " + ", ".join(names.get(k, k) for k in diffs)
    mode = "full" if full_reason else "incremental"

    status = {}
    for sid, c in cohorts.items():
        if sid not in base_cohorts:
            status[sid] = "NEW"
        elif base_cohorts[sid].get("fingerprint") != c["fingerprint"]:
            status[sid] = "CHANGED"
        else:
            status[sid] = "SAME"
    removed = sorted(set(base_cohorts) - set(cohorts))
    if mode == "full":
        to_import = sorted(cohorts)
        keep = []
    else:
        to_import = sorted(s for s in cohorts if status[s] != "SAME")
        keep = sorted(s for s in cohorts if status[s] == "SAME")

    ## Summary
    print(f" Drop folder: {len(cohorts)} cohort(s) in {a.studies}")
    if info is not None:
        built = (info.get("created") or "?")[:19]
        print(f" Base:        CURRENT = {base} (built {built}, {len(base_cohorts) or len(info.get('studies', []))} cohort(s))")
    else:
        print(f" Base:        none ({why})")
    if mode == "full":
        print(f" Build:       FULL - empty database, every cohort imported. Why: {full_reason}")
    else:
        print(" Build:       INCREMENTAL - CURRENT's database + only the NEW / CHANGED cohorts re-imported")
    print()
    print(f"   {'status':<8} {'action':<8} {'study_id':<34} {'samples':>8}  detail")
    for sid in sorted(set(cohorts) | set(removed)):
        if sid in removed:
            o = base_cohorts[sid]
            print(f"   {'REMOVED':<8} {'remove':<8} {sid:<34} {len(o.get('samples', [])):>8}  "
                  f"in CURRENT, no folder in studies/ any more (was {o.get('folder', '?')})")
            continue
        c, st = cohorts[sid], status[sid]
        action = "import" if sid in to_import else "keep"
        n = len(c["samples"])
        if st == "CHANGED":
            n_old = len(base_cohorts[sid].get("samples", []))
            n_txt = f"{n}" if n == n_old else f"{n} ({n - n_old:+d})"
            detail = describe(base_cohorts[sid], c)
        elif st == "NEW":
            n_txt, detail = f"{n}", f"folder {c['folder']}, {len(c['files'])} file(s), {len(c['reports'])} report(s)"
        else:
            n_txt, detail = f"{n}", "unchanged"
        print(f"   {st:<8} {action:<8} {sid:<34} {n_txt:>8}  {detail}")
        if action == "import":                     # what the build will link: reports per type, samples without one
            counts, notes = report_summary(clinical_samples(os.path.join(a.studies, c["folder"])) or [],
                                           c["reports"], types)
            print(f"   {'':<8} {'':<8} {'':<34} {'':>8}  reports: {counts}{'; ' if notes else ''}{'; '.join(notes)}")
    n_import = sum(len(cohorts[s]["samples"]) for s in to_import)
    print()
    print(f" Import {len(to_import)} cohort(s) ({n_import} samples), keep {len(keep)}, remove {len(removed)}.")

    if mode == "incremental" and not to_import and not removed:
        print(" Nothing changed since CURRENT - no build needed.")
        return EXIT_NOTHING

    plan = {
        "plan_version": PLAN_VERSION,
        "snapshot_id": a.snapshot_id,
        "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "mode": mode,
        "full_reason": full_reason,
        "base_snapshot": base if mode == "incremental" else None,
        "config": config,
        "import": to_import,
        "remove": removed if mode == "incremental" else [],
        "keep": keep,
        "dropped": removed,
        "status": status,
        "cohorts": cohorts,
    }
    tmp = a.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(plan, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, a.out)
    print(f" Plan: {a.out}")
    if removed:
        print(f"\n !!! {len(removed)} cohort(s) would DISAPPEAR from the new snapshot: {', '.join(removed)}")
        print(" !!! (every folder in studies/ is a cohort - was a folder deleted or renamed by mistake?)")
        return EXIT_REMOVALS
    return EXIT_BUILD


def load_plan(path):
    try:
        with open(path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, ValueError) as e:
        die(f"cannot read the plan {path}: {e}")
    if plan.get("plan_version") != PLAN_VERSION:
        die(f"{path}: plan version {plan.get('plan_version')} - made by another image, run the check again")
    return plan


def cmd_verify(a):
    plan = load_plan(a.plan)
    problems = []
    if plan["snapshot_id"] != a.snapshot_id:
        problems.append(f"the plan is for snapshot {plan['snapshot_id']}, this build is {a.snapshot_id}")
    config = json.loads(a.config)
    if plan["config"] != config:
        diffs = sorted(k for k in set(plan["config"]) | set(config) if plan["config"].get(k) != config.get(k))
        problems.append("settings changed since the check: " + ", ".join(diffs))
    ## only the cohorts to import are read from the drop folder; kept ones come from the base snapshot
    now = scan(a.studies, a.reports, load_report_types(a.report_types), only_ids=set(plan["import"]))
    for sid in plan["import"]:
        want = plan["cohorts"][sid]
        if sid not in now:
            problems.append(f"{sid}: its folder ({want['folder']}) is gone")
        elif now[sid]["folder"] != want["folder"]:
            problems.append(f"{sid}: now in folder {now[sid]['folder']}, the plan says {want['folder']}")
        elif now[sid]["fingerprint"] != want["fingerprint"]:
            problems.append(f"{sid}: files changed since the check ({describe(want, now[sid])})")
    if problems:
        print("The drop folder or the settings changed since the check:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        sys.exit(EXIT_ERROR)
    print(f"Plan {plan['snapshot_id']} still matches: {len(plan['import'])} cohort(s) to import unchanged since the check")
    return 0


def cmd_lines(a):
    plan = load_plan(a.plan)
    print(f"mode {plan['mode']}")
    print(f"snapshot {plan['snapshot_id']}")
    if plan.get("base_snapshot"):
        print(f"base {plan['base_snapshot']}")
    for sid in plan["remove"]:
        print(f"remove {sid}")
    for sid in plan["import"]:
        print(f"import {sid} {plan['cohorts'][sid]['folder']}")
    for sid in plan["keep"]:
        print(f"keep {sid}")
    return 0


def report_url(base, study_id, name):
    """the URL written into the study for one report. PDFs get a trailing /view: cBioPortal's resource tab takes the
    text after the last '.' of the URL path as the file type and, for 'pdf', frames Google's Docs viewer instead of
    the URL (Google would fetch the report: no login there, and patient data must not leave). With /view the type
    reads 'pdf/view', the tab frames the gatekeeper directly and the browser's own PDF viewer shows it."""
    url = f"{base}/{quote(study_id, safe='')}/{quote(name, safe='')}"
    return url + "/view" if name.endswith(".pdf") else url


def cmd_types_digest(a):
    print(types_digest(a.report_types))
    return 0


def cmd_resources(a):
    """reports/<study_id>/ -> meta/data_resource_{definition,sample}.txt in the staging copy (never the study folder)"""
    types = load_report_types(a.report_types)
    samples = clinical_samples(a.study_dir)
    if samples is None:
        die("no clinical sample file (meta with datatype: SAMPLE_ATTRIBUTES, PATIENT_ID + SAMPLE_ID columns)"
            " - cannot link reports to samples")
    names, bad, other = set(), [], []
    for f in sorted(os.listdir(a.reports_dir)):
        p = os.path.join(a.reports_dir, f)
        if f.startswith(".") or not os.path.isfile(p):
            continue
        if not report_type(f, types):
            other.append(f)
        elif REPORT_FILE_RE.match(f) and os.path.dirname(os.path.realpath(p)) == os.path.realpath(a.reports_dir):
            names.add(f)
        else:
            bad.append(f)

    print(f"Reports in {a.reports_dir}: {len(names)}; samples in the study: {len(samples)}")
    by_type = type_names(names, types)
    defs, rows_all = [], []
    for t in types:
        files = by_type[t["RESOURCE_ID"]]
        if not files:
            print(f"  {t['DISPLAY_NAME']} (*{t['SUFFIX']}): none - no tab")
            continue
        rows, missing = match_reports(samples, files, t)
        used = Counter(r[2] for r in rows)
        print(f"  {t['DISPLAY_NAME']} (*{t['SUFFIX']}): {len(files)} file(s), linked to {len(rows)} sample(s)")
        if missing:
            print(f"    samples without a report ({len(missing)}): {', '.join(missing)}")
        unused = sorted(files - set(used))
        if unused:
            print(f"    reports matching no SAMPLE_ID / PATIENT_ID ({len(unused)}): {', '.join(unused)}")
        shared = sorted(f for f, n in used.items() if n > 1)
        if shared:
            print(f"    WARNING: reports linked to more than one sample (PATIENT_ID match): {', '.join(shared)}")
        if rows:
            defs.append(t)
            rows_all += [(p, s, t["RESOURCE_ID"], f) for p, s, f in rows]
    if bad:
        print(f"  WARNING: not linked - name not served (letters, digits, _ . - only) or symlink out of the folder:"
              f" {', '.join(bad)}")
    if other:
        print(f"  ignored (no report type in {a.report_types}): {short(other)}")
    if not rows_all:
        return EXIT_NOTHING

    def write(fname, text):
        with open(os.path.join(a.stage, fname), "x", encoding="utf-8") as fh:    # "x": never overwrite a study file
            fh.write(text)

    sid, base = a.study_id, a.base_url.rstrip("/")
    write("meta_resource_definition.txt",
          f"cancer_study_identifier: {sid}\nresource_type: DEFINITION\ndata_filename: data_resource_definition.txt\n")
    write("data_resource_definition.txt",
          "RESOURCE_ID\tDISPLAY_NAME\tRESOURCE_TYPE\tDESCRIPTION\tOPEN_BY_DEFAULT\tPRIORITY\n"
          + "".join(f"{t['RESOURCE_ID']}\t{t['DISPLAY_NAME']}\tSAMPLE\t{t['DESCRIPTION']}\t{t['OPEN_BY_DEFAULT']}"
                    f"\t{t['PRIORITY']}\n" for t in defs))
    write("meta_resource_sample.txt",
          f"cancer_study_identifier: {sid}\nresource_type: SAMPLE\ndata_filename: data_resource_sample.txt\n")
    write("data_resource_sample.txt",
          "PATIENT_ID\tSAMPLE_ID\tRESOURCE_ID\tURL\n"
          + "".join(f"{p}\t{s}\t{rid}\t{report_url(base, sid, f)}\n" for p, s, rid, f in rows_all))
    print(f"Resource files written to {a.stage}/ ({', '.join(t['DISPLAY_NAME'] for t in defs)}; the study folder is unchanged)")
    return 0


def cmd_snapshot_reports(a):
    """every cohort's reports -> <out>/<study_id>/. A file unchanged from the link source (same name + sha256 as
    recorded in its BUILD_INFO) is HARD-LINKED from it (snapshots never change once READY), the rest is copied from
    the drop folder and checked against the plan. Link source: the plan's base snapshot (incremental), else
    CURRENT (full build), if any."""
    plan = load_plan(a.plan)
    src_id = plan.get("base_snapshot")
    if src_id:
        try:
            with open(os.path.join(a.snapshots, src_id, "BUILD_INFO.json"), encoding="utf-8") as fh:
                src_cohorts = json.load(fh).get("cohorts") or {}
        except (OSError, ValueError) as e:
            die(f"base snapshot {src_id}: cannot read BUILD_INFO.json ({e})")
    else:
        src_id, info, _ = load_base(a.snapshots)
        src_cohorts = (info or {}).get("cohorts") or {}
    os.makedirs(a.out, exist_ok=True)
    total_link = total_copy = 0
    for sid in sorted(plan["import"]) + sorted(plan["keep"]):
        want = plan["cohorts"][sid].get("reports") or {}
        if not want:
            continue
        dst_dir = os.path.join(a.out, sid)
        os.makedirs(dst_dir)
        old = src_cohorts.get(sid, {}).get("reports") or {}
        n_link = n_copy = 0
        for name, sha in sorted(want.items()):
            dst = os.path.join(dst_dir, name)
            src = os.path.join(a.snapshots, src_id, "reports", sid, name) if src_id else ""
            if src and old.get(name) == sha and os.path.isfile(src):
                try:
                    os.link(src, dst)
                    n_link += 1
                    continue
                except OSError:
                    shutil.copy2(src, dst)          # e.g. a file system without hard links
            elif sid in plan["keep"]:
                die(f"{sid} is kept from {src_id}, but {src or 'its report'} {name} is missing there")
            else:
                shutil.copy2(os.path.join(a.reports, sid, name), dst)
            if sha256_file(dst) != sha:
                die(f"reports/{sid}/{name} changed during the build - run the check again")
            n_copy += 1
        total_link += n_link
        total_copy += n_copy
        print(f"reports/{sid}: {len(want)} file(s) ({n_link} hard-linked from {src_id or 'no snapshot'}, {n_copy} copied)")
    print(f"Reports: {total_link} hard-linked, {total_copy} copied")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("plan")
    pl.add_argument("--studies", required=True)
    pl.add_argument("--reports", required=True)
    pl.add_argument("--report-types", required=True)
    pl.add_argument("--snapshots", required=True)
    pl.add_argument("--config", required=True, help="JSON of the settings a snapshot depends on")
    pl.add_argument("--snapshot-id", required=True)
    pl.add_argument("--out", required=True)
    pl.add_argument("--full", action="store_true")
    ve = sub.add_parser("verify")
    ve.add_argument("--plan", required=True)
    ve.add_argument("--studies", required=True)
    ve.add_argument("--reports", required=True)
    ve.add_argument("--report-types", required=True)
    ve.add_argument("--config", required=True)
    ve.add_argument("--snapshot-id", required=True)
    li = sub.add_parser("lines")
    li.add_argument("--plan", required=True)
    td = sub.add_parser("types-digest")
    td.add_argument("--report-types", required=True)
    rs = sub.add_parser("resources")
    rs.add_argument("--study-dir", required=True)
    rs.add_argument("--stage", required=True)
    rs.add_argument("--reports-dir", required=True)
    rs.add_argument("--study-id", required=True)
    rs.add_argument("--base-url", required=True)
    rs.add_argument("--report-types", required=True)
    sr = sub.add_parser("snapshot-reports")
    sr.add_argument("--plan", required=True)
    sr.add_argument("--reports", required=True)
    sr.add_argument("--snapshots", required=True)
    sr.add_argument("--out", required=True)
    a = p.parse_args()
    sys.exit({"plan": cmd_plan, "verify": cmd_verify, "lines": cmd_lines, "types-digest": cmd_types_digest,
              "resources": cmd_resources, "snapshot-reports": cmd_snapshot_reports}[a.cmd](a))


if __name__ == "__main__":
    main()
