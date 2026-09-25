#!/usr/bin/env bash
#
# setup-cloudflare-vpn.sh — one-paste VLESS + WebSocket + TLS behind Cloudflare.
#
# This builds the VPN that routes THROUGH Cloudflare's CDN (orange cloud), so
# Iran sees only Cloudflare's shared IP — which is impractical to block. It uses
# WebSocket+TLS (which Cloudflare proxies), NOT Reality (which Cloudflare breaks).
#
# What it does on your VPS (Debian/Ubuntu):
#   * installs Xray, Caddy, qrencode
#   * generates a UUID + a secret WebSocket path
#   * creates an origin TLS cert (self-signed by default; or bring a Cloudflare
#     Origin Certificate with --cert/--key)
#   * runs Caddy on :443 -> serves a decoy site on "/" and forwards ONLY the
#     secret path to Xray (VLESS+WS on 127.0.0.1:8080)
#   * opens the firewall and prints the client link + QR for Hiddify
#
# Usage:
#   sudo ./setup-cloudflare-vpn.sh --domain mooooz.lol
#   sudo ./setup-cloudflare-vpn.sh --domain mooooz.lol --cert origin.pem --key origin.key
#
# Options:
#   --domain <host>   REQUIRED. The Cloudflare-fronted hostname (orange cloud).
#   --cert <file>     Cloudflare Origin Certificate (use SSL mode "Full (strict)").
#   --key  <file>     ...its private key. If omitted, a self-signed cert is made
#                     and you use SSL mode "Full".
#   --uuid <uuid>     Reuse a specific UUID (default: generated).
#   --path </p>       Reuse a specific WS path (default: /<random>).
#   --name <label>    Label shown in the client app (default: derived from domain).
#
# AFTER running, do 3 things in the Cloudflare dashboard (it can't be scripted
# without an API token): (1) DNS: A record <domain> -> this VPS IP, PROXIED
# (orange cloud). (2) SSL/TLS mode: Full (or Full (strict) if you used --cert).
# (3) leave WebSockets ON (default). Then import the printed link into Hiddify.
#
set -euo pipefail

DOMAIN=""; CERT=""; KEY=""; UUID=""; WSPATH=""; NAME=""
PUBLIC_PORT=443
XRAY_LOCAL_PORT=8080
CERT_DIR=/etc/ssl/cf-vpn
DECOY_DIR=/var/www/decoy

log()  { printf '\033[1;36m[cf-vpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cf-vpn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[cf-vpn] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --cert)   CERT="${2:-}"; shift 2 ;;
    --key)    KEY="${2:-}"; shift 2 ;;
    --uuid)   UUID="${2:-}"; shift 2 ;;
    --path)   WSPATH="${2:-}"; shift 2 ;;
    --name)   NAME="${2:-}"; shift 2 ;;
    --port)   PUBLIC_PORT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)."
[ -n "$DOMAIN" ] || die "--domain is required (e.g. --domain mooooz.lol)"
command -v apt-get >/dev/null 2>&1 || die "this script targets Debian/Ubuntu (apt). Install Xray+Caddy manually otherwise."
[ -n "$NAME" ] || NAME="CF-${DOMAIN}"

