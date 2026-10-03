#!/bin/bash
# merge-issuer.sh — fold one or more issuer folders into another.
#
#   merge-issuer.sh "Weaver Brake and Tire" "Weaver Brake TEXT Tire Inc" -- "Weaver Brake & Tire Inc"
#
# Every PDF in the FROM folders moves into TO (never overwriting; a clash gets
# " (merged)" appended), each emptied FROM folder is removed, and an alias
# FROM=TO is appended to $ALIASES so the model's next use of that spelling
# lands in TO. Folder names are relative to $DOCS or absolute.
set -u

SCANS=/srv/nas/public/scans
DOCS=/srv/nas/public/documents
[[ -f /etc/pigeonhole.conf ]] && source /etc/pigeonhole.conf
ALIASES=${ALIASES:-$DOCS/.issuers}

froms=()
while (( $# )) && [[ $1 != -- ]]; do froms+=("$1"); shift; done
[[ ${1:-} == -- && -n ${2:-} && ${#froms[@]} -gt 0 ]] || { echo "usage: $0 FROM... -- TO" >&2; exit 1; }
to=$2
[[ $to = /* ]] || to="$DOCS/$to"
mkdir -p "$to"

for from in "${froms[@]}"; do
  [[ $from = /* ]] || from="$DOCS/$from"
  [[ -d "$from" ]] || { echo "skip: no folder $from" >&2; continue; }
  [[ "$(realpath "$from")" == "$(realpath "$to")" ]] && { echo "skip: $from is the target" >&2; continue; }
  n=0
  for f in "$from"/*; do
    [[ -f "$f" ]] || continue
    dst="$to/$(basename "$f")"
    [[ -e "$dst" ]] && dst="$to/$(basename "${f%.*}") (merged).${f##*.}"
    mv -n "$f" "$dst" && ((n++))
  done
  rmdir "$from" 2>/dev/null || echo "note: $from not empty, left in place" >&2
  printf '%s=%s\n' "$(basename "$from")" "$(basename "$to")" >> "$ALIASES"
  echo "merged $n file(s): $(basename "$from") -> $(basename "$to")"
done
