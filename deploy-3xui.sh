#!/usr/bin/env bash
# =============================================================================
#  deploy-3xui.sh — 3x-ui + nginx on a fresh Ubuntu/Debian server, one command.
#
#  Layout:
#    :443  nginx stream, routing by SNI (PROXY protocol to backends)
#          ├─ SNI = $DOMAIN      -> nginx :7443 (TLS, Let's Encrypt)
#          │     ├─ /<panel path>     -> 3x-ui panel   (127.0.0.1)
#          │     ├─ /<sub path>       -> subscriptions (127.0.0.1)
#          │     ├─ /<xhttp path>     -> VLESS XHTTP   (unix socket)
#          │     ├─ /<port>/<ws path> -> VLESS WS      (127.0.0.1)
#          │     └─ /<port>/<grpc>    -> Trojan gRPC   (127.0.0.1)
#          └─ any other SNI     -> VLESS Reality + Vision (127.0.0.1:8443)
#    :80   certbot + redirect to https
#
#  Usage (as root):
#    bash deploy-3xui.sh
#  Options (environment variables, all optional):
#    DOMAIN=my.domain.com      default: <server-ip>.cdn-one.org (wildcard IP DNS)
#    REALITY_SNI=www.max.ru    Reality mask site (must support TLS 1.3 + h2)
#    PANEL_USER=... PANEL_PASS=...   default: random
#    REMARK="NL"               prefix for inbound names (default: country code)
#    XUI_VERSION=v3.10.2       default: latest release
#    CLIENT_NAME=user1         first client (one subscription for all 4 inbounds)
#    ENABLE_UFW=1              open only ssh/80/443 (0 = don't touch firewall)
#    FORCE=1                   allow running over an existing 3x-ui install
# =============================================================================
set -Eeuo pipefail

# ---------- helpers ----------------------------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_off=$'\e[0m'
log()  { echo "${c_grn}==>${c_off} $*"; }
warn() { echo "${c_ylw}[!]${c_off} $*" >&2; }
die()  { echo "${c_red}[x] $*${c_off}" >&2; exit 1; }
# never exit silently: report the failing line and command
trap 'echo "${c_red}[x] failed at line $LINENO: $BASH_COMMAND${c_off}" >&2' ERR

# random alnum string without SIGPIPE issues under pipefail
rnd() { head -c 256 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }
rnd_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

port_free() { ! ss -Htln "sport = :$1" | grep -q .; }
rnd_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(( 20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000 ))
    port_free "$p" && { echo "$p"; return; }
  done
  die "no free port found"
}

# ---------- pre-flight -------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run as root"
. /etc/os-release
[[ "${ID:-}" =~ ^(ubuntu|debian)$ ]] || die "only Ubuntu/Debian are supported (found: ${ID:-?})"
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported arch $(uname -m)" ;;
esac

# a working install has a DB; a leftover from a failed run of this script does not
if [[ -d /usr/local/x-ui && -f /etc/x-ui/x-ui.db && "${FORCE:-0}" != 1 ]]; then
  die "3x-ui already installed in /usr/local/x-ui. Re-run with FORCE=1 to reinstall (old DB is backed up)."
fi

log "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates jq sqlite3 openssl tar ufw certbot \
  nginx libnginx-mod-stream dnsutils >/dev/null

