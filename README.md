# deploy-3xui

One-command install of **3x-ui** behind **nginx** on a fresh Ubuntu/Debian VPS.

Everything goes through port **443** (nginx routes by SNI):

| Inbound | Transport |
|---|---|
| VLESS + Reality + Vision | TCP, behind nginx (PROXY protocol) |
| VLESS XHTTP | TLS (Let's Encrypt), unix socket |
| VLESS WebSocket | TLS (Let's Encrypt) |
| Trojan gRPC | TLS (Let's Encrypt) |

Plus: subscription link for all four, panel hidden behind a random path, BBR, ufw (only ssh/80/443 open),
automatic certificate renewal. Domain defaults to `<server-ip>.cdn-one.org`, so no own domain is needed.

## Install

As root on a clean server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Zippo102-89/deploy-3xui/main/deploy-3xui.sh)
```

With your own domain (A-record must point to the server):

```bash
DOMAIN=vpn.example.com bash <(curl -fsSL https://raw.githubusercontent.com/Zippo102-89/deploy-3xui/main/deploy-3xui.sh)
```

After 2вЂ“3 minutes it prints the panel URL, login, password and the subscription link.
They are also saved to `/root/3xui-info.txt`.

## Options

| Variable | Default | Meaning |
|---|---|---|
| `DOMAIN` | `<ip>.cdn-one.org` | domain for TLS, panel and subscription |
| `REALITY_SNI` | `www.max.ru` | site Reality pretends to be |
| `PANEL_USER` / `PANEL_PASS` | random | panel credentials |
| `CLIENT_NAME` | `user1` | first client |
| `ENABLE_UFW` | `1` | `0` = don't touch the firewall |
| `XUI_VERSION` | latest | e.g. `v3.10.2` |
| `FORCE` | `0` | `1` = reinstall over existing 3x-ui (old DB is backed up) |

Requirements: Ubuntu 22.04+/Debian 12+, amd64 or arm64, ports 80 and 443 free.
