#!/bin/bash
# reclassify.sh — name already-filed documents again with the current model,
# prompt and alias file, and move the ones that come out differently.
#
#   reclassify.sh [--dry-run] PATH...      files, globs, or issuer folders
#   reclassify.sh [--dry-run] --all        every document under $DOCS
#
# --all without --dry-run asks for confirmation (pass --yes to skip it).
# --folder-only moves a document only when the issuer folder changes, and
# leaves names alone; without it any change in date, type or recipient is a
# rename too.
#
# The filed PDF already carries its OCR text, so this is only a model call per
# document (seconds), not a new OCR. A document that cannot be named (model
# finds no issuer, or the text is unreadable) is left where it is and
# reported. Moves never overwrite. Afterwards every empty issuer folder under
# $DOCS is removed. Each move is appended to $NAMES so reprocess.sh can still
# trace the document to its original. --dry-run prints what would happen.
set -u
source "$(dirname "$(readlink -f "$0")")/pigeonhole-lib.sh"

dry=0 all=0 yes=0 folder_only=0 args=()
for a in "$@"; do
  case $a in
    --dry-run|-n)  dry=1 ;;
    --all)         all=1 ;;
    --yes|-y)      yes=1 ;;
    --folder-only) folder_only=1 ;;
    -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    *)            args+=("$a") ;;
  esac
done
(( all || ${#args[@]} )) || { sed -n '2,15p' "$0"; exit 1; }
mkdir -p "$WORK"                        # ollama.lock lives there

# ---- collect the documents -------------------------------------------------
files=()
add_dir() { while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$1" -maxdepth 1 -type f -iname '*.pdf' -print0 | sort -z); }
if (( all )); then
  while IFS= read -r -d '' d; do add_dir "$d"; done < <(find "$DOCS" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | sort -z)
fi
for a in "${args[@]}"; do
  [[ $a = /* ]] || a="$DOCS/$a"
  if   [[ -d $a ]]; then add_dir "$a"
  elif [[ -f $a ]]; then files+=("$a")
  else echo "skip: no such file or folder: $a" >&2
  fi
done
(( ${#files[@]} )) || { echo "nothing to do"; exit 0; }
echo "${#files[@]} document(s)$( ((dry)) && echo ' (dry run)')"
if (( all && ! dry && ! yes )); then
  [[ -t 0 ]] || { echo "refusing to reclassify the whole tree non-interactively without --yes" >&2; exit 1; }
  read -r -p "Move files across the whole tree as the model decides? Run with --dry-run first. [y/N] " ans
  [[ $ans == [yY]* ]] || exit 1
fi

# ---- one at a time -----------------------------------------------------------
moved=0 same=0 left=0
for f in "${files[@]}"; do
  rel=${f#"$DOCS"/}
  base=$(basename "$f"); stem=${base%.*}
  # the leading date in the filed name is the scan or document date we had
  [[ $stem =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] && scandate=${BASH_REMATCH[1]} || scandate=$(date -r "$f" +%F)
  scanned="$scandate $(date -r "$f" +%H%M)"

  classify "$f" 2>/tmp/reclassify.$$; rc=$?
  why=$(tail -n1 /tmp/reclassify.$$ | sed 's/^naming: //')
  if (( rc == 2 )); then
    echo "STOP  model unavailable: $why" >&2; rm -f /tmp/reclassify.$$; exit 2
  elif (( rc != 0 )); then
    echo "LEFT  $rel  ($why)"; ((left++)); continue
  fi

  dir="$DOCS/$ISSUER"
  fname="$DOCDATE - $DOCTYPE${INITIALS:+ - $INITIALS}"
  plain=$(sed -E 's/ \(scanned [^)]*\)( \([0-9]+\))?$//' <<< "$stem")   # name without a clash suffix
  if (( folder_only )); then
    [[ "$dir" == "$(dirname "$f")" ]] && { ((same++)); continue; }
    fname=$stem                         # keep the name, change the folder
  elif [[ "$dir" == "$(dirname "$f")" && "$fname" == "$plain" ]]; then
    ((same++)); continue                # same name; a clash suffix is not a change
  fi
  if (( dry )); then
    echo "WOULD $rel  ->  $ISSUER/$fname.pdf"; ((moved++)); continue
  fi
  dst=$(safe_move "$f" "$dir" "$fname") || { echo "FAIL  could not move $rel" >&2; ((left++)); continue; }
  newrel=${dst#"$DOCS"/}
  arrival=$(awk -F'\t' -v p="$rel" '$3==p {n=$2} END {print n}' "$NAMES" 2>/dev/null)
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "${arrival:-?}" "$newrel" >> "$NAMES"
  seen_move "$rel" "$newrel"
  echo "MOVED $rel  ->  $newrel"; ((moved++))
done
rm -f /tmp/reclassify.$$

# ---- tidy -------------------------------------------------------------------
while IFS= read -r -d '' d; do
  if (( dry )); then echo "WOULD remove empty folder: ${d#"$DOCS"/}"
  else rmdir "$d" && echo "removed empty folder: ${d#"$DOCS"/}"
  fi
done < <(find "$DOCS" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -empty -print0 | sort -z)

echo "done: $moved $( ((dry)) && echo 'would move' || echo 'moved'), $same unchanged, $left left as is"
