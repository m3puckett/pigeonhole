#!/bin/bash
# seed-seen.sh — build or extend $SCANS/.seen, the content-hash index that
# ocr-one.sh uses to recognise re-sent copies of documents it has already filed.
# Hashes every PDF in $SCANS/originals (the untouched input of each filed
# document), so scans processed before the index existed count too. Safe to
# re-run at any time, including while the watcher is busy.
set -u

SCANS=/srv/nas/public/scans
[[ -f /etc/pigeonhole.conf ]] && source /etc/pigeonhole.conf

ORIG=$SCANS/originals
NAMES=$SCANS/.names.log
SEEN=$SCANS/.seen
touch "$SEEN"

added=0 known=0
while IFS= read -r -d '' f; do
  hash=$(sha256sum "$f" | cut -c1-64)
  name=$(basename "$f")
  # "X (scanned 2025-10-08 1634) (2).pdf" was X.pdf when it arrived
  plain=$(sed -E 's/ \(scanned [^)]*\)( \([0-9]+\))?(\.[A-Za-z]+)$/\2/' <<< "$name")
  filed=$(awk -F'\t' -v n="$plain" '$2==n {print $3; exit}' "$NAMES" 2>/dev/null)
  exec 9>>"$SEEN.lock"; flock 9
  if grep -q "^$hash"$'\t' "$SEEN"; then
    ((known++))
  else
    printf '%s\t%s\t%s\n' "$hash" "$plain" "${filed:-?}" >> "$SEEN"
    ((added++))
  fi
  exec 9>&-
done < <(find "$ORIG" -type f \( -iname '*.pdf' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -size +0 -print0)

echo "seed-seen: $added added, $known already indexed, $(wc -l < "$SEEN") entries in $SEEN"
