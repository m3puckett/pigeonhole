#!/bin/bash
# Install or update pigeonhole. Safe to re-run after a git pull.
set -eu
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

install -m 0755 bin/ocr-one.sh bin/ocr-watch.sh bin/seed-seen.sh bin/reprocess.sh bin/merge-issuer.sh bin/reclassify.sh /usr/local/bin/
install -m 0644 bin/pigeonhole-lib.sh /usr/local/bin/
install -d /usr/local/share/pigeonhole
install -m 0644 examples/prompt.example examples/issuers.example /usr/local/share/pigeonhole/
install -m 0644 systemd/ocr-watch.service /etc/systemd/system/
[[ -d /etc/logrotate.d ]] && install -m 0644 examples/pigeonhole.logrotate /etc/logrotate.d/pigeonhole
[[ -f /etc/pigeonhole.conf ]] || install -m 0644 examples/pigeonhole.conf.example /etc/pigeonhole.conf

systemctl daemon-reload
systemctl enable --now ocr-watch
systemctl restart ocr-watch
echo "pigeonhole installed. Watch it: journalctl -fu ocr-watch"
