#!/bin/bash
# reprocess.sh — send already-filed documents through pigeonhole again.
#
#   reprocess.sh "$DOCS/MetLife/2025-10-08 - Explanation of Benefits.pdf" ...
#
# For each filed PDF: the filed copy is moved to $SCANS/.misfiled/ (nothing is
# deleted), its entry is removed from the duplicate index, and the untouched
# original from $SCANS/originals/ is put back in the inbox under its arrival
# name, so the watcher treats it as new. Use after fixing a misfile or after
# upgrading pigeonhole. Set INBOX=/some/dir to stage somewhere else instead.
set -u

SCANS=/srv/nas/public/scans
DOCS=/srv/nas/public/documents
[[ -f /etc/pigeonhole.conf ]] && source /etc/pigeonhole.conf

ORIG=$SCANS/originals
NAMES=$SCANS/.names.log
SEEN=$SCANS/.seen
MISFILED=$SCANS/.misfiled
INBOX=${INBOX:-$SCANS/inbox}
mkdir -p "$MISFILED" "$INBOX"

forget() {                      # forget HASH -> drop it from the duplicate index
  [[ -s "$SEEN" ]] || return 0
  flock "$SEEN.lock" awk -i inplace -F'\t' -v h="$1" '$1!=h' "$SEEN"
}

status=0
for filed in "$@"; do
  rel=${filed#"$DOCS"/}
  arrival=$(awk -F'\t' -v p="$rel" '$3==p {n=$2} END {print n}' "$NAMES")
  if [[ -z "$arrival" ]]; then
    echo "skip: $rel is not in $NAMES" >&2; status=1; continue
  fi
  stem=${arrival%.*}
  mapfile -t origs < <(find "$ORIG" -maxdepth 1 -type f \( -name "$stem.pdf" -o -name "$stem (scanned *" \) | sort)
  if (( ${#origs[@]} == 0 )); then
    echo "skip: no original for $rel ($arrival)" >&2; status=1; continue
  fi

  # park the filed copy, never overwriting
  dst="$MISFILED/${rel//\//_}"
  [[ -e "$dst" ]] && dst="$MISFILED/$(date +%s)-${rel//\//_}"
  mv -n "$filed" "$dst" || { echo "skip: could not move $filed" >&2; status=1; continue; }

  # every stored copy goes back; duplicates among them get parked by the dup check
  for o in "${origs[@]}"; do
    forget "$(sha256sum "$o" | cut -c1-64)"
    target="$INBOX/$arrival"
    [[ -e "$target" ]] && target="$INBOX/$stem (reprocess $(date +%H%M%S)-$RANDOM).pdf"
    mv -n "$o" "$target"
  done
  echo "requeued $arrival (${#origs[@]} original(s)); old copy in ${dst#"$SCANS"/}"
done
exit $status