IP=$(curl -4 -s --max-time 8 https://api.ipify.org || curl -4 -s --max-time 8 https://ifconfig.me || true)
[[ "$IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "cannot detect public IPv4"
DOMAIN=${DOMAIN:-$IP.cdn-one.org}
REALITY_SNI=${REALITY_SNI:-www.max.ru}
CLIENT_NAME=${CLIENT_NAME:-user1}
ENABLE_UFW=${ENABLE_UFW:-1}
if [[ -z "${REMARK:-}" ]]; then
  REMARK=$(curl -s --max-time 5 "https://ipinfo.io/$IP/country" 2>/dev/null | tr -dc 'A-Z' | cut -c1-2 || true)
  REMARK=${REMARK:-VPN}
fi

RES=$(dig +short A "$DOMAIN" | tail -1)
[[ "$RES" == "$IP" ]] || die "$DOMAIN resolves to '${RES:-nothing}', expected $IP. Fix DNS or set DOMAIN=..."
log "server $IP, domain $DOMAIN, reality SNI $REALITY_SNI"

curl -s --max-time 8 -o /dev/null "https://$REALITY_SNI/" \
  || warn "$REALITY_SNI is not reachable from this server; Reality needs a reachable target"

# ---------- generated parameters ---------------------------------------------
PANEL_USER=${PANEL_USER:-admin$(rnd 4)}
PANEL_PASS=${PANEL_PASS:-$(rnd 20)}
PANEL_PORT=$(rnd_port)
SUB_PORT=$(rnd_port)
WS_PORT=$(rnd_port)
GRPC_PORT=$(rnd_port)
REALITY_PORT=8443; port_free $REALITY_PORT || REALITY_PORT=$(rnd_port)
WWW_PORT=7443;     port_free $WWW_PORT     || WWW_PORT=$(rnd_port)
PANEL_PATH=$(rnd 10)
SUB_PATH=$(rnd 10)
SUBJSON_PATH=$(rnd 10)
XHTTP_PATH=$(rnd 10)
WS_PATH="$WS_PORT/$(rnd 10)"
GRPC_SVC="$GRPC_PORT/$(rnd 10)"
XHTTP_SOCK="/dev/shm/xhttp-$(rnd 6).sock"
SUB_ID=$(rnd 16)

# ---------- system tuning ----------------------------------------------------
log "enabling BBR"
cat > /etc/sysctl.d/99-3xui.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null 2>&1 || true

# ---------- firewall (before certbot: needs :80) -----------------------------
if [[ "$ENABLE_UFW" == 1 ]]; then
  log "configuring ufw (ssh, 80, 443)"
  # sshd -T fails on some images (e.g. Debian cloud with socket-activated ssh) — never let it abort
  SSH_PORT=$( { sshd -T 2>/dev/null || true; } | awk '/^port /{print $2; exit}')
  [[ -n "$SSH_PORT" ]] || SSH_PORT=$( { ss -Htlnp 2>/dev/null || true; } | awk '/sshd|"systemd"/{n=split($4,a,":"); print a[n]; exit}')
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
  ufw allow "$SSH_PORT/tcp" comment ssh >/dev/null
  ufw allow 80/tcp comment 'certbot/http' >/dev/null
  ufw allow 443/tcp comment 'nginx sni' >/dev/null
  ufw --force enable >/dev/null
fi

# ---------- certificate ------------------------------------------------------
log "issuing Let's Encrypt certificate for $DOMAIN"
systemctl stop nginx 2>/dev/null || true
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
  --register-unsafely-without-email --key-type ecdsa --keep-until-expiring \
  --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" >/dev/null \
  || die "certbot failed (is port 80 reachable from the internet?)"
# on renewal x-ui must reload the new cert (panel + subscription use it directly)
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/3xui-restart.sh <<'EOF'
#!/bin/sh
systemctl restart x-ui || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/3xui-restart.sh
CERT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
KEY=/etc/letsencrypt/live/$DOMAIN/privkey.pem

# ---------- 3x-ui ------------------------------------------------------------
if [[ -z "${XUI_VERSION:-}" ]]; then
  XUI_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest | jq -r .tag_name)
fi
[[ "$XUI_VERSION" == v* ]] || die "cannot determine 3x-ui version"
log "installing 3x-ui $XUI_VERSION"
URL="https://github.com/MHSanaei/3x-ui/releases/download/$XUI_VERSION/x-ui-linux-$ARCH.tar.gz"
TMP=$(mktemp -d)
curl -sL --fail -o "$TMP/x-ui.tgz" "$URL" || die "download failed: $URL"
if curl -sL --fail -o "$TMP/x-ui.tgz.sha256" "$URL.sha256"; then
  (cd "$TMP" && echo "$(awk '{print $1}' x-ui.tgz.sha256)  x-ui.tgz" | sha256sum -c --quiet -) \
    || die "sha256 mismatch for $URL"
fi
systemctl stop x-ui 2>/dev/null || true
if [[ -d /usr/local/x-ui ]]; then
  BK=/root/x-ui-backup-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BK"; cp -a /etc/x-ui "$BK/" 2>/dev/null || true
  rm -rf /usr/local/x-ui /etc/x-ui
  warn "previous install removed, DB backed up to $BK"
fi
tar -xzf "$TMP/x-ui.tgz" -C /usr/local/
rm -rf "$TMP"
chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* 2>/dev/null || true
cp -f /usr/local/x-ui/x-ui.sh /usr/bin/x-ui && chmod +x /usr/bin/x-ui
SVC=/usr/local/x-ui/x-ui.service.debian; [[ -f $SVC ]] || SVC=/usr/local/x-ui/x-ui.service
cp -f "$SVC" /etc/systemd/system/x-ui.service
systemctl daemon-reload
systemctl enable x-ui >/dev/null 2>&1
XUI=/usr/local/x-ui/x-ui
XRAY=$(ls /usr/local/x-ui/bin/xray-linux-* | head -1)

# x-ui >= 3.10 runs under ProtectSystem=full: /etc is read-only for the service and
# ReadWritePaths=-/etc/x-ui only applies if the folder already exists — create it first.
mkdir -p /etc/x-ui /var/log/x-ui
chmod 700 /etc/x-ui

# first start creates the DB
DB=/etc/x-ui/x-ui.db
systemctl start x-ui
for _ in $(seq 1 30); do [[ -f $DB ]] && break; sleep 1; done
if [[ ! -f $DB ]]; then
  journalctl -u x-ui --no-pager -n 30 >&2 || true
  die "x-ui did not create $DB (see the log above)"
fi
sleep 2
systemctl stop x-ui

setkv() {  # upsert into settings table
  sqlite3 "$DB" "UPDATE settings SET value='$2' WHERE key='$1';
                 INSERT INTO settings(key,value) SELECT '$1','$2'
                 WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$1');"
}
log "configuring panel"
$XUI setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" \
  -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1 -webCert "$CERT" -webCertKey "$KEY" >/dev/null
setkv subEnable true
setkv subListen 127.0.0.1
setkv subPort "$SUB_PORT"
setkv subPath "/$SUB_PATH/"
setkv subJsonPath "/$SUBJSON_PATH/"
setkv subURI "https://$DOMAIN/$SUB_PATH/"
setkv subJsonURI "https://$DOMAIN/$SUBJSON_PATH/"
setkv subCertFile "$CERT"
setkv subKeyFile "$KEY"
setkv subUpdates 12
setkv timeLocation Europe/Moscow

systemctl start x-ui
for _ in $(seq 1 30); do ! port_free "$PANEL_PORT" && break; sleep 1; done
port_free "$PANEL_PORT" && die "panel did not start (journalctl -u x-ui)"

TOKEN=$($XUI setting -getApiToken -tokenName deploy 2>/dev/null | grep -oE '[A-Za-z0-9_.-]{20,}' | tail -1)
[[ -n "$TOKEN" ]] || die "could not get API token from x-ui"
API="https://127.0.0.1:$PANEL_PORT/$PANEL_PATH"
api_add() {  # $1 = inbound JSON
  local r; r=$(curl -sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
              -X POST -d "$1" "$API/panel/api/inbounds/add")
  [[ $(jq -r .success <<<"$r") == true ]] || die "inbound add failed: $(jq -r .msg <<<"$r")"
  echo "    + $(jq -r .obj.remark <<<"$r")"
}
# builds the body expected by /panel/api/inbounds/add
inbound() {  # remark listen port protocol settings stream sniffing
  jq -cn --arg remark "$1" --arg listen "$2" --argjson port "$3" --arg proto "$4" \
         --arg s "$5" --arg st "$6" --arg sn "$7" \
    '{up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:$listen,
      port:$port,protocol:$proto,settings:$s,streamSettings:$st,sniffing:$sn}'
}
client() {  # email [flow] [password]
  jq -cn --arg email "$1" --arg flow "${2:-}" --arg pw "${3:-}" --arg sub "$SUB_ID" \
         --arg id "$(cat /proc/sys/kernel/random/uuid)" \
    '{id:$id,password:$pw,flow:$flow,email:$email,limitIp:0,totalGB:0,expiryTime:0,
      enable:true,tgId:0,subId:$sub,comment:"",reset:0}'
}
SNIFF_ON='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
SNIFF_OFF='{"enabled":false,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
EXT_TLS=$(jq -cn --arg d "$DOMAIN" '[{forceTls:"tls",dest:$d,port:443,remark:""}]')

