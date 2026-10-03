#!/bin/bash
# ocr-one.sh — OCR a single scanned PDF or image (jpg, jpeg, png), classify it
# from its content, and file it under
# $DOCS/<Issuer>/<YYYY-MM-DD - Document type - Initials>.pdf
#
# Part of pigeonhole. Called by ocr-watch.sh, possibly several copies in
# parallel. Never overwrites anything.
#
# The classification prompt lives in $PROMPT ($DOCS/.prompt by default). It must
# keep the two placeholders {{KNOWN_FOLDERS}} and {{TEXT}}. Edit it freely; it
# is read fresh for every document. Recipient codes are discovered from lines
# in that file of the form "Some Name: ABC".
set -u

f="$1"

source "$(dirname "$(readlink -f "$0")")/pigeonhole-lib.sh"

name=$(basename "$f")
stem="${name%.*}"
ext="${name##*.}"; ext="${ext,,}"
work="$WORK/$$-$name"           # unique per worker; keeps the arrival extension

# ---- claim the file -------------------------------------------------------
# Leave it alone if it is empty or still growing (Finder bulk copies create
# every file empty, then fill them in). The close_write when the copy
# finishes triggers another sweep, which will pick it up then.
size=$(stat -c %s "$f" 2>/dev/null) || exit 0
(( size > 0 )) || exit 0
sleep 2
[[ "$(stat -c %s "$f" 2>/dev/null)" == "$size" ]] || exit 0

# If the mv fails, another worker already took it (or the scanner sent a
# duplicate event for a file that's gone). Either way, nothing to do.
mv "$f" "$work" 2>/dev/null || exit 0
scanned=$(date -r "$work" '+%F %H%M')
scandate=${scanned%% *}
mkdir -p "$DOCS" "$ORIG" "$FAIL"
touch "$SEEN"

# ---- duplicate check ------------------------------------------------------
# Same bytes as something already filed (a re-copied batch, a scanner resend)?
# Park it in $DUPS and stop. The lookup and the "ours now" entry happen under
# one lock so two workers holding identical files can't both file them.
hash=$(sha256sum "$work" | cut -c1-64)

seen_lookup_or_claim() {        # prints the existing entry, or records ours
  exec 9>>"$SEEN.lock"; flock 9
  grep -m1 "^$hash"$'\t' "$SEEN" ||
    printf '%s\t%s\t%s\n' "$hash" "$name" "(processing)" >> "$SEEN"
  exec 9>&-
}
seen_set() {                    # seen_set PATH -> record where ours was filed
  exec 9>>"$SEEN.lock"; flock 9
  awk -v h="$hash" -v p="$1" 'BEGIN{FS=OFS="\t"} $1==h{$3=p} 1' "$SEEN" > "$SEEN.tmp" &&
    mv "$SEEN.tmp" "$SEEN"
  exec 9>&-
}
seen_forget() {                 # drop our entry so a retry isn't a duplicate
  exec 9>>"$SEEN.lock"; flock 9
  awk -v h="$hash" -F'\t' '$1!=h' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
  exec 9>&-
}

prior=$(seen_lookup_or_claim)
if [[ -n "$prior" ]]; then
  IFS=$'\t' read -r _ pname ppath <<< "$prior"
  dst=$(safe_move "$work" "$SCANS/$DUPS" "$stem")
  printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$name" "$pname" "$ppath" >> "$DUPLOG"
  echo "DUP  $name == $pname -> $ppath (parked in ${dst#"$SCANS"/})"
  exit 0
fi

# first run: seed the prompt from the shipped example, then it's yours to edit
[[ -f "$PROMPT" ]] || cp "$SHARE/prompt.example" "$PROMPT"

# ---- OCR ------------------------------------------------------------------
# Scanners sometimes emit slightly corrupt JPEG streams ("invalid jpeg data")
# that ocrmypdf cannot copy through. --force-ocr re-rasterizes every page, so
# it gets past that; it is slower and loses nothing on a scan, so retry with it.
ocr="$WORK/ocr-$$-$stem.pdf"
forced=0                        # set when --force-ocr produced the text
ocr_opts=(--rotate-pages --rotate-pages-threshold "$ROTATE_THRESHOLD" --deskew --clean
          --optimize 1 -l eng --output-type pdfa --jobs "$OCR_JOBS")