# WS path must start with a single slash.
if [ -z "$WSPATH" ]; then WSPATH="/$(openssl rand -hex 6)"; fi
case "$WSPATH" in /*) ;; *) WSPATH="/$WSPATH" ;; esac

if [ -n "$CERT" ] && [ -z "$KEY" ]; then die "--cert given without --key"; fi
if [ -n "$KEY" ] && [ -z "$CERT" ]; then die "--key given without --cert"; fi

# Warn if something already holds the public port (e.g. an old Reality Xray).
if ss -tlnp 2>/dev/null | grep -q ":${PUBLIC_PORT} "; then
  warn "something is already listening on :${PUBLIC_PORT}. Caddy needs it."
  warn "If that's an old proxy on this box, stop it or use a different --port."
fi

# ---------------------------------------------------------------------------
log "installing dependencies (this can take a minute)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl openssl qrencode ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https

# ---- Xray ----
if ! command -v xray >/dev/null 2>&1; then
  log "installing Xray-core…"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# ---- Caddy ----
if ! command -v caddy >/dev/null 2>&1; then
  log "installing Caddy…"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

# ---- IDs ----
if [ -z "$UUID" ]; then
  UUID="$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
fi

# ---- Origin certificate ----
mkdir -p "$CERT_DIR"
if [ -n "$CERT" ]; then
  log "using provided Cloudflare Origin certificate"
  install -m 644 "$CERT" "$CERT_DIR/origin.pem"
  install -m 600 "$KEY"  "$CERT_DIR/origin.key"
  CF_SSL_MODE="Full (strict)"
else
  log "generating a self-signed origin certificate for $DOMAIN"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$CERT_DIR/origin.key" -out "$CERT_DIR/origin.pem" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  chmod 600 "$CERT_DIR/origin.key"
  CF_SSL_MODE="Full"
fi

# ---- Xray config (VLESS + WS on localhost; TLS handled by Caddy) ----
log "writing Xray config…"
mkdir -p /usr/local/etc/xray
cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_LOCAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WSPATH}" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF

# ---- Decoy website ----
mkdir -p "$DECOY_DIR"
if [ ! -f "$DECOY_DIR/index.html" ]; then
  cat >"$DECOY_DIR/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:8vh auto;padding:0 20px;color:#222;line-height:1.6}h1{font-weight:600}</style>
</head><body><h1>It works</h1>
<p>This site is running. Content is coming soon.</p></body></html>
EOF
fi

# ---- Caddy config ----
log "writing Caddyfile…"
cat >/etc/caddy/Caddyfile <<EOF
{
	auto_https disable_redirects
}

${DOMAIN}:${PUBLIC_PORT} {
	tls ${CERT_DIR}/origin.pem ${CERT_DIR}/origin.key

	@vpn path ${WSPATH}
	reverse_proxy @vpn 127.0.0.1:${XRAY_LOCAL_PORT}

	root * ${DECOY_DIR}
	file_server
}
EOF

log "validating Caddy config…"
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

# ---- Firewall ----
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PUBLIC_PORT}"/tcp >/dev/null 2>&1 || true
fi

# ---- Start services ----
log "starting services…"
systemctl enable --now xray >/dev/null 2>&1 || systemctl restart xray
systemctl restart xray
systemctl enable --now caddy >/dev/null 2>&1 || true
systemctl reload caddy 2>/dev/null || systemctl restart caddy

sleep 1
systemctl is-active --quiet xray  || warn "xray is not active — check: journalctl -u xray -e"
systemctl is-active --quiet caddy || warn "caddy is not active — check: journalctl -u caddy -e"

# ---- Client link + QR ----
enc_path="$(printf '%s' "$WSPATH" | sed 's,/,%2F,g')"
LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${enc_path}#${NAME}"

echo
echo "==================================================================="
echo " Cloudflare-fronted VLESS+WS VPN is set up on this server."
echo "==================================================================="
echo
echo " Now finish in the Cloudflare dashboard:"
echo "   1) DNS: A record  ${DOMAIN}  ->  $(curl -fsS https://api.ipify.org 2>/dev/null || echo THIS_VPS_IP)   [ PROXIED / orange cloud ]"
echo "   2) SSL/TLS mode:  ${CF_SSL_MODE}"
echo "   3) WebSockets:    ON  (default)"
echo
echo " Client details:"
echo "   Host/SNI : ${DOMAIN}"
echo "   Port     : 443"
echo "   UUID     : ${UUID}"
echo "   Network  : ws"
echo "   Path     : ${WSPATH}"
echo
echo " Import link (paste into Hiddify / v2rayNG / NekoBox):"
echo
echo "   ${LINK}"
echo
if command -v qrencode >/dev/null 2>&1; then
  echo " Or scan this QR:"
  qrencode -t ANSIUTF8 "$LINK"
fi
echo
echo " Notes:"
echo "  * Reality does NOT work behind Cloudflare — this uses WS+TLS on purpose."
echo "  * IP is safe (Cloudflare's), but the hostname's SNI can still be filtered"
echo "    and TLS-in-TLS is detectable. Run this as a SECONDARY alongside Reality."
echo "  * Logs: journalctl -u xray -f   |   journalctl -u caddy -f"
echo "==================================================================="