log "creating inbounds"
# 1) VLESS Reality + Vision, behind nginx stream (PROXY protocol)
KEYS=$($XRAY x25519)
PRIV=$(awk -F': *' '/^Private ?[Kk]ey/{print $2}' <<<"$KEYS")
PUB=$(awk -F': *' '/Public ?[Kk]ey|^Password/{print $2; exit}' <<<"$KEYS")
[[ -n "$PRIV" && -n "$PUB" ]] || die "cannot parse xray x25519 output"
SID=$(rnd_hex 8)
S=$(jq -cn --argjson c "$(client "$CLIENT_NAME-reality" xtls-rprx-vision)" '{clients:[$c],decryption:"none",fallbacks:[]}')
ST=$(jq -cn --arg sni "$REALITY_SNI" --arg priv "$PRIV" --arg pub "$PUB" --arg sid "$SID" --arg ip "$IP" \
  '{network:"tcp",security:"reality",
    tcpSettings:{acceptProxyProtocol:true,header:{type:"none"}},
    realitySettings:{show:false,xver:0,target:($sni+":443"),serverNames:[$sni],privateKey:$priv,
      minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],
      settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}},
    externalProxy:[{forceTls:"same",dest:$ip,port:443,remark:""}]}')
api_add "$(inbound "$REMARK reality" 127.0.0.1 "$REALITY_PORT" vless "$S" "$ST" "$SNIFF_ON")"

