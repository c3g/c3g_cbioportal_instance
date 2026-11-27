#!/usr/bin/env python3
################################################################################
### c3g_cbioportal_instance - which cohorts a build must (re)import (README "Incremental builds")
### A cohort = one folder in <shared>/studies/ = one cBioPortal study (its cancer_study_identifier),
### plus its PCGR reports in <shared>/reports/<cancer_study_identifier>/.
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
### Python standard library only (runs inside the image).
################################################################################
import argparse
import datetime
import hashlib
import json
import os
import re
import sys

SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
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


def report_files(reports_root, study_id):
    """file name -> sha256 of reports/<study_id>/*.html (what the build links and copies)"""
    d = os.path.join(reports_root, study_id)
    if not os.path.isdir(d):
        return {}
    return {name: sha256_file(os.path.join(d, name)) for name in sorted(os.listdir(d))
            if name.endswith(".html") and not name.startswith(".") and os.path.isfile(os.path.join(d, name))}


def sample_ids(folder):
    """SAMPLE_IDs of the study's sample attribute file (for the summary only; the fingerprint decides)"""
    data_file = "data_clinical_sample.txt"
    for name in sorted(os.listdir(folder)):
        if name.startswith("meta_") and name.endswith(".txt"):
            meta = os.path.join(folder, name)
            if meta_value(meta, "datatype").upper() == "SAMPLE_ATTRIBUTES":
                data_file = meta_value(meta, "data_filename") or data_file
                break
    path = os.path.join(folder, data_file)
    if not os.path.isfile(path):
        return []
    ids, col = set(), None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            fields = [f.strip() for f in line.rstrip("\r\n").split("\t")]
            if col is None:
                header = [f.upper() for f in fields]
                if "SAMPLE_ID" not in header:
                    return []
                col = header.index("SAMPLE_ID")
                continue
            if len(fields) > col and fields[col]:
                ids.add(fields[col])
    return sorted(ids)


def fingerprint(files, reports):
    blob = json.dumps({"files": files, "reports": reports}, sort_keys=True).encode()
    return hashlib.sha256(blob).hexdigest()


def scan(studies_root, reports_root, only_ids=None):
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
        reports = report_files(reports_root, sid)
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
    cohorts = scan(a.studies, a.reports)
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
    now = scan(a.studies, a.reports, only_ids=set(plan["import"]))
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


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("plan")
    pl.add_argument("--studies", required=True)
    pl.add_argument("--reports", required=True)
    pl.add_argument("--snapshots", required=True)
    pl.add_argument("--config", required=True, help="JSON of the settings a snapshot depends on")
    pl.add_argument("--snapshot-id", required=True)
    pl.add_argument("--out", required=True)
    pl.add_argument("--full", action="store_true")
    ve = sub.add_parser("verify")
    ve.add_argument("--plan", required=True)
    ve.add_argument("--studies", required=True)
    ve.add_argument("--reports", required=True)
    ve.add_argument("--config", required=True)
    ve.add_argument("--snapshot-id", required=True)
    li = sub.add_parser("lines")
    li.add_argument("--plan", required=True)
    a = p.parse_args()
    sys.exit({"plan": cmd_plan, "verify": cmd_verify, "lines": cmd_lines}[a.cmd](a))


if __name__ == "__main__":
    main()
