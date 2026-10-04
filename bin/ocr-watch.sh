#!/bin/bash
# ocr-watch.sh — watch $SCANS/inbox and hand new PDFs and scan images (jpg, jpeg,
# png) to ocr-one.sh, PAR at a time.
# Part of pigeonhole. Runs as a systemd service (ocr-watch.service).
set -u

source "$(dirname "$(readlink -f "$0")")/pigeonhole-lib.sh"

mkdir -p "$IN" "$WORK" "$SCANS"/{originals,failed} "$DOCS"

# ---- recover from a restart -----------------------------------------------
# Stopping the service kills workers mid-document. Each had claimed its file
# as $WORK/<pid>-<name>.pdf; for every one whose worker is gone, drop the
# half-made OCR output and its "(processing)" entry in $SEEN, and put the file
# back in the inbox so it is simply done again. Files held by a live
# ocr-one.sh (one run by hand, say) are left alone.
recovered=0
recover() {
  local f base pid name hash
  for f in "$WORK"/[0-9]*-*.*; do
    [[ -f "$f" ]] || continue
    base=${f##*/}; pid=${base%%-*}; name=${base#*-}
    [[ $pid =~ ^[0-9]+$ ]] || continue
    [[ -r /proc/$pid/cmdline ]] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q ocr-one && continue
    rm -f "$WORK/ocr-${base%.*}.pdf" "$WORK/raster-$pid"-*.png "$WORK/raster-$pid.pdf"
    if [[ -s "$SEEN" ]]; then
      hash=$(sha256sum "$f" | cut -c1-64)
      flock "$SEEN.lock" awk -i inplace -F'\t' -v h="$hash" '$1!=h' "$SEEN"
    fi
    mv -n "$f" "$IN/$name" && { log "RECOVER $name -> inbox (worker $pid gone)"; ((recovered++)); }
  done
}

# One sweep at a time. Only non-empty files whose inode has been untouched for
# 5s, so nothing mid-upload. ctime rather than mtime: Finder copying onto the
# share creates every file empty with the source's old mtime and fills them in
# afterwards, so an mtime test passes before any data has arrived. Each worker
# claims its file by moving it out of the inbox, so a duplicate event finds
# nothing to do.
# The model has to be there before anything is claimed. Otherwise a MODEL
# that isn't pulled on the Ollama host, or the host being down, sends every
# document straight to _Unsorted at a few seconds each.
model_ready() {
  curl -s --max-time 10 "${OLLAMA%/api/generate}/api/tags" |
    jq -e --arg m "$MODEL" '.models[]?.name | select(. == $m or . == $m + ":latest")' >/dev/null 2>&1
}
held=0
sweep() {
  until model_ready; do
    (( held++ )) || log "model $MODEL is not available at $OLLAMA; holding the inbox until it is"
    sleep 60
  done
  (( held )) && log "model $MODEL is available again, resuming"
  held=0
  flock "$WORK/sweep.lock" bash -c "
    find '$IN' -maxdepth 1 -type f \\( -iname '*.pdf' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \\) \
         -size +0 ! -newerct '-5 seconds' -print0 |
    xargs -0 -r -P $PAR -n 1 /usr/local/bin/ocr-one.sh"
}

recover
# Recovered files were moved before inotifywait is listening, and the sweep
# ignores anything touched in the last 5s, so give them time to count.
(( recovered )) && sleep 6
log "watching $IN (PAR=$PAR, model $MODEL at $OLLAMA)"
sweep                                   # anything waiting at startup
inotifywait -m -q -e close_write -e moved_to "$IN" |
while read -r _; do sleep 5; sweep; done
