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

# ---- defaults (override any of these in /etc/pigeonhole.conf) -------------
SCANS=/srv/nas/public/scans
DOCS=/srv/nas/public/documents
MODEL=qwen2.5:3b
OLLAMA=http://127.0.0.1:11434/api/generate
OCR_JOBS=2                      # tesseract threads per document
ROTATE_THRESHOLD=2              # ocrmypdf --rotate-pages-threshold; default 14 misses most upside-down scans
TEXT_CHARS=3500                 # how much OCR text the model sees
MIN_READABLE=4                  # common English words per 100 tokens below which OCR text is treated as gibberish
MODEL_WAIT=10                   # minutes to keep retrying when the model is unreachable before giving the file back
UNSORTED=_Unsorted              # folder for anything that couldn't be classified
DUPS=duplicates                 # folder (under $SCANS) for re-sent copies of filed scans
SHARE=/usr/local/share/pigeonhole
[[ -f /etc/pigeonhole.conf ]] && source /etc/pigeonhole.conf

IN=$SCANS/inbox
WORK=$SCANS/.work
ORIG=$SCANS/originals
FAIL=$SCANS/failed
LOG=$SCANS/.ocr.log             # ocrmypdf stderr
NAMES=$SCANS/.names.log         # original name -> final path
SEEN=$SCANS/.seen               # sha256 <TAB> original name <TAB> filed path
DUPLOG=$SCANS/.dups.log         # duplicate name -> what it matched
PROMPT=${PROMPT:-$DOCS/.prompt}
ALIASES=${ALIASES:-$DOCS/.issuers}

name=$(basename "$f")
stem="${name%.*}"
ext="${name##*.}"; ext="${ext,,}"
work="$WORK/$$-$name"           # unique per worker; keeps the arrival extension

# ---- helpers --------------------------------------------------------------

# clean STRING [MAXLEN] -> filesystem-safe, tidy spaces, trimmed, capped
clean() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._&-' \
    | sed -E 's/ +/ /g; s/^[ .]+//; s/[ .]+$//' | cut -c1-"${2:-80}"
}

# safe_move SRC DIR STEM -> prints final path. Keeps SRC's extension. Claims
# the name with a hard link (atomic), so it never overwrites; falls back to a
# timestamp, then (n).
safe_move() {
  local src="$1" dir="$2" stem="$3" dst n=2 e
  e="${src##*.}"; e="${e,,}"
  mkdir -p "$dir"
  dst="$dir/$stem.$e"
  if ! ln "$src" "$dst" 2>/dev/null; then
    dst="$dir/$stem (scanned $scanned).$e"
    while ! ln "$src" "$dst" 2>/dev/null; do
      dst="$dir/$stem (scanned $scanned) ($n).$e"; ((n++))
      (( n > 100 )) && return 1
    done
  fi
  rm -f "$src"
  printf '%s' "$dst"
}

# existing_folders -> text block listing issuer folders already present
existing_folders() {
  local list
  list=$(find "$DOCS" -maxdepth 1 -mindepth 1 -type d ! -name '.*' ! -name "$UNSORTED" \
           -printf '%f\n' 2>/dev/null | sort -f | head -n 200 | paste -sd ';' - | sed 's/;/; /g')
  [[ -n "$list" ]] && printf 'Existing issuer folders. If the document is from one of these, write the issuer EXACTLY as it appears here:\n%s\n' "$list"
}

# recipient_codes -> the codes defined in the prompt file, one per line
recipient_codes() {
  grep -oE ':[[:space:]]*[A-Z]{2,4}[[:space:]]*$' "$PROMPT" 2>/dev/null | tr -d ': \t'
}

# folder_key NAME -> the form used to decide two issuer names are the same
# folder: lowercase, "&" as "and", punctuation and spaces dropped, a leading
# "the" dropped. Legal suffixes (Inc, LLC) are kept on purpose: "Raxis Inc"
# and "Raxis LLC" may well be different entities. Use $ALIASES for those.
folder_key() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/&/ and /g; s/[^a-z0-9]+//g; s/^the//'
}

# canonical_issuer NAME -> apply alias file, then reuse an existing folder
# with the same folder_key. Otherwise return NAME unchanged.
canonical_issuer() {
  local raw="$1" key hit d
  key=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  if [[ -f "$ALIASES" ]]; then
    hit=$(awk -F= -v k="$key" '
      !/^[ \t]*#/ && NF>=2 { a=$1; gsub(/^[ \t]+|[ \t]+$/,"",a)
        if (tolower(a)==k) { b=$2; gsub(/^[ \t]+|[ \t]+$/,"",b); print b; exit } }' "$ALIASES")
    [[ -n "$hit" ]] && raw="$hit"
  fi
  key=$(folder_key "$raw")
  while IFS= read -r d; do
    [[ $(folder_key "$d") == "$key" ]] && { raw="$d"; break; }
  done < <(find "$DOCS" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort)
  printf '%s' "$raw"
}

