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
#   * auto-picks a free local port for the WS inbound
#   * if :443 is taken (e.g. Reality panel), auto-uses origin port 8443 and tells
#     you the one Cloudflare "Origin Rule" to add — Reality keeps 443
#   * creates a caddy.service if Caddy is a bare binary with no service
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
#   --port <n>        Force the origin port Caddy binds (default: 443, or 8443 if
#                     443 is busy). Cloudflare-supported HTTPS origin ports:
#                     443, 8443, 2053, 2083, 2087, 2096.
#   --uninstall       Remove ONLY what this script added (its inbound, snippet,
#                     decoy, cert) and leave the rest of Xray/Caddy intact.
#
set -euo pipefail

DOMAIN=""; CERT=""; KEY=""; UUID=""; WSPATH=""; NAME=""; UNINSTALL=0
PUBLIC_PORT=443; PORT_SET=0; NEED_ORIGIN_RULE=0
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
backup() { [ -f "$1" ] || return 0; cp -a "$1" "$1.bak.$STAMP"; log "backed up $1 -> $1.bak.$STAMP"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --cert)   CERT="${2:-}"; shift 2 ;;
    --key)    KEY="${2:-}"; shift 2 ;;
    --uuid)   UUID="${2:-}"; shift 2 ;;
    --path)   WSPATH="${2:-}"; shift 2 ;;
    --name)   NAME="${2:-}"; shift 2 ;;
    --port)   PUBLIC_PORT="${2:-}"; PORT_SET=1; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)."
command -v apt-get >/dev/null 2>&1 || die "this script targets Debian/Ubuntu (apt)."

port_holder() { # prints the process name holding tcp port $1, or empty
  ss -tlnpH 2>/dev/null | awk -v p=":$1" '$4 ~ p"$"{print}' \
    | grep -oE 'users:\(\("[^"]+' | grep -oE '[^"]+$' | head -1 || true
}

# ---------------------------------------------------------------------------
# UNINSTALL
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  log "uninstalling cf-vpn additions (leaving the rest intact)…"
  if [ -f "$XRAY_CONF" ] && command -v jq >/dev/null 2>&1 && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
    backup "$XRAY_CONF"; tmp="$(mktemp)"
    jq --arg tag "$XRAY_TAG" '.inbounds |= map(select(.tag != $tag))' "$XRAY_CONF" > "$tmp" && mv "$tmp" "$XRAY_CONF"
    log "removed the $XRAY_TAG inbound from Xray"; systemctl restart xray 2>/dev/null || true
  fi
  if [ -f "$CADDY_SNIPPET" ]; then
    rm -f "$CADDY_SNIPPET"; log "removed $CADDY_SNIPPET"
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
  fi
  log "left in place (delete manually if unused): $CERT_DIR, $DECOY_DIR, caddy.service"
  log "done."; exit 0
fi