# 2) VLESS WS (TLS terminated by nginx)
S=$(jq -cn --argjson c "$(client "$CLIENT_NAME-ws")" '{clients:[$c],decryption:"none",fallbacks:[]}')
ST=$(jq -cn --arg p "/$WS_PATH" --arg h "$DOMAIN" --argjson ext "$EXT_TLS" \
  '{network:"ws",security:"none",wsSettings:{acceptProxyProtocol:false,path:$p,host:$h,headers:{}},externalProxy:$ext}')
api_add "$(inbound "$REMARK ws" 127.0.0.1 "$WS_PORT" vless "$S" "$ST" "$SNIFF_OFF")"

# 3) VLESS XHTTP on a unix socket (nginx grpc_pass, h2c)
S=$(jq -cn --argjson c "$(client "$CLIENT_NAME-xhttp")" '{clients:[$c],decryption:"none",fallbacks:[]}')
ST=$(jq -cn --arg p "/$XHTTP_PATH" --arg h "$DOMAIN" --argjson ext "$EXT_TLS" \
  '{network:"xhttp",security:"none",
    xhttpSettings:{path:$p,host:$h,headers:{},mode:"packet-up",xPaddingBytes:"100-1000",
      scMaxBufferedPosts:30,scMaxEachPostBytes:"1000000",noSSEHeader:false},
    externalProxy:$ext}')
api_add "$(inbound "$REMARK xhttp" "$XHTTP_SOCK,0666" 0 vless "$S" "$ST" "$SNIFF_ON")"

# 4) Trojan gRPC
S=$(jq -cn --argjson c "$(client "$CLIENT_NAME-grpc" "" "$(rnd 16)")" '{clients:[$c],fallbacks:[]}')
ST=$(jq -cn --arg svc "/$GRPC_SVC" --arg h "$DOMAIN" --argjson ext "$EXT_TLS" \
  '{network:"grpc",security:"none",grpcSettings:{serviceName:$svc,authority:$h,multiMode:false},externalProxy:$ext}')
api_add "$(inbound "$REMARK trojan-grpc" 127.0.0.1 "$GRPC_PORT" trojan "$S" "$ST" "$SNIFF_OFF")"

# the deploy token is no longer needed
systemctl stop x-ui
sqlite3 "$DB" "DELETE FROM api_tokens WHERE name='deploy';" 2>/dev/null || true
systemctl start x-ui

# ---------- nginx ------------------------------------------------------------
log "configuring nginx"
grep -q '^stream' /etc/nginx/nginx.conf \
  || echo 'stream { include /etc/nginx/stream-enabled/*.conf; }' >> /etc/nginx/nginx.conf
mkdir -p /etc/nginx/stream-enabled
rm -f /etc/nginx/sites-enabled/default
# listen on IPv6 only if the host has it, otherwise nginx refuses to start
if [[ -f /proc/net/if_inet6 ]]; then L6_443='listen [::]:443;'; L6_80='listen [::]:80;'; else L6_443=''; L6_80=''; fi

cat > /etc/nginx/stream-enabled/3xui-sni.conf <<EOF
map \$ssl_preread_server_name \$sni_backend {
    hostnames;
    $DOMAIN    www;
    default    reality;
}
upstream reality { server 127.0.0.1:$REALITY_PORT; }
upstream www     { server 127.0.0.1:$WWW_PORT; }
server {
    listen 443;
    $L6_443
    ssl_preread on;
    proxy_protocol on;
    proxy_pass \$sni_backend;
}
EOF

PROXY_HDRS='proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;'

