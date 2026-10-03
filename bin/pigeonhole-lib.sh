#!/bin/bash
# pigeonhole-lib.sh — settings and the classification helpers shared by
# ocr-one.sh (the worker) and reclassify.sh. Sourced, not run. Lives next to
# the scripts both in the repo and in /usr/local/bin.
#
# Callers may set before use:
#   scanned   "YYYY-MM-DD HHMM" of the scan, used by safe_move's clash suffix
#   scandate  "YYYY-MM-DD", the fallback when the model finds no date

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
    dst="$dir/$stem (scanned ${scanned:-$(date '+%F %H%M')}).$e"
    while ! ln "$src" "$dst" 2>/dev/null; do
      dst="$dir/$stem (scanned ${scanned:-$(date '+%F %H%M')}) ($n).$e"; ((n++))
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

# recipient_surnames -> last word of each "Some Name: ABC" line, upper-cased
recipient_surnames() {
  grep -E ':[[:space:]]*[A-Z]{2,4}[[:space:]]*$' "$PROMPT" 2>/dev/null |
    sed -E 's/:[[:space:]]*[A-Z]{2,4}[[:space:]]*$//; s/.* //' | tr '[:lower:]' '[:upper:]'
}

# not_an_issuer NAME -> true when NAME is a recipient code or surname, a date
# or number, or a document type word: things the model puts in the issuer
# field when it cannot find one
not_an_issuer() {
  local u="${1^^}"
  grep -qxF "$u" <<< "$codes" && return 0
  grep -qxF "$u" <<< "$surnames" && return 0
  [[ $u =~ ^[0-9][0-9./-]*$ ]] && return 0
  [[ $u =~ ^(RECEIPT|RECEIPTS|INVOICE|STATEMENT|BILL|LETTER|NOTICE|FORM|CERTIFICATE|CERTIFICATES|DOCUMENT|CONTRACT|POLICY|CLAIM|CHECK|W-?2|1099|1098|TAX|UNKNOWN|NONE|N/A|CUSTOMER|CUSTOMER COPY|STORE NUMBER [0-9]+|CORPORATE CERTIFICATES|CLEANER SERVICE FORM)$ ]] && return 0
  return 1
}

