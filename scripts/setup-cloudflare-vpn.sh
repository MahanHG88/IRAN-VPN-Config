#!/usr/bin/env bash
#
# setup-cloudflare-vpn.sh — safe, idempotent VLESS + WebSocket + TLS behind Cloudflare.
#
# Builds the VPN that routes THROUGH Cloudflare's CDN (orange cloud), so Iran
# sees only Cloudflare's shared IP — impractical to block. Uses WebSocket+TLS
# (which Cloudflare proxies), NOT Reality (which Cloudflare breaks).
#
# NON-DESTRUCTIVE BY DESIGN:
#   * installs Xray / Caddy only if missing (reports what it finds)
#   * MERGES into existing configs instead of overwriting:
#       - Xray: adds a tagged "cfvpn-ws" inbound next to your existing inbounds
#       - Caddy: writes /etc/caddy/conf.d/cf-vpn.caddy and adds an import line
#   * backs up every file it changes (<file>.bak.<timestamp>)
#   * validates Xray and Caddy configs BEFORE restarting; restores + aborts on error
#   * auto-picks a free local port; detects :443 conflicts and warns
#   * safe to re-run: updates its own inbound/snippet, never duplicates
#
# Usage:
#   sudo ./setup-cloudflare-vpn.sh --domain mooooz.lol
#   sudo ./setup-cloudflare-vpn.sh --domain mooooz.lol --cert origin.pem --key origin.key
#
# Options:
#   --domain <host>   REQUIRED. The Cloudflare-fronted hostname (orange cloud).
#   --cert <file>     Cloudflare Origin Certificate (then use SSL mode "Full (strict)").
#   --key  <file>     ...its private key. If omitted, a self-signed cert is made
#                     and you use SSL mode "Full".
#   --uuid <uuid>     Reuse a specific UUID (default: generated / reused if present).
#   --path </p>       Reuse a specific WS path (default: /<random>, or existing).
#   --name <label>    Label shown in the client app (default: CF-<domain>).
#   --port <n>        Public HTTPS port Caddy binds (default: 443).
#   --uninstall       Remove ONLY what this script added (its inbound, snippet,
#                     decoy, cert) and leave the rest of Xray/Caddy intact.
#
# After running, in the Cloudflare dashboard: (1) DNS A record <domain> -> this
# VPS IP, PROXIED (orange). (2) SSL/TLS mode: Full (or Full (strict) with --cert).
# (3) WebSockets ON (default). Then import the printed link into Hiddify.
#
set -euo pipefail

DOMAIN=""; CERT=""; KEY=""; UUID=""; WSPATH=""; NAME=""; UNINSTALL=0
PUBLIC_PORT=443
XRAY_CONF=/usr/local/etc/xray/config.json
CADDY_MAIN=/etc/caddy/Caddyfile
CADDY_SNIPPET_DIR=/etc/caddy/conf.d
CADDY_SNIPPET=/etc/caddy/conf.d/cf-vpn.caddy
CERT_DIR=/etc/ssl/cf-vpn
DECOY_DIR=/var/www/cf-vpn-decoy
XRAY_TAG="cfvpn-ws"
STAMP="$(date +%Y%m%d%H%M%S)"

log()  { printf '\033[1;36m[cf-vpn]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cf-vpn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[cf-vpn] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

backup() { # back up a file if it exists; echoes the backup path
  [ -f "$1" ] || return 0
  cp -a "$1" "$1.bak.$STAMP"
  log "backed up $1 -> $1.bak.$STAMP"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --cert)   CERT="${2:-}"; shift 2 ;;
    --key)    KEY="${2:-}"; shift 2 ;;
    --uuid)   UUID="${2:-}"; shift 2 ;;
    --path)   WSPATH="${2:-}"; shift 2 ;;
    --name)   NAME="${2:-}"; shift 2 ;;
    --port)   PUBLIC_PORT="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)."
command -v apt-get >/dev/null 2>&1 || die "this script targets Debian/Ubuntu (apt)."

