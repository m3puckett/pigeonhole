#!/bin/bash
# ocr-one.sh — OCR a single scanned PDF, classify it from its content, and file
# it under $DOCS/<Issuer>/<YYYY-MM-DD - Document type - Initials>.pdf
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
TEXT_CHARS=3500                 # how much OCR text the model sees
UNSORTED=_Unsorted              # folder for anything that couldn't be classified
DUPS=duplicates                 # folder (under $SCANS) for re-sent copies of filed scans
SHARE=/usr/local/share/pigeonhole
[[ -f /etc/pigeonhole.conf ]] && source /etc/pigeonhole.conf

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
work="$WORK/$$-$name"           # unique per worker

# ---- helpers --------------------------------------------------------------

# clean STRING [MAXLEN] -> filesystem-safe, tidy spaces, trimmed, capped
clean() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._&-' \
    | sed -E 's/ +/ /g; s/^[ .]+//; s/[ .]+$//' | cut -c1-"${2:-80}"
}

# safe_move SRC DIR STEM -> prints final path. Claims the name with a hard
# link (atomic), so it never overwrites; falls back to a timestamp, then (n).
safe_move() {
  local src="$1" dir="$2" stem="$3" dst n=2
  mkdir -p "$dir"
  dst="$dir/$stem.pdf"
  if ! ln "$src" "$dst" 2>/dev/null; then
    dst="$dir/$stem (scanned $scanned).pdf"
    while ! ln "$src" "$dst" 2>/dev/null; do
      dst="$dir/$stem (scanned $scanned) ($n).pdf"; ((n++))
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

# canonical_issuer NAME -> apply alias file, then reuse an existing folder
# whose name matches ignoring case. Otherwise return NAME unchanged.
canonical_issuer() {
  local raw="$1" key hit
  key=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  if [[ -f "$ALIASES" ]]; then
    hit=$(awk -F= -v k="$key" '
      !/^[ \t]*#/ && NF>=2 { a=$1; gsub(/^[ \t]+|[ \t]+$/,"",a)
        if (tolower(a)==k) { b=$2; gsub(/^[ \t]+|[ \t]+$/,"",b); print b; exit } }' "$ALIASES")
    [[ -n "$hit" ]] && raw="$hit"
  fi
  hit=$(find "$DOCS" -maxdepth 1 -mindepth 1 -type d -iname "$raw" -printf '%f\n' 2>/dev/null | head -n1)
  [[ -n "$hit" ]] && raw="$hit"
  printf '%s' "$raw"
}

# ask_model TEXT [EXTRA] -> prints "issuer<TAB>type<TAB>date<TAB>recipient"
ask_model() {
  local text="$1" extra="${2:-}" tmpl prompt
  tmpl=$(<"$PROMPT")
  prompt=${tmpl//'{{KNOWN_FOLDERS}}'/$(existing_folders)}
  prompt=${prompt//'{{TEXT}}'/$text}
  [[ -n "$extra" ]] && prompt+=$'\n\n'"$extra"
  jq -n --arg m "$MODEL" --arg p "$prompt" \
     '{model:$m, prompt:$p, stream:false, format:"json", options:{temperature:0, num_ctx:8192}}' |
  flock "$WORK/ollama.lock" curl -s --max-time 300 "$OLLAMA" -d @- |
  jq -r '.response // empty' |
  jq -r '[.issuer, .type, .date, .recipient] | map((. // "") | tostring) | @tsv' 2>/dev/null
}

# classify PDF -> sets ISSUER DOCTYPE DOCDATE INITIALS; fails if unusable
classify() {
  local pdf="$1" text codes row extra=""
  text=$(pdftotext -l 2 -layout "$pdf" - 2>/dev/null | tr -s '[:space:]' ' ' 2>/dev/null | head -c "$TEXT_CHARS")
  [[ -z "${text// /}" ]] && { echo "naming: no text in $pdf" >&2; return 1; }
  codes=$(recipient_codes)

  for attempt in 1 2; do
    row=$(ask_model "$text" "$extra")
    [[ -z "$row" ]] && { echo "naming: empty/invalid/timeout from $MODEL" >&2; return 1; }
    IFS=$'\t' read -r ISSUER DOCTYPE DOCDATE INITIALS <<< "$row"
    ISSUER=$(clean "$ISSUER" 60); DOCTYPE=$(clean "$DOCTYPE" 60)
    DOCDATE=$(clean "$DOCDATE" 20); INITIALS=$(clean "$INITIALS" 20)
    [[ -z "$ISSUER" ]] && { echo "naming: model returned no issuer" >&2; return 1; }

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
ocr="$WORK/ocr-$$-$name"
ocr_opts=(--rotate-pages --deskew --clean --optimize 1 -l eng --output-type pdfa --jobs "$OCR_JOBS")
if ! ocrmypdf --skip-text "${ocr_opts[@]}" "$work" "$ocr" 2>>"$LOG"; then
  rm -f "$ocr"
  echo "retrying $name with --force-ocr" >&2
  if ! ocrmypdf --force-ocr "${ocr_opts[@]}" "$work" "$ocr" 2>>"$LOG"; then
    rm -f "$ocr"
    seen_forget
    dst=$(safe_move "$work" "$FAIL" "$stem")
    echo "FAIL $name -> $dst (see $LOG)"
    exit 1
  fi
fi

# ---- classify and file ----------------------------------------------------
if classify "$ocr"; then
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