# nice_case NAME -> an all-caps name in title case ("STATE OF GEORGIA
# DEPARTMENT OF REVENUE" -> "State of Georgia Department of Revenue").
# Short words that look like acronyms (no vowel: LLC, MVD, PNC; or a known
# one: IRS, UPS, USAA) stay upper, as does anything with "&" (AT&T); small
# words (of, and, the) go lower; hyphenated parts are cased separately. A
# name that already has a lowercase letter is returned untouched.
nice_case() {
  local in="$1" out="" w first=1
  [[ $in == *[a-z]* ]] && { printf '%s' "$in"; return; }
  for w in $in; do
    if [[ $w == *"&"* ]]; then :
    elif [[ ${w,,} =~ ^(of|and|the|for|at|in|on|de|la|du)$ ]] && (( ! first )); then w=${w,,}
    else w=$(_case_word "$w")
    fi
    out+="${out:+ }$w"; first=0
  done
  printf '%s' "$out"
}
_case_word() {                  # one word, possibly hyphenated
  local w="$1" part rest out="" parts
  IFS=- read -ra parts <<< "$w"
  for part in "${parts[@]}"; do
    if (( ${#part} <= 4 )) && [[ $part != *[AEIOUY]* || $part =~ ^(IRS|UPS|USA|USAA|IBM|HSA|FSA|IRA|EOB|HOA|NASA|FEMA|AAA|AARP|CNN|ESPN|ATT|USPS|FDIC|DOJ|DOT|EPA|FBI|SSA|UGA|GSU|NFL|NBA|MLB|NHL|NYU|UCLA|USC|LLP|PLC|GMBH|CPA|CPAS|PC|PA|MD|DDS|DVM|OD|LP)$ ]]; then
      out+="${out:+-}$part"
    else
      rest=${part:1}; out+="${out:+-}${part:0:1}${rest,,}"
    fi
  done
  printf '%s' "$out"
}

# folder_key NAME -> the form used to decide two issuer names are the same
# folder: lowercase, "&" as "and", punctuation and spaces dropped, a leading
# "the" dropped. Legal suffixes (Inc, LLC) are kept on purpose: "Raxis Inc"
# and "Raxis LLC" may well be different entities. Use $ALIASES for those.
folder_key() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/&/ and /g; s/^www\.//; s/\.(com|net|org)$//; s/[^a-z0-9]+//g; s/^the//'
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
  (( n < 8 )) && { echo 0; return; }      # a word or two is not a document
  (( n < 20 )) && { echo 100; return; }   # too short to judge, let it through
  hits=$(grep -cxE 'the|and|for|your|you|this|that|with|from|are|was|have|not|account|total|date|amount|please|statement|payment|bill|number|balance|due|page|service|services|address|name|phone|box|dear|thank|information|insurance|member|patient|invoice|tax|year|form|income|interest|paid|charge|charges|visit|call|online|www|com|per|any|all|new|may|will|been|has|our|can|other|than|more|about' <<< "$toks")
  echo $(( hits * 100 / n ))
}

# has_text PDF -> true if the first pages already carry a text layer
has_text() {
  (( $(pdftotext -l 2 "$1" - 2>/dev/null | tr -d '[:space:]' | wc -c) > 50 ))
}

# date_in_text YYYY-MM-DD TEXT -> true if that date is printed in TEXT in any
# common form. The model is asked for the printed issue date but will guess
# one from context (a tax year, a billing period) when none is there.
date_in_text() {
  local y=${1:0:4} m=${1:5:2} d=${1:8:2} mon mab
  mon=$(date -d "$1" +%B 2>/dev/null) || return 1
  mab=${mon:0:3}
  grep -qiE "$1|$y/$m/$d|${m#0}/${d#0}/$y|$m/$d/$y|${m#0}/${d#0}/${y:2}|$m/$d/${y:2}|$m-$d-$y|$m-$d-${y:2}|$mon ${d#0},? $y|$mab\.? ${d#0},? $y|${d#0} $mon,? $y|${d#0} $mab\.? $y|${d#0}-$mab-$y|$d$mab$y" <<< "$2"
}

# classify PDF -> sets ISSUER DOCTYPE DOCDATE INITIALS. Returns 1 if the model
# can't name it, 2 if the model is unavailable, 3 if the text is unreadable.
classify() {
  local pdf="$1" text codes surnames row extra="" score rc
  text=$(pdftotext -l 2 -layout "$pdf" - 2>/dev/null | tr -s '[:space:]' ' ' 2>/dev/null | head -c "$TEXT_CHARS")
  [[ -z "${text// /}" ]] && { echo "naming: no text in $pdf" >&2; return 3; }
  score=$(readability "$text")
  (( score < MIN_READABLE )) && { echo "naming: text looks like gibberish (readability $score < $MIN_READABLE)" >&2; return 3; }
  codes=$(recipient_codes); surnames=$(recipient_surnames)

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

    # issuer came back as a recipient code or surname, a date, a number or a
    # document type -> ask once more, pointedly
    if not_an_issuer "$ISSUER"; then
      if (( attempt == 1 )); then
        echo "naming: issuer '$ISSUER' is not an organization, retrying" >&2
        extra="CORRECTION: \"$ISSUER\" is not an issuer. The issuer is the company, agency or organization whose name or logo appears at the top of the document; it is never a person, a family name, a recipient code, a date, a number or a kind of document. Try again."
        continue
      fi
      echo "naming: issuer '$ISSUER' still not an organization after retry, unsorted" >&2
      return 1
    fi
    break
  done

  [[ -z "$DOCTYPE" ]] && DOCTYPE="Document"
  ISSUER=$(nice_case "$ISSUER")
  if [[ "$DOCDATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && ! date_in_text "$DOCDATE" "$text"; then
    echo "naming: date $DOCDATE is not printed in the text, using scan date" >&2
    DOCDATE=""
  fi
  [[ "$DOCDATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || DOCDATE="${scandate:-$(date +%F)}"
  ISSUER=$(canonical_issuer "$ISSUER")
  return 0
}


# seen_move OLDREL NEWREL -> point the duplicate index's filed-path column at
# the new location (cosmetic: matching is by hash)
seen_move() {
  [[ -s "$SEEN" ]] || return 0
  flock "$SEEN.lock" awk -i inplace -F'\t' -v o="$1" -v n="$2" 'BEGIN{OFS=FS} $3==o{$3=n} 1' "$SEEN"
}
