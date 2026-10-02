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

## Notes

- `$DOCS/.prompt` contains your family's names. If `$DOCS` is on a share
  others can write to, set `PROMPT=` in the conf to somewhere private.
- Scanners often reopen a file to set timestamps after upload; the watcher
  only acts on files untouched for 5 seconds and workers claim files by moving
  them, so duplicate events are harmless.