# ask_model TEXT [EXTRA] -> prints "issuer<TAB>type<TAB>date<TAB>recipient".
# Returns 2 when Ollama could not be reached or reported an error (model not
# pulled, server down), which is not the document's fault: the caller holds
# instead of filing it unsorted.
ask_model() {
  local text="$1" extra="${2:-}" tmpl prompt raw err
  tmpl=$(<"$PROMPT")
  # replacements are quoted: unquoted, bash >= 5.2 turns every "&" in them
  # into the matched placeholder ("Weaver Brake & Tire" -> "Weaver Brake
  # {{KNOWN_FOLDERS}} Tire"), which the model then faithfully echoes back
  prompt=${tmpl//'{{KNOWN_FOLDERS}}'/"$(existing_folders)"}
  prompt=${prompt//'{{TEXT}}'/"$text"}
  [[ -n "$extra" ]] && prompt+=$'\n\n'"$extra"
  raw=$(jq -n --arg m "$MODEL" --arg p "$prompt" \
          '{model:$m, prompt:$p, stream:false, format:"json", options:{temperature:0, num_ctx:8192}}' |
        flock "$WORK/ollama.lock" curl -s --max-time 300 "$OLLAMA" -d @-)
  [[ -z "$raw" ]] && { echo "model: no answer from $OLLAMA" >&2; return 2; }
  err=$(jq -r '.error // empty' <<< "$raw" 2>/dev/null)
  [[ -n "$err" ]] && { echo "model: $OLLAMA says: $err" >&2; return 2; }
  jq -r '.response // empty' <<< "$raw" |
  jq -r '[.issuer, .type, .date, .recipient] | map((. // "") | tostring) | @tsv' 2>/dev/null
}

# readability TEXT -> prints common-English-words per 100 tokens (0-100), or
# 100 when there are too few tokens to judge. OCR of a page that is upside
# down, sideways or just blurry comes out as letter salad; the model then
# guesses an issuer (usually the prompt's first example) and the document is
# misfiled. Anything below $MIN_READABLE is sent to $UNSORTED instead.
readability() {
  local toks n hits
  toks=$(printf '%s' "$1" | tr -cs 'A-Za-z' '\n' | awk 'length>=2' | tr 'A-Z' 'a-z')
  n=$(grep -c . <<< "$toks")
  (( n < 20 )) && { echo 100; return; }
  hits=$(grep -cxE 'the|and|for|your|you|this|that|with|from|are|was|have|not|account|total|date|amount|please|statement|payment|bill|number|balance|due|page|service|services|address|name|phone|box|dear|thank|information|insurance|member|patient|invoice|tax|year|form|income|interest|paid|charge|charges|visit|call|online|www|com|per|any|all|new|may|will|been|has|our|can|other|than|more|about' <<< "$toks")
  echo $(( hits * 100 / n ))
}

# has_text PDF -> true if the first pages already carry a text layer
has_text() {
  (( $(pdftotext -l 2 "$1" - 2>/dev/null | tr -d '[:space:]' | wc -c) > 50 ))
}

# classify PDF -> sets ISSUER DOCTYPE DOCDATE INITIALS. Returns 1 if the model
# can't name it, 2 if the model is unavailable, 3 if the text is unreadable.
classify() {
  local pdf="$1" text codes row extra="" score rc
  text=$(pdftotext -l 2 -layout "$pdf" - 2>/dev/null | tr -s '[:space:]' ' ' 2>/dev/null | head -c "$TEXT_CHARS")
  [[ -z "${text// /}" ]] && { echo "naming: no text in $pdf" >&2; return 3; }
  score=$(readability "$text")
  (( score < MIN_READABLE )) && { echo "naming: text looks like gibberish (readability $score < $MIN_READABLE)" >&2; return 3; }
  codes=$(recipient_codes)

  for attempt in 1 2; do
    row=$(ask_model "$text" "$extra"); rc=$?
    (( rc == 2 )) && return 2
    [[ -z "$row" ]] && { echo "naming: empty/invalid answer from $MODEL" >&2; return 1; }
    IFS=$'\t' read -r ISSUER DOCTYPE DOCDATE INITIALS <<< "$row"
    ISSUER=$(clean "$ISSUER" 60); DOCTYPE=$(clean "$DOCTYPE" 60)
    DOCDATE=$(clean "$DOCDATE" 20); INITIALS=$(clean "$INITIALS" 20)

    # no issuer at all -> ask once more; this usually works on readable text
    if [[ -z "$ISSUER" ]]; then
      if (( attempt == 1 )); then
        echo "naming: model returned no issuer, retrying" >&2
        extra="CORRECTION: your answer left \"issuer\" empty. Name the company, agency or organization that produced this document, whatever appears at the top of the first page, even if it is not one of the existing folders."
        continue
      fi
      echo "naming: still no issuer after retry, unsorted" >&2
      return 1
    fi

    # issuer came back as a recipient code -> ask once more, pointedly
    if grep -qxF "${ISSUER^^}" <<< "$codes"; then
      if (( attempt == 1 )); then
        echo "naming: issuer '$ISSUER' is a recipient code, retrying" >&2
        extra="CORRECTION: \"$ISSUER\" is a recipient code, not an issuer. The issuer is the company or organization whose name or logo appears at the top of the document. Try again."
        continue
      fi
      echo "naming: issuer still a recipient code after retry, unsorted" >&2
      return 1
    fi
    break
  done

  [[ -z "$DOCTYPE" ]] && DOCTYPE="Document"
  [[ "$DOCDATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || DOCDATE="$scandate"
  ISSUER=$(canonical_issuer "$ISSUER")
  return 0
}

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
    seen_forget
    dst=$(safe_move "$work" "$FAIL" "$stem")
    echo "FAIL $name -> $dst (see $LOG)"
    exit 1
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
