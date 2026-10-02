#!/bin/bash
# ocr-watch.sh — watch $SCANS/inbox and hand new PDFs to ocr-one.sh, PAR at a time.
# Part of pigeonhole. Runs as a systemd service (ocr-watch.service).
set -u

# ---- defaults (override in /etc/pigeonhole.conf) --------------------------
SCANS=/srv/nas/public/scans
DOCS=/srv/nas/public/documents
PAR=4                           # documents processed concurrently
[[ -f /etc/pigeonhole.conf ]] && source /etc/pigeonhole.conf

IN=$SCANS/inbox
WORK=$SCANS/.work
mkdir -p "$IN" "$WORK" "$SCANS"/{originals,failed} "$DOCS"

# One sweep at a time. Only files untouched for 5s, so nothing mid-upload.
# Each worker claims its file by moving it out of the inbox, so a duplicate
# event from the scanner finds nothing to do.
sweep() {
  flock "$WORK/sweep.lock" bash -c "
    find '$IN' -maxdepth 1 -type f -iname '*.pdf' ! -newermt '-5 seconds' -print0 |
    xargs -0 -r -P $PAR -n 1 /usr/local/bin/ocr-one.sh"
}

sweep                                   # anything waiting at startup
inotifywait -m -q -e close_write -e moved_to "$IN" |
while read -r _; do sleep 5; sweep; done
