#!/usr/bin/env bash
# Replace the decoy website on a server installed by deploy-3xui.sh (no reinstall).
#   bash <(curl -fsSL https://raw.githubusercontent.com/Zippo102-89/deploy-3xui/main/update-decoy.sh)
# Optional: BRAND="My Studio" bash <(curl ...)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
DIR=/var/www/3xui-decoy
[[ -d $DIR ]] || { echo "$DIR not found — was the server installed with deploy-3xui.sh?" >&2; exit 1; }
DOMAIN=${DOMAIN:-$(sed -n 's/^Domain *: //p' /root/3xui-info.txt 2>/dev/null || true)}
[[ -n "$DOMAIN" ]] || DOMAIN=$(hostname -f)
BRANDS=("Lumacraft Studio" "Arcvale Digital" "Brightmoor Labs" "Quillhaven Studio" "Kestrelbay Digital"
        "Fernwick Studio" "Solent Works" "Northmere Labs" "Cobalt Finch Studio" "Silverbirch Digital")
BRAND=${BRAND:-${BRANDS[$(( $(od -An -N1 -tu1 /dev/urandom | tr -d ' ') % ${#BRANDS[@]} ))]}}
curl -fsSL --max-time 15 https://raw.githubusercontent.com/Zippo102-89/deploy-3xui/main/decoy.html \
  | sed -e "s/__BRAND__/$BRAND/g" -e "s/__YEAR__/$(date +%Y)/g" -e "s/__HOST__/$DOMAIN/g" > "$DIR/index.html.new"
mv "$DIR/index.html.new" "$DIR/index.html"
echo "decoy updated: https://$DOMAIN/  ($BRAND)"