# ---------------------------------------------------------------------------
# UNINSTALL: remove only what we added.
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  log "uninstalling cf-vpn additions (leaving the rest intact)…"
  if [ -f "$XRAY_CONF" ] && command -v jq >/dev/null 2>&1 && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
    backup "$XRAY_CONF"
    tmp="$(mktemp)"
    jq --arg tag "$XRAY_TAG" '.inbounds |= map(select(.tag != $tag))' "$XRAY_CONF" > "$tmp" && mv "$tmp" "$XRAY_CONF"
    log "removed the $XRAY_TAG inbound from Xray"
    systemctl restart xray 2>/dev/null || true
  fi
  if [ -f "$CADDY_SNIPPET" ]; then
    rm -f "$CADDY_SNIPPET"; log "removed $CADDY_SNIPPET"
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
  fi
  log "left in place (delete manually if you want): $CERT_DIR, $DECOY_DIR"
  log "done."
  exit 0
fi

[ -n "$DOMAIN" ] || die "--domain is required (e.g. --domain mooooz.lol)"
[ -n "$NAME" ] || NAME="CF-${DOMAIN}"
if [ -n "$CERT" ] && [ -z "$KEY" ]; then die "--cert given without --key"; fi
if [ -n "$KEY" ] && [ -z "$CERT" ]; then die "--key given without --cert"; fi

