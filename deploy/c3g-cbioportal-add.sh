#!/bin/bash
################################################################################
### c3g_cbioportal_instance - put one study + its reports into the drop folder (README "Step by step")
### One command instead of the manual copies:
###   - the study folder           -> <shared>/studies/<folder>/                    (replaced whole: a mirror)
###   - every report found under the given folders (PCGR, ORANGE, ...: config/report_types.tsv), searched
###     recursively, so the pipeline output folders can be given as they are (e.g. <id>/orange/<id>.orange.pdf)
###                                -> <shared>/reports/<cancer_study_identifier>/   (flat; holds exactly those
###                                   reports afterwards, so reports of dropped samples go away)
### SHARED = the drop folder: a local path (on the VM) or user@host:/path (rsync over ssh, e.g. from the HPC where the
### pipeline ran). Symlinks are copied as the files they point to (the drop folder must not hold symlinks).
### Other studies are never touched; removing a study stays manual (delete its folder, README "Step by step").
### Shows what it will do and asks first (--yes = no question). Linking reports to samples (SAMPLE_ID / PATIENT_ID,
### with or without -T) is done and shown by the check; this script only copies.
### Then: the check + build (deploy/c3g-cbioportal-check.sh, on the VM). CHECK=true runs it right away (local SHARED).
### bash 3.2 compatible (macOS) - needs rsync (and ssh for a remote SHARED).
################################################################################
set -euo pipefail

## CHANGE HERE ##
SHARED=${SHARED:-/Path/to/YOUR/cbioportal_drop}             ## CHANGE HERE - ASK ## drop folder: /path or user@host:/path
REPO=$(cd "$(dirname "$0")/.." && pwd)
REPORT_TYPES=${REPORT_TYPES:-${REPO}/config/report_types.tsv}   # same file as in the image
CHECK=${CHECK:-false}                                        # true = run deploy/c3g-cbioportal-check.sh afterwards

DIVIDER="=================================="; DIVIDER=$DIVIDER$DIVIDER
SAFE_ID_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
die() { echo -e "ERROR: $*" >&2; exit 1; }
usage() {
  echo "Usage: SHARED=<drop folder | user@host:/drop/folder> $0 [--yes] <study_folder> [<report_folder> ...]"
  echo "  <report_folder>: searched recursively for the report types of ${REPORT_TYPES}."
  echo "                   None given = <shared>/reports/<study_id>/ is left as it is."
}