cat > /etc/nginx/sites-available/3xui.conf <<EOF
server {
    listen 80;
    $L6_80
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 127.0.0.1:$WWW_PORT ssl http2 proxy_protocol;
    server_name $DOMAIN;
    server_tokens off;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    absolute_redirect off;
    root /var/www/3xui-decoy;
    index index.html;

    ssl_certificate     $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    http2_body_preread_size 128k;
    client_body_buffer_size 512k;

    # 3x-ui panel
    location /$PANEL_PATH/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        $PROXY_HDRS
        proxy_read_timeout 3600s;
        proxy_pass https://127.0.0.1:$PANEL_PORT;
    }
    location = /$PANEL_PATH { return 301 /$PANEL_PATH/; }

    # subscriptions
    location /$SUB_PATH/     { $PROXY_HDRS proxy_pass https://127.0.0.1:$SUB_PORT; }
    location /$SUBJSON_PATH/ { $PROXY_HDRS proxy_pass https://127.0.0.1:$SUB_PORT; }
    location /assets/        { proxy_pass https://127.0.0.1:$SUB_PORT; }

    # VLESS XHTTP -> unix socket
    location /$XHTTP_PATH {
        client_max_body_size 0;
        grpc_pass grpc://unix:$XHTTP_SOCK;
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Connection "";
        grpc_set_header Host \$host;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # VLESS WebSocket
    location /$WS_PATH {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        $PROXY_HDRS
        proxy_read_timeout 1d;
        proxy_buffering off;
        proxy_pass http://127.0.0.1:$WS_PORT;
    }

    # Trojan gRPC
    location /$GRPC_SVC {
        client_max_body_size 0;
        grpc_pass grpc://127.0.0.1:$GRPC_PORT;
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
        grpc_socket_keepalive on;
        grpc_set_header X-Real-IP \$remote_addr;
    }

    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/3xui.conf /etc/nginx/sites-enabled/3xui.conf

mkdir -p /var/www/3xui-decoy
cat > /var/www/3xui-decoy/index.html <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Welcome</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:15vh auto;padding:0 16px;color:#333}</style>
</head><body><h1>It works</h1><p>This server is up and running.</p></body></html>
EOF

nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx config test failed"; }
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

# ---------- self-test --------------------------------------------------------
log "self-test"
sleep 3
ok=1
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/$PANEL_PATH/")
[[ "$code" == 200 ]] && echo "    panel ............ OK" || { echo "    panel ............ FAIL ($code)"; ok=0; }
SUB=$(curl -s --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/$SUB_PATH/$SUB_ID" || true)
grep -q '://' <<<"$SUB" || SUB=$(base64 -d <<<"$SUB" 2>/dev/null || true)
n=$(grep -cE '^(vless|trojan)://' <<<"$SUB" || true)
[[ "$n" == 4 ]] && echo "    subscription ..... OK (4 links)" || { echo "    subscription ..... FAIL ($n links)"; ok=0; }
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$REALITY_SNI:443:127.0.0.1" "https://$REALITY_SNI/" || true)
[[ "$code" != 000 ]] && echo "    reality via 443 .. OK (target answered $code)" || { echo "    reality via 443 .. FAIL"; ok=0; }
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/$XHTTP_PATH/x" || true)
[[ "$code" =~ ^4 ]] && echo "    xhttp path ....... OK ($code from xray)" || { echo "    xhttp path ....... FAIL ($code)"; ok=0; }

# ---------- summary ----------------------------------------------------------
INFO=/root/3xui-info.txt
cat > "$INFO" <<EOF
3x-ui deployed $(date '+%F %T')  ($XUI_VERSION)
Server IP     : $IP
Domain        : $DOMAIN
Panel         : https://$DOMAIN/$PANEL_PATH/
Login         : $PANEL_USER
Password      : $PANEL_PASS
Subscription  : https://$DOMAIN/$SUB_PATH/$SUB_ID
JSON sub      : https://$DOMAIN/$SUBJSON_PATH/$SUB_ID
Reality SNI   : $REALITY_SNI   (shortId $SID)
Internal ports: panel $PANEL_PORT, sub $SUB_PORT, reality $REALITY_PORT, ws $WS_PORT, grpc $GRPC_PORT
EOF
chmod 600 "$INFO"
echo
cat "$INFO"
echo
[[ $ok == 1 ]] && log "done. Credentials saved to $INFO" \
               || warn "deployed with failed checks above; see journalctl -u x-ui and /var/log/nginx/error.log"