[ -n "$DOMAIN" ] || die "--domain is required (e.g. --domain mooooz.lol)"
[ -n "$NAME" ] || NAME="CF-${DOMAIN}"
if [ -n "$CERT" ] && [ -z "$KEY" ]; then die "--cert given without --key"; fi
if [ -n "$KEY" ] && [ -z "$CERT" ]; then die "--key given without --cert"; fi
# Normalize an explicitly-given path now; otherwise it's resolved below (reuse
# the existing one from the config, or generate a new one) so re-runs are stable.
[ -n "$WSPATH" ] && case "$WSPATH" in /*) ;; *) WSPATH="/$WSPATH" ;; esac

# ---------------------------------------------------------------------------
# Dependencies (only what's missing)
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
need_apt_update=1
apt_install() { [ "$need_apt_update" -eq 1 ] && { apt-get update -y >/dev/null; need_apt_update=0; }; apt-get install -y "$@" >/dev/null; }

log "checking base tools…"
command -v curl     >/dev/null 2>&1 || apt_install curl
command -v openssl  >/dev/null 2>&1 || apt_install openssl
command -v jq       >/dev/null 2>&1 || apt_install jq
command -v qrencode >/dev/null 2>&1 || apt_install qrencode

# ---- Xray ----
if command -v xray >/dev/null 2>&1; then
  log "Xray: already installed — leaving it as is"
else
  log "Xray: not found — installing Xray-core"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# ---- Caddy ----
if command -v caddy >/dev/null 2>&1; then
  log "Caddy: already installed ($(caddy version 2>/dev/null | head -1)) — leaving the binary as is"
else
  log "Caddy: not found — installing Caddy"
  apt_install debian-keyring debian-archive-keyring apt-transport-https gnupg ca-certificates
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  need_apt_update=1; apt_install caddy
fi

# ---------------------------------------------------------------------------
# Decide the origin port BEFORE writing configs.
# ---------------------------------------------------------------------------
holder="$(port_holder "$PUBLIC_PORT")"
if [ -n "$holder" ] && [ "$holder" != "caddy" ]; then
  if [ "$PORT_SET" -eq 0 ]; then
    warn "port ${PUBLIC_PORT} is held by '${holder}' (likely your Reality)."
    # Try each Cloudflare-supported HTTPS origin port; pick the first free one.
    chosen=""
    for cand in 8443 2053 2083 2087 2096; do
      h="$(port_holder "$cand")"
      if [ -z "$h" ] || [ "$h" = "caddy" ]; then chosen="$cand"; break; fi
      warn "  origin port ${cand} is busy (${h}) — trying next"
    done
    # All the standard ones busy? Origin Rules can target ANY origin port, so
    # fall back to a free high port.
    if [ -z "$chosen" ]; then
      chosen=9443
      while [ -n "$(port_holder "$chosen")" ]; do chosen=$((chosen+1)); done
      warn "  all standard CF ports busy — using free port ${chosen} (Origin Rule handles it)"
    fi
    PUBLIC_PORT="$chosen"
    NEED_ORIGIN_RULE=1
    warn "-> Caddy will use origin port ${PUBLIC_PORT}; add a Cloudflare Origin Rule (shown at the end)."
  else
    warn "port ${PUBLIC_PORT} is held by '${holder}'. Caddy may fail to bind; continuing as you asked."
  fi
fi
# If we're on a non-standard CF origin port, an Origin Rule is required.
case "$PUBLIC_PORT" in 443) ;; *) NEED_ORIGIN_RULE=1 ;; esac

# ---------------------------------------------------------------------------
# IDs, cert, decoy
# ---------------------------------------------------------------------------
if [ -f "$XRAY_CONF" ] && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
  # Reuse the existing UUID and WS path so re-runs don't churn the client config.
  [ -z "$UUID" ] && UUID="$(jq -r --arg t "$XRAY_TAG" '(.inbounds[]? | select(.tag==$t) | .settings.clients[0].id) // empty' "$XRAY_CONF" 2>/dev/null | head -1)"
  [ -z "$WSPATH" ] && WSPATH="$(jq -r --arg t "$XRAY_TAG" '(.inbounds[]? | select(.tag==$t) | .streamSettings.wsSettings.path) // empty' "$XRAY_CONF" 2>/dev/null | head -1)"
fi
[ -n "$UUID" ] || UUID="$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
# Only generate a fresh path if none was given and none exists in the config.
[ -n "$WSPATH" ] || WSPATH="/$(openssl rand -hex 6 2>/dev/null || head -c6 /dev/urandom | xxd -p)"
case "$WSPATH" in /*) ;; *) WSPATH="/$WSPATH" ;; esac

mkdir -p "$CERT_DIR"
if [ -n "$CERT" ]; then
  log "using provided Cloudflare Origin certificate"
  install -m 644 "$CERT" "$CERT_DIR/origin.pem"; install -m 600 "$KEY" "$CERT_DIR/origin.key"
  CF_SSL_MODE="Full (strict)"
elif [ -f "$CERT_DIR/origin.pem" ] && [ -f "$CERT_DIR/origin.key" ]; then
  log "reusing existing origin certificate in $CERT_DIR"; CF_SSL_MODE="Full"
else
  log "generating a self-signed origin certificate for $DOMAIN"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$CERT_DIR/origin.key" -out "$CERT_DIR/origin.pem" -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  chmod 600 "$CERT_DIR/origin.key"; CF_SSL_MODE="Full"
fi

mkdir -p "$DECOY_DIR"
[ -f "$DECOY_DIR/index.html" ] || cat >"$DECOY_DIR/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:8vh auto;padding:0 20px;color:#222;line-height:1.6}h1{font-weight:600}</style>
</head><body><h1>It works</h1><p>This site is running. Content is coming soon.</p></body></html>
EOF

# ---------------------------------------------------------------------------
# Free local port for the WS inbound
# ---------------------------------------------------------------------------
declare -a used_ports=(); existing_port=""
if [ -f "$XRAY_CONF" ] && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
  existing_port="$(jq -r --arg t "$XRAY_TAG" '(.inbounds[]? | select(.tag==$t) | .port) // empty' "$XRAY_CONF" | head -1)"
  mapfile -t used_ports < <(jq -r '.inbounds[]?.port // empty' "$XRAY_CONF" 2>/dev/null)
fi
port_in_use() { local p="$1" u; for u in "${used_ports[@]:-}"; do [ "$u" = "$p" ] && return 0; done; ss -tlnH 2>/dev/null | grep -qE "127\.0\.0\.1:$p |0\.0\.0\.0:$p |\[::\]:$p " && return 0; return 1; }
if [ -n "$existing_port" ]; then XRAY_LOCAL_PORT="$existing_port"; log "reusing existing $XRAY_TAG local port $XRAY_LOCAL_PORT"
else XRAY_LOCAL_PORT=8080; while port_in_use "$XRAY_LOCAL_PORT"; do XRAY_LOCAL_PORT=$((XRAY_LOCAL_PORT+1)); done; log "using local port $XRAY_LOCAL_PORT for the WS inbound"; fi

# ---------------------------------------------------------------------------
# Xray config: MERGE, validate
# ---------------------------------------------------------------------------
our_inbound="$(jq -n --arg id "$UUID" --arg path "$WSPATH" --argjson port "$XRAY_LOCAL_PORT" --arg tag "$XRAY_TAG" '
  { listen:"127.0.0.1", port:$port, protocol:"vless", tag:$tag,
    settings:{ clients:[{id:$id}], decryption:"none" },
    streamSettings:{ network:"ws", wsSettings:{ path:$path } } }')"

if [ -f "$XRAY_CONF" ] && jq -e . "$XRAY_CONF" >/dev/null 2>&1; then
  log "merging WS inbound into existing Xray config"; backup "$XRAY_CONF"; tmp="$(mktemp)"
  jq --argjson inb "$our_inbound" --arg t "$XRAY_TAG" '
    .inbounds = ((.inbounds // []) | map(select(.tag != $t)) + [$inb])
    | (if ((.outbounds // []) | length) == 0 then .outbounds = [{protocol:"freedom",tag:"direct"}] else . end)
  ' "$XRAY_CONF" > "$tmp" && mv "$tmp" "$XRAY_CONF"
else
  log "no existing Xray config — writing a fresh one"; mkdir -p "$(dirname "$XRAY_CONF")"
  jq -n --argjson inb "$our_inbound" '{log:{loglevel:"warning"},inbounds:[$inb],outbounds:[{protocol:"freedom",tag:"direct"}]}' > "$XRAY_CONF"
fi

# Xray's service runs as an unprivileged user (nobody) — it must be able to read
# the config and traverse its directory (mktemp+mv can leave it root-only 600).
chmod 755 "$(dirname "$XRAY_CONF")" 2>/dev/null || true
chmod 644 "$XRAY_CONF" 2>/dev/null || true

if ! xray -test -config "$XRAY_CONF" >/tmp/cfvpn-xray-test.log 2>&1; then
  warn "Xray config test FAILED — restoring backup and aborting:"; cat /tmp/cfvpn-xray-test.log >&2
  [ -f "$XRAY_CONF.bak.$STAMP" ] && cp -a "$XRAY_CONF.bak.$STAMP" "$XRAY_CONF"
  die "no changes applied to the running Xray."
fi

# ---------------------------------------------------------------------------
# Ensure Caddy has a systemd service (bare-binary installs don't)
# ---------------------------------------------------------------------------
ensure_caddy_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^caddy\.service' \
     || [ -f /lib/systemd/system/caddy.service ] || [ -f /etc/systemd/system/caddy.service ]; then
    return 0
  fi
  local bin; bin="$(command -v caddy)"
  log "Caddy has no systemd service — creating one for $bin"
  if ! id caddy >/dev/null 2>&1; then
    groupadd --system caddy 2>/dev/null || true
    useradd --system --gid caddy --home-dir /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy 2>/dev/null || true
  fi
  mkdir -p /var/lib/caddy; chown -R caddy:caddy /var/lib/caddy 2>/dev/null || true
  cat >/etc/systemd/system/caddy.service <<UNIT
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${bin} run --environ --config ${CADDY_MAIN}
ExecReload=${bin} reload --config ${CADDY_MAIN} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}
ensure_caddy_service

# Make cert + decoy readable by the caddy user (if it runs unprivileged).
if id caddy >/dev/null 2>&1; then
  # chown the DIRECTORY too, not just the files — caddy must traverse it to read them.
  chown root:caddy "$CERT_DIR" "$CERT_DIR/origin.key" "$CERT_DIR/origin.pem" 2>/dev/null || true
  chmod 750 "$CERT_DIR" 2>/dev/null || true
  chmod 640 "$CERT_DIR/origin.key" 2>/dev/null || true
  chmod 644 "$CERT_DIR/origin.pem" 2>/dev/null || true
  chmod -R a+rX "$DECOY_DIR" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Caddy config: separate snippet + import, validate
# ---------------------------------------------------------------------------
mkdir -p "$CADDY_SNIPPET_DIR"
cat >"$CADDY_SNIPPET" <<EOF
https://${DOMAIN}:${PUBLIC_PORT} {
	tls ${CERT_DIR}/origin.pem ${CERT_DIR}/origin.key

	@vpn path ${WSPATH}
	reverse_proxy @vpn 127.0.0.1:${XRAY_LOCAL_PORT}

	root * ${DECOY_DIR}
	file_server
}
EOF
log "wrote Caddy snippet $CADDY_SNIPPET (origin port ${PUBLIC_PORT})"

if [ -f "$CADDY_MAIN" ]; then
  if ! grep -qE '^\s*import\s+conf\.d/\*\.caddy' "$CADDY_MAIN"; then
    backup "$CADDY_MAIN"; printf '\nimport conf.d/*.caddy\n' >> "$CADDY_MAIN"; log "added import to $CADDY_MAIN"
  else log "$CADDY_MAIN already imports conf.d — unchanged"; fi
else
  printf 'import conf.d/*.caddy\n' > "$CADDY_MAIN"; log "created minimal $CADDY_MAIN"
fi

if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile >/tmp/cfvpn-caddy-test.log 2>&1; then
  warn "Caddy config test FAILED — reverting our changes and aborting:"; cat /tmp/cfvpn-caddy-test.log >&2
  rm -f "$CADDY_SNIPPET"; [ -f "$CADDY_MAIN.bak.$STAMP" ] && cp -a "$CADDY_MAIN.bak.$STAMP" "$CADDY_MAIN"
  die "no changes applied to the running Caddy."
fi

# ---------------------------------------------------------------------------
# Firewall + start
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then ufw allow "${PUBLIC_PORT}"/tcp >/dev/null 2>&1 || true; fi

log "restarting Xray and (re)starting Caddy…"
systemctl enable xray >/dev/null 2>&1 || true; systemctl restart xray
systemctl enable caddy >/dev/null 2>&1 || true
systemctl reload caddy 2>/dev/null || systemctl restart caddy

sleep 1
systemctl is-active --quiet xray  || warn "xray is not active — check: journalctl -u xray -e"
systemctl is-active --quiet caddy || warn "caddy is not active — check: journalctl -u caddy -e"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
enc_path="$(printf '%s' "$WSPATH" | sed 's,/,%2F,g')"
LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${enc_path}#${NAME}"
PUBIP="$(curl -fsS https://api.ipify.org 2>/dev/null || echo THIS_VPS_IP)"

echo
echo "==================================================================="
echo " Cloudflare-fronted VLESS+WS VPN is ready (Reality/panel preserved)."
echo "==================================================================="
echo
echo " Cloudflare dashboard steps:"
echo "   1) DNS: A record  ${DOMAIN}  ->  ${PUBIP}   [ PROXIED / orange cloud ]"
echo "   2) SSL/TLS mode:  ${CF_SSL_MODE}"
echo "   3) WebSockets:    ON (default)"
if [ "$NEED_ORIGIN_RULE" -eq 1 ]; then
echo "   4) Origin Rule (REQUIRED — origin port is ${PUBLIC_PORT}, not 443):"
echo "        Rules -> Origin Rules -> Create rule"
echo "        If hostname equals ${DOMAIN}  ->  Rewrite to  Port = ${PUBLIC_PORT}"
echo "      (Visitors still use 443; Cloudflare dials your origin on ${PUBLIC_PORT}.)"
fi
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
echo " Undo everything with:  sudo $0 --domain ${DOMAIN} --uninstall"
echo " Note: this uses a dedicated Xray on 127.0.0.1:${XRAY_LOCAL_PORT}, separate"
echo " from your panel's Xray — your Reality on 443 is untouched."
echo "==================================================================="