YES=""
if [ "${1:-}" == "--yes" ]; then YES=--yes; shift; fi
[ $# -ge 1 ] || { usage; exit 1; }
STUDY=${1%/}; shift
[ -d "${STUDY}" ] || die "${STUDY} is not a folder"
[ -f "${STUDY}/meta_study.txt" ] || die "${STUDY} has no meta_study.txt - give the pipeline's cBioPortal study folder"
STUDY=$(cd "${STUDY}" && pwd)
FOLDER=$(basename "${STUDY}")
SID=$(sed -n 's/^cancer_study_identifier:[[:space:]]*//p' "${STUDY}/meta_study.txt" | tr -d '[:space:]')
[[ "${FOLDER}" =~ ${SAFE_ID_RE} ]] || die "folder name '${FOLDER}': letters, digits, _ . - only (and not starting with _ . -)"
[ -n "${SID}" ] || die "no cancer_study_identifier in ${STUDY}/meta_study.txt"
[[ "${SID}" =~ ${SAFE_ID_RE} ]] || die "cancer_study_identifier '${SID}': letters, digits, _ . - only"
[ -r "${REPORT_TYPES}" ] || die "${REPORT_TYPES} not found (REPORT_TYPES)"
for d in "$@"; do [ -d "${d}" ] || die "report folder ${d} not found"; done
command -v rsync > /dev/null || die "rsync not found"

## Drop folder: local or remote (user@host:/path)
REMOTE=0; RHOST=""; RPATH=${SHARED}
case "${SHARED}" in
  /*|./*|../*) ;;
  *:*) REMOTE=1; RHOST=${SHARED%%:*}; RPATH=${SHARED#*:} ;;
esac
on_drop() {   # on_drop <shell test / command on paths under the drop folder, already quoted>
  if [ "${REMOTE}" -eq 1 ]; then ssh "${RHOST}" "$1"; else bash -c "$1"; fi
}
q() { printf '%q' "${RPATH}/$1"; }
on_drop "test -d $(q studies) && test -d $(q reports)" \
  || die "${SHARED}/studies or ${SHARED}/reports not found (SHARED = the drop folder: studies/ reports/ snapshots/)"

## Reports: every file with a report type's suffix under the given folders, flat, as symlinks in a temp folder
TMP=$(mktemp -d "${TMPDIR:-/tmp}/c3g-cbioportal-add.XXXXXX")
trap 'rm -rf "${TMP}"' EXIT
mkdir "${TMP}/reports"
N_REPORTS=0; COUNTS=""; DUPS=""
if [ $# -gt 0 ]; then
  while IFS=$'\t' read -r suffix label; do
    n=0
    while IFS= read -r -d '' f; do
      b=$(basename "${f}")
      case "${b}" in .*) continue ;; esac
      if [ -L "${TMP}/reports/${b}" ]; then
        [ "${f}" -ef "${TMP}/reports/${b}" ] || DUPS="${DUPS}  ${b}: ${f} and $(readlink "${TMP}/reports/${b}")\n"
        continue
      fi
      ln -s "$(cd "$(dirname "${f}")" && pwd)/${b}" "${TMP}/reports/${b}"
      n=$((n + 1))
    done < <(find -L "$@" -type f -name "*${suffix}" -print0 2>/dev/null)
    N_REPORTS=$((N_REPORTS + n))
    COUNTS="${COUNTS}${COUNTS:+, }${label} ${n}"
  done < <(awk -F'\t' '!/^#/ && NF >= 3 && $1 != "RESOURCE_ID" {l = $3; sub(/ [Rr]eport$/, "", l); print $2 "\t" l}' "${REPORT_TYPES}")
  [ -z "${DUPS}" ] || die "two different reports with the same file name (they go into one flat folder):\n${DUPS}"
  [ "${N_REPORTS}" -gt 0 ] || die "no report (${REPORT_TYPES}) found under: $* - nothing copied.
       Leave the report folders out to keep <shared>/reports/${SID}/ as it is."
fi

## What it will do
if on_drop "test -d $(q "studies/${FOLDER}")"; then st_now="REPLACED (mirror: files not in ${STUDY} are deleted there)"; else st_now="NEW"; fi
if [ $# -eq 0 ]; then
  rp_now="left as it is (no report folder given)"
else
  old=$(on_drop "ls -A $(q "reports/${SID}") 2>/dev/null | wc -l" | tr -d '[:space:]')
  rp_now="${N_REPORTS} report(s): ${COUNTS}$([ "${old:-0}" -eq 0 ] || echo " - REPLACES the ${old} file(s) there")"
fi
echo -e "\n ${DIVIDER} \n Study ${SID} (folder ${FOLDER}) -> ${SHARED} \n"
echo "   studies/${FOLDER}/   ${st_now}"
echo "   reports/${SID}/   ${rp_now}"
echo "   Which sample each report is linked to (SAMPLE_ID / PATIENT_ID, with or without -T): shown by the check."
echo
if [ "${YES}" != "--yes" ]; then
  [ -t 0 ] || die "no terminal to ask for confirmation - run it in a terminal, or pass --yes"
  read -r -p "Copy? [y/N] " ans || ans=""
  [[ "${ans}" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Nothing copied"; exit 1; }
fi

## Copy (-rLt: files, folders, times; symlinks copied as the files they point to; permissions NOT copied, so
## setgid / group-only modes of HPC folders never reach the drop folder; --delete only inside these two folders)
echo -e "\n ${DIVIDER} \n Copy studies/${FOLDER}/ \n"
rsync -rLt --delete --exclude '.*' "${STUDY}/" "${SHARED}/studies/${FOLDER}/"
if [ $# -gt 0 ]; then
  echo -e "\n ${DIVIDER} \n Copy reports/${SID}/ (${COUNTS}) \n"
  rsync -rLt --delete "${TMP}/reports/" "${SHARED}/reports/${SID}/"
fi

echo -e "\n ${DIVIDER} \n Done: ${SID} is in the drop folder."
echo " Next, on the VM inside tmux (shows NEW / CHANGED + reports per type, asks, builds; PROMOTE=true promotes after):"
echo "   SHARED=${RPATH} ./deploy/c3g-cbioportal-check.sh"
echo " A NEW study is hidden until it is in OPA's c3g_cbioportal/data.json (README 'Step by step', step 5)."
if [ "${CHECK}" == "true" ]; then
  [ "${REMOTE}" -eq 0 ] || die "CHECK=true needs a local SHARED (run the check on the VM)"
  exec env SHARED="${SHARED}" "${REPO}/deploy/c3g-cbioportal-check.sh"
fi


### How to run: ###
# (from the repo root; <study_folder> = the pipeline's cBioPortal study folder, <oncoanalyser_output> /
#  <pcgr_output> = folders holding the reports anywhere below them)
# SHARED=/Path/to/YOUR/cbioportal_drop ./deploy/c3g-cbioportal-add.sh <study_folder> <oncoanalyser_output> <pcgr_output>
# SHARED=genome@<VM>:/Path/to/YOUR/cbioportal_drop ./deploy/c3g-cbioportal-add.sh ...    # from another machine (ssh)
# SHARED=... CHECK=true ./deploy/c3g-cbioportal-add.sh ...    # + the check / build right after (on the VM, in tmux)
# SHARED=... ./deploy/c3g-cbioportal-add.sh <study_folder>    # study only, reports/<study_id>/ left as it is
# Several studies: while read -r s; do SHARED=... ./deploy/c3g-cbioportal-add.sh --yes "$s" <report_folder>; done < studies.txt
