# pigeonhole

mark@raxis.com

Drop a scanned PDF in a folder. A few seconds later it has a searchable text
layer, a sensible name, and it's sitting in a folder named for whoever sent it.

```
scans/inbox/BRW60E9AA43E7E9_001598.pdf
        │
        ▼  ocrmypdf  →  local LLM (Ollama) reads the first two pages
        │
        ▼
documents/CrossCountry Mortgage/2026-08-04 - Mortgage Statement - AQE.pdf
```

Everything runs on your own box. No document text leaves the machine.

## How it works

- `ocr-watch.sh` (a systemd service) watches `$SCANS/inbox` with inotify and
  sweeps new PDFs to `ocr-one.sh`, several at a time.
- `ocr-one.sh` runs `ocrmypdf`, hands the OCR text to a small local model with
  the prompt in `$DOCS/.prompt`, gets back JSON (`issuer`, `type`, `date`,
  `recipient`), and files the result as
  `$DOCS/<Issuer>/<YYYY-MM-DD - Type - Recipient>.pdf`.
- The original scan is kept in `$SCANS/originals/`; OCR failures land in
  `$SCANS/failed/`; anything the model can't classify goes to
  `$DOCS/_Unsorted/`.
- `$SCANS/.names.log` records original name → final path for every document.

### Keeping folders consistent

The folders already under `$DOCS` are fed to the model as the authoritative
issuer list, and whatever it returns is matched case-insensitively against
them before a new folder is created. Create the folders you want by hand and
the system follows. For stubborn variants, add aliases to `$DOCS/.issuers`
(see `examples/issuers.example`).

### Never overwrites

Destinations are claimed with an atomic hard link, so parallel workers can't
race and nothing you placed by hand can be clobbered. A collision gets a
`(scanned YYYY-MM-DD HHMM)` suffix.

## Requirements

Ubuntu/Debian:

```
sudo apt install ocrmypdf tesseract-ocr-eng unpaper pngquant inotify-tools jq poppler-utils
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen2.5:3b
```

`qwen2.5:3b` is good and runs on CPU in a few seconds per document on a
modern desktop chip. `qwen2.5:7b` is noticeably better at messy scans if you
have the RAM and patience.

## Install

```
git clone <this repo> && cd pigeonhole
sudo ./install.sh
sudo vi /etc/pigeonhole.conf          # paths, model, parallelism
sudo systemctl restart ocr-watch
journalctl -fu ocr-watch
```

`install.sh` copies the scripts to `/usr/local/bin`, the examples to
`/usr/local/share/pigeonhole`, installs and enables the systemd unit, and
seeds `/etc/pigeonhole.conf` if it doesn't exist. Re-run it after a `git pull`.

Edit `systemd/ocr-watch.service` (or override with `systemctl edit`) to set the
user the service runs as; it should be the user that owns the share.

On first run `ocr-one.sh` copies `prompt.example` to `$DOCS/.prompt`. Edit
that file to add your household's recipient codes (lines of the form
`Full Name: ABC`); it's read fresh for every document. Keep the two
placeholders `{{KNOWN_FOLDERS}}` and `{{TEXT}}`.

Point your scanner's scan-to-SMB at the `inbox` folder.

## Tuning

| Setting | Where | Notes |
|---|---|---|
| `PAR` | conf | Documents OCR'd at once. Model calls are serialized anyway. |
| `OCR_JOBS` | conf | Tesseract threads per document. `PAR × OCR_JOBS ≈ cores`. |
| `MODEL` | conf | Any Ollama model name. |
| `--optimize 1` | `ocr-one.sh` | `2` is lossy but smaller. |
| `OLLAMA_KEEP_ALIVE` | ollama service | Set to `1h`+ so the model stays loaded between scans. |

## Images

JPEG and PNG files in the inbox are handled like PDFs: each becomes a one-page
searchable PDF and is classified and filed the same way, and the untouched
image is kept in `originals/`. Scanner JPEGs carry their resolution; a phone
photo usually does not, so its dpi is estimated as if the paper were letter
width. One image is one page: a three-page letter photographed as three images
is filed as three documents.

## Duplicates

Every document that gets filed is also hashed (sha256 of the bytes as they
arrived) into `$SCANS/.seen`. A new arrival whose hash is already there is
parked in `$SCANS/duplicates/` instead of being OCR'd and filed again, with a
`DUP` line in the journal and a row in `$SCANS/.dups.log` naming what it
matched. So re-copying a whole folder of old scans is harmless: only the ones
pigeonhole has never seen get processed. The check is on content, not name, so
a renamed copy is still a duplicate and a fresh scan of the same paper is not.

Run `seed-seen.sh` once after upgrading to index everything already in
`originals/`; it is safe to re-run any time.

## Misfiles

OCR of a page that is upside down, sideways or blurry comes out as letter
salad, and a small model asked to name its issuer will guess rather than say
nothing (usually the first example in the prompt). Two defences:

- `ROTATE_THRESHOLD` (default 2) makes ocrmypdf act on tesseract's orientation
  guess far more readily than its default of 14, which missed every rotated
  page in the first batch while never being wrong about upright ones.
- Text scoring below `MIN_READABLE` common English words per 100 tokens
  (default 4) is not shown to the model at all; the document goes to
  `_Unsorted` with a `gibberish` line in the journal.

To redo documents that were filed wrongly, `reprocess.sh <filed pdf>...` parks
the filed copy in `$SCANS/.misfiled/`, forgets its hash, and puts the stored
original back in the inbox. Nothing is deleted.

## When the model is down

Nothing is filed without an answer from the model. The watcher checks that
`MODEL` exists on the Ollama host before each sweep and holds the inbox,
with one journal line, until it does; a worker that loses the model
mid-document retries for `MODEL_WAIT` minutes and then puts the file back in
the inbox with a `HOLD` line. So a typo in `MODEL`, a model not yet pulled on
a new host, or the host rebooting just pauses pigeonhole instead of sending
everything to `_Unsorted`.

## Notes

- `$DOCS/.prompt` contains your family's names. If `$DOCS` is on a share
  others can write to, set `PROMPT=` in the conf to somewhere private.
- Scanners often reopen a file to set timestamps after upload, and Finder
  copying a batch onto the share creates every file empty first and fills them
  in later. The watcher only acts on non-empty files whose inode has been
  untouched for 5 seconds, workers skip anything still growing, and workers
  claim files by moving them, so duplicate events are harmless.
- Restarting the service (an `install.sh` run, say) is safe at any time. It
  kills whatever the workers had in hand, and on startup the watcher puts those
  files back in the inbox to be done again.