# WS path must start with a single slash.
if [ -z "$WSPATH" ]; then WSPATH="/$(openssl rand -hex 6 2>/dev/null || head -c6 /dev/urandom | xxd -p)"; fi
case "$WSPATH" in /*) ;; *) WSPATH="/$WSPATH" ;; esac

# ---------------------------------------------------------------------------
# Dependencies (install only what's missing).
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
need_apt_update=1
apt_install() {
  [ "$need_apt_update" -eq 1 ] && { apt-get update -y >/dev/null; need_apt_update=0; }
  apt-get install -y "$@" >/dev/null
}

log "checking base tools…"
for pkg in curl openssl jq qrencode ca-certificates; do
  command -v "${pkg/ca-certificates/update-ca-certificates}" >/dev/null 2>&1 || apt_install "$pkg"
done
command -v jq >/dev/null 2>&1 || apt_install jq
command -v qrencode >/dev/null 2>&1 || apt_install qrencode

# ---- Xray (detect / install) ----
if command -v xray >/dev/null 2>&1; then
  log "Xray: already installed ($(xray version 2>/dev/null | head -1 || echo present)) — leaving it as is"
else
  log "Xray: not found — installing Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# ---- Caddy (detect / install) ----
if command -v caddy >/dev/null 2>&1; then
  log "Caddy: already installed ($(caddy version 2>/dev/null | head -1 || echo present)) — leaving it as is"
else
  log "Caddy: not found — installing Caddy"
  apt_install debian-keyring debian-archive-keyring apt-transport-https gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  need_apt_update=1; apt_install caddy
fi

# ---------------------------------------------------------------------------
# IDs, cert, decoy.
# ---------------------------------------------------------------------------
# Reuse an existing cfvpn-ws UUID if present (idempotent re-runs).
if [ -z "$UUID" ] && [ -f "$XRAY_CONF" ] && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
  UUID="$(jq -r --arg t "$XRAY_TAG" '(.inbounds[]? | select(.tag==$t) | .settings.clients[0].id) // empty' "$XRAY_CONF" 2>/dev/null | head -1)"
fi
[ -n "$UUID" ] || UUID="$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"

mkdir -p "$CERT_DIR"
if [ -n "$CERT" ]; then
  log "using provided Cloudflare Origin certificate"
  install -m 644 "$CERT" "$CERT_DIR/origin.pem"
  install -m 600 "$KEY"  "$CERT_DIR/origin.key"
  CF_SSL_MODE="Full (strict)"
elif [ -f "$CERT_DIR/origin.pem" ] && [ -f "$CERT_DIR/origin.key" ]; then
  log "reusing existing origin certificate in $CERT_DIR"
  CF_SSL_MODE="Full"
else
  log "generating a self-signed origin certificate for $DOMAIN"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$CERT_DIR/origin.key" -out "$CERT_DIR/origin.pem" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  chmod 600 "$CERT_DIR/origin.key"
  CF_SSL_MODE="Full"
fi

mkdir -p "$DECOY_DIR"
[ -f "$DECOY_DIR/index.html" ] || cat >"$DECOY_DIR/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:8vh auto;padding:0 20px;color:#222;line-height:1.6}h1{font-weight:600}</style>
</head><body><h1>It works</h1><p>This site is running. Content is coming soon.</p></body></html>
EOF

# ---------------------------------------------------------------------------
# Pick a free local port for the Xray WS inbound (avoid existing inbounds + listeners).
# ---------------------------------------------------------------------------
declare -a used_ports=()
if [ -f "$XRAY_CONF" ] && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
  # Reuse our own inbound's port if it already exists.
  existing_port="$(jq -r --arg t "$XRAY_TAG" '(.inbounds[]? | select(.tag==$t) | .port) // empty' "$XRAY_CONF" | head -1)"
  mapfile -t used_ports < <(jq -r '.inbounds[]?.port // empty' "$XRAY_CONF" 2>/dev/null)
fi
port_in_use() {
  local p="$1" u
  for u in "${used_ports[@]:-}"; do [ "$u" = "$p" ] && return 0; done
  ss -tlnH 2>/dev/null | grep -qE "127\.0\.0\.1:$p |0\.0\.0\.0:$p |\[::\]:$p " && return 0
  return 1
}
if [ -n "${existing_port:-}" ]; then
  XRAY_LOCAL_PORT="$existing_port"
  log "reusing existing $XRAY_TAG local port $XRAY_LOCAL_PORT"
else
  XRAY_LOCAL_PORT=8080
  while port_in_use "$XRAY_LOCAL_PORT"; do XRAY_LOCAL_PORT=$((XRAY_LOCAL_PORT+1)); done
  log "using local port $XRAY_LOCAL_PORT for the WS inbound"
fi

# ---------------------------------------------------------------------------
# Xray config: MERGE our inbound, never clobber.
# ---------------------------------------------------------------------------
our_inbound="$(jq -n --arg id "$UUID" --arg path "$WSPATH" --argjson port "$XRAY_LOCAL_PORT" --arg tag "$XRAY_TAG" '
  { listen:"127.0.0.1", port:$port, protocol:"vless", tag:$tag,
    settings:{ clients:[{id:$id}], decryption:"none" },
    streamSettings:{ network:"ws", wsSettings:{ path:$path } } }')"

if [ -f "$XRAY_CONF" ] && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
  log "merging WS inbound into existing Xray config"
  backup "$XRAY_CONF"
  tmp="$(mktemp)"
  jq --argjson inb "$our_inbound" --arg t "$XRAY_TAG" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $t)) + [$inb])
    | (if ((.outbounds // []) | length) == 0 then .outbounds = [{protocol:"freedom",tag:"direct"}] else . end)
  ' "$XRAY_CONF" > "$tmp" && mv "$tmp" "$XRAY_CONF"
else
  log "no existing Xray config — writing a fresh one"
  mkdir -p "$(dirname "$XRAY_CONF")"
  jq -n --argjson inb "$our_inbound" '{log:{loglevel:"warning"},inbounds:[$inb],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$XRAY_CONF"
fi

# Validate Xray before touching the running service.
if ! xray -test -config "$XRAY_CONF" >/tmp/cfvpn-xray-test.log 2>&1; then
  warn "Xray config test FAILED — restoring backup and aborting:"; cat /tmp/cfvpn-xray-test.log >&2
  [ -f "$XRAY_CONF.bak.$STAMP" ] && cp -a "$XRAY_CONF.bak.$STAMP" "$XRAY_CONF"
  die "no changes applied to the running Xray."
fi

# ---------------------------------------------------------------------------
# Caddy config: separate snippet + import, never clobber the main Caddyfile.
# ---------------------------------------------------------------------------
mkdir -p "$CADDY_SNIPPET_DIR"
# Using the https:// scheme prefix disables the automatic :80 redirect for this
# site, so we don't need a global options block (which would clash with yours).
cat >"$CADDY_SNIPPET" <<EOF
https://${DOMAIN}:${PUBLIC_PORT} {
	tls ${CERT_DIR}/origin.pem ${CERT_DIR}/origin.key

	@vpn path ${WSPATH}
	reverse_proxy @vpn 127.0.0.1:${XRAY_LOCAL_PORT}

	root * ${DECOY_DIR}
	file_server
}
EOF
log "wrote Caddy snippet $CADDY_SNIPPET"

if [ -f "$CADDY_MAIN" ]; then
  if ! grep -qE '^\s*import\s+conf\.d/\*\.caddy' "$CADDY_MAIN"; then
    backup "$CADDY_MAIN"
    printf '\nimport conf.d/*.caddy\n' >> "$CADDY_MAIN"
    log "added 'import conf.d/*.caddy' to $CADDY_MAIN"
  else
    log "$CADDY_MAIN already imports conf.d — left unchanged"
  fi
else
  printf 'import conf.d/*.caddy\n' > "$CADDY_MAIN"
  log "created minimal $CADDY_MAIN with conf.d import"
fi

# Validate Caddy before reloading.
if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile >/tmp/cfvpn-caddy-test.log 2>&1; then
  warn "Caddy config test FAILED — reverting our changes and aborting:"; cat /tmp/cfvpn-caddy-test.log >&2
  rm -f "$CADDY_SNIPPET"
  [ -f "$CADDY_MAIN.bak.$STAMP" ] && cp -a "$CADDY_MAIN.bak.$STAMP" "$CADDY_MAIN"
  die "no changes applied to the running Caddy."
fi

# ---------------------------------------------------------------------------
# Port 443 conflict check (warn, don't clobber).
# ---------------------------------------------------------------------------
holder="$(ss -tlnpH 2>/dev/null | awk -v p=":${PUBLIC_PORT}" '$4 ~ p"$" {print $0}' | grep -oE 'users:\(\("[^"]+' | grep -oE '[^"]+$' | head -1 || true)"
if [ -n "$holder" ] && [ "$holder" != "caddy" ]; then
  warn "port ${PUBLIC_PORT} is currently held by '$holder', not Caddy."
  warn "Caddy needs ${PUBLIC_PORT}. If '$holder' is another proxy (e.g. Reality on 443),"
  warn "either move it, use --port, or run this CDN setup on a separate VPS."
fi

# ---------------------------------------------------------------------------
# Start / reload services.
# ---------------------------------------------------------------------------
log "restarting Xray and reloading Caddy…"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
systemctl enable caddy >/dev/null 2>&1 || true
systemctl reload caddy 2>/dev/null || systemctl restart caddy

sleep 1
systemctl is-active --quiet xray  || warn "xray is not active — check: journalctl -u xray -e"
systemctl is-active --quiet caddy || warn "caddy is not active — check: journalctl -u caddy -e"

# ---------------------------------------------------------------------------
# Client link + QR.
# ---------------------------------------------------------------------------
enc_path="$(printf '%s' "$WSPATH" | sed 's,/,%2F,g')"
LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${enc_path}#${NAME}"
PUBIP="$(curl -fsS https://api.ipify.org 2>/dev/null || echo THIS_VPS_IP)"

echo
echo "==================================================================="
echo " Cloudflare-fronted VLESS+WS VPN is ready (existing setup preserved)."
echo "==================================================================="
echo
echo " Finish in the Cloudflare dashboard:"
echo "   1) DNS: A record  ${DOMAIN}  ->  ${PUBIP}   [ PROXIED / orange cloud ]"
echo "   2) SSL/TLS mode:  ${CF_SSL_MODE}"
echo "   3) WebSockets:    ON (default)"
echo
echo " Client:  Host/SNI ${DOMAIN} · Port 443 · ws · path ${WSPATH}"
echo "          UUID ${UUID}"
echo
echo " Import link (paste into Hiddify / v2rayNG / NekoBox):"
echo
echo "   ${LINK}"
echo
if command -v qrencode >/dev/null 2>&1; then echo " Or scan:"; qrencode -t ANSIUTF8 "$LINK"; fi
echo
echo " Backups (if any) end in .bak.${STAMP}.  Undo everything with: sudo $0 --uninstall"
echo " Reality does NOT work behind Cloudflare — this is WS+TLS on purpose."
echo " Run it as a SECONDARY next to a direct Reality server."
echo "==================================================================="