# An image becomes a one-page PDF first. ocrmypdf refuses one whose metadata
# has no credible resolution (phone photos say 72 dpi or nothing), so in that
# case assume the paper was letter width and derive the dpi from the pixels.
if [[ $ext != pdf ]]; then
  read -r img_dpi img_w < <(python3 -c '
import sys
from PIL import Image
with Image.open(sys.argv[1]) as im:
    print(int(im.info.get("dpi", (0, 0))[0]), im.size[0])' "$work" 2>/dev/null || echo "0 0")
  if (( img_dpi <= 96 )); then
    est=$(( img_w * 10 / 85 )); (( est < 100 )) && est=100
    ocr_opts+=(--image-dpi "$est")
    echo "image: $name has no credible dpi, assuming letter width -> $est dpi" >&2
  fi
fi
if ! ocrmypdf --skip-text "${ocr_opts[@]}" "$work" "$ocr" 2>>"$LOG"; then
  rm -f "$ocr"
  echo "retrying $name with --force-ocr" >&2
  forced=1
  if ! ocrmypdf --force-ocr "${ocr_opts[@]}" "$work" "$ocr" 2>>"$LOG"; then
    rm -f "$ocr"
    # Last resort for a PDF whose structure is damaged (ghostscript gives up
    # on it, pikepdf trips over a truncated image): poppler usually still
    # renders the pages, so rasterize them and OCR a PDF rebuilt from that.
    rebuilt=""
    if [[ $ext == pdf ]]; then
      echo "retrying $name from rasterized pages" >&2
      raster="$WORK/raster-$$"
      if pdftoppm -r 300 -png "$work" "$raster" 2>>"$LOG" && compgen -G "$raster-*.png" >/dev/null &&
         python3 -c 'import sys, glob, img2pdf; open(sys.argv[1], "wb").write(img2pdf.convert(sorted(glob.glob(sys.argv[2] + "-*.png"))))' "$raster.pdf" "$raster" 2>>"$LOG" &&
         ocrmypdf --force-ocr "${ocr_opts[@]}" "$raster.pdf" "$ocr" 2>>"$LOG"; then
        rebuilt=1
      fi
      rm -f "$raster"-*.png "$raster.pdf"
    fi
    if [[ -z $rebuilt ]]; then
      rm -f "$ocr"
      seen_forget
      dst=$(safe_move "$work" "$FAIL" "$stem")
      echo "FAIL $name -> $dst (see $LOG)"
      exit 1
    fi
  fi
fi

# ---- classify and file ----------------------------------------------------

# name_it PDF -> classify, waiting out an unavailable model. If the model is
# still gone after $MODEL_WAIT minutes that is not this document's problem:
# hand the file back to the inbox untouched (the watcher holds the inbox until
# the model answers) and stop.
name_it() {
  local rc i
  classify "$1"; rc=$?
  if (( rc == 2 )); then
    echo "model unavailable, retrying for up to $MODEL_WAIT min" >&2
    for (( i = 0; i < MODEL_WAIT && rc == 2; i++ )); do
      sleep 60; classify "$1"; rc=$?
    done
    if (( rc == 2 )); then
      rm -f "$ocr"; seen_forget
      mv -n "$work" "$IN/$name" 2>/dev/null || safe_move "$work" "$IN" "$stem" >/dev/null
      echo "HOLD $name -> inbox (model unavailable for $MODEL_WAIT min)"
      exit 0
    fi
  fi
  return $rc
}

name_it "$ocr"; rc=$?

# Unreadable text in a PDF that arrived with its own text layer: that layer
# was someone else's OCR (--skip-text kept it) and may simply be poor. Redo
# it once. --redo-ocr can't be combined with --deskew, so that is dropped.
if (( rc == 3 && ! forced )) && [[ $ext == pdf ]] && has_text "$work"; then
  echo "retrying $name with --redo-ocr (existing text layer unreadable)" >&2
  redo="$WORK/redo-$$-$stem.pdf"
  redo_opts=(); for opt in "${ocr_opts[@]}"; do [[ $opt == --deskew ]] || redo_opts+=("$opt"); done
  if ocrmypdf --redo-ocr "${redo_opts[@]}" "$work" "$redo" 2>>"$LOG"; then
    mv -f "$redo" "$ocr"
    name_it "$ocr"; rc=$?
  else
    rm -f "$redo"
    echo "redo-ocr failed for $name, keeping first pass (see $LOG)" >&2
  fi
fi
(( rc == 3 )) && echo "naming: unreadable, unsorted" >&2

if (( rc == 0 )); then
  dir="$DOCS/$ISSUER"
  fname="$DOCDATE - $DOCTYPE${INITIALS:+ - $INITIALS}"
else
  dir="$DOCS/$UNSORTED"
  fname="$scandate - $stem"
fi
dst=$(safe_move "$ocr" "$dir" "$fname")
safe_move "$work" "$ORIG" "$stem" >/dev/null
seen_set "${dst#"$DOCS"/}"

printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$name" "${dst#"$DOCS"/}" >> "$NAMES"
echo "OK   $name -> ${dst#"$DOCS"/}"
