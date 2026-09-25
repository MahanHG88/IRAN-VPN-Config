#!/usr/bin/env bash
#
# icmp-tunnel.sh — last-resort ICMP (ping) tunnel using `hans`.
#
# This is a BREAK-GLASS transport for when almost nothing else gets through
# (e.g. a hard crackdown where only ICMP echo still passes). It is SLOW and
# high-latency — fine for messaging / light browsing / checking news, not for
# streaming. Use Reality / CDN-fronting / Hysteria2 for normal use; keep this
# for the moment those all fail. See ../docs/07-icmp-dns-tunneling.md.
#
# It creates a full IP-over-ICMP tunnel (a tun interface), so once it is up the
# client can route real traffic through the server, which NATs it to the
# internet.
#
#   SERVER (your VPS, must have a public IP):
#       sudo ./icmp-tunnel.sh server --password 'YOURPASS'
#       sudo ./icmp-tunnel.sh server --password 'YOURPASS' --systemd   # persist
#
#   CLIENT (the machine in Iran):
#       sudo ./icmp-tunnel.sh client --server <VPS_PUBLIC_IP> --password 'YOURPASS'
#       # add --full-tunnel to route ALL of this machine's traffic through it:
#       sudo ./icmp-tunnel.sh client --server <VPS_PUBLIC_IP> --password 'YOURPASS' --full-tunnel
#
# Notes / caveats:
#   * Both ends need root (raw sockets + tun device).
#   * ICMP can be rate-limited or dropped by the network; if ping to the server
#     doesn't work at all, this won't either.
#   * On the client, --full-tunnel changes your default route. The script keeps
#     a host route to the server via your real gateway and restores everything
#     on exit (Ctrl-C). If you are SSH'd into the client remotely, prefer
#     running WITHOUT --full-tunnel and use a proxy over the tunnel instead.
#
set -euo pipefail

TUN_NET_BASE="10.9.0.1"   # server-side tunnel IP; clients get 10.9.0.2, .3, ...
TUN_DEV="tun0"
MTU="1200"
DNS_FALLBACK="1.1.1.1"

# ---------------------------------------------------------------------------
log()  { printf '\033[1;36m[icmp-tunnel]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[icmp-tunnel]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[icmp-tunnel] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)."
}

detect_pm() {
  if   command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf     >/dev/null 2>&1; then echo dnf
  elif command -v yum     >/dev/null 2>&1; then echo yum
  elif command -v pacman  >/dev/null 2>&1; then echo pacman
  elif command -v apk     >/dev/null 2>&1; then echo apk
  else echo unknown; fi
}

install_hans() {
  if command -v hans >/dev/null 2>&1; then
    log "hans already installed: $(command -v hans)"
    return
  fi
  local pm; pm="$(detect_pm)"
  log "installing hans via: $pm"
  case "$pm" in
    apt)    apt-get update -y && apt-get install -y hans ;;
    dnf)    dnf install -y hans || build_hans_hint ;;
    yum)    yum install -y hans || build_hans_hint ;;
    pacman) pacman -Sy --noconfirm hans || build_hans_hint ;;
    apk)    apk add hans || build_hans_hint ;;
    *)      build_hans_hint ;;
  esac
  command -v hans >/dev/null 2>&1 || build_hans_hint
}

build_hans_hint() {
  die "could not install 'hans' from your package manager.
     Build it from source (needs git + build tools):
         git clone https://github.com/friedrich/hans
         cd hans && make
         sudo cp hans /usr/local/bin/
     Then re-run this script."
}

wait_for_tun() {
  local n=0
  until ip link show "$TUN_DEV" >/dev/null 2>&1; do
    n=$((n+1)); [ "$n" -gt 30 ] && die "tunnel device $TUN_DEV did not come up."
    sleep 1
  done
}

# ---------------------------------------------------------------------------
# SERVER
# ---------------------------------------------------------------------------
run_server() {
  require_root
  [ -n "${PASSWORD:-}" ] || die "server needs --password"
  install_hans

  local wan; wan="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -n "$wan" ] || die "could not detect WAN interface."
  log "WAN interface: $wan"

  if [ "${SYSTEMD:-0}" = "1" ]; then
    install_server_systemd "$wan"
    return
  fi

  server_prep "$wan"
  log "starting hans server on $TUN_NET_BASE (Ctrl-C to stop)"
  trap "server_cleanup '$wan'" EXIT INT TERM
  hans -f -s "$TUN_NET_BASE" -p "$PASSWORD" -d "$TUN_DEV" -m "$MTU" -i
}

server_prep() {
  local wan="$1"
  log "enabling IP forwarding + letting hans own ICMP echo"
  sysctl -qw net.ipv4.ip_forward=1
  sysctl -qw net.ipv4.icmp_echo_ignore_all=1   # kernel stops auto-replying to pings
  if ! iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o "$wan" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o "$wan" -j MASQUERADE
  fi
}

server_cleanup() {
  local wan="$1"
  warn "cleaning up server NAT / sysctl"
  iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o "$wan" -j MASQUERADE 2>/dev/null || true
  sysctl -qw net.ipv4.icmp_echo_ignore_all=0 || true
}

install_server_systemd() {
  local wan="$1"
  local unit=/etc/systemd/system/icmp-tunnel.service
  log "installing persistent systemd service -> $unit"
  # Persist forwarding across reboots.
  cat >/etc/sysctl.d/99-icmp-tunnel.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.icmp_echo_ignore_all=1
EOF
  sysctl -q --system

  cat >"$unit" <<EOF
[Unit]
Description=ICMP tunnel (hans) server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/sbin/iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o ${wan} -j MASQUERADE
ExecStart=/usr/bin/env hans -f -s ${TUN_NET_BASE} -p ${PASSWORD} -d ${TUN_DEV} -m ${MTU} -i
ExecStopPost=-/sbin/iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o ${wan} -j MASQUERADE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "$unit"   # contains the password
  systemctl daemon-reload
  systemctl enable --now icmp-tunnel.service
  log "service started. Check: systemctl status icmp-tunnel && journalctl -u icmp-tunnel -f"
  warn "the unit file contains your password in plaintext (perms 600, root-only)."
}

# ---------------------------------------------------------------------------
# CLIENT
# ---------------------------------------------------------------------------
run_client() {
  require_root
  [ -n "${SERVER:-}" ]   || die "client needs --server <VPS_PUBLIC_IP>"
  [ -n "${PASSWORD:-}" ] || die "client needs --password"
  install_hans

  # Capture the real path to the server BEFORE we touch routing.
  local orig_gw orig_dev
  orig_gw="$(ip route show default | awk '/default/{print $3; exit}')"
  orig_dev="$(ip route show default | awk '/default/{print $5; exit}')"
  [ -n "$orig_gw" ] && [ -n "$orig_dev" ] || die "could not detect current default route."
  log "current default route: via $orig_gw dev $orig_dev"

  log "starting hans client -> $SERVER (over ICMP)"
  hans -f -c "$SERVER" -p "$PASSWORD" -d "$TUN_DEV" -m "$MTU" -i &
  HANS_PID=$!

  trap "client_cleanup '$orig_gw' '$orig_dev'" EXIT INT TERM
  wait_for_tun
  log "tunnel $TUN_DEV is up."

  if [ "${FULL_TUNNEL:-0}" = "1" ]; then
    client_full_tunnel "$orig_gw" "$orig_dev"
  else
    log "point-to-point tunnel ready. Server is reachable at $TUN_NET_BASE over the tunnel."
    log "To route everything through it, re-run with --full-tunnel."
    log "Or run a proxy on the server bound to $TUN_NET_BASE and point your apps at it."
  fi

  log "running. Press Ctrl-C to tear down and restore your network."
  wait "$HANS_PID"
}

client_full_tunnel() {
  local orig_gw="$1" orig_dev="$2"
  log "enabling full-tunnel routing"
  # 1) pin a host route to the server via the REAL gateway, so ICMP to the
  #    server keeps flowing outside the tunnel (otherwise we'd cut our own leg).
  ip route replace "$SERVER" via "$orig_gw" dev "$orig_dev"
  # 2) send everything else through the tunnel.
  ip route replace default via "$TUN_NET_BASE" dev "$TUN_DEV"
  # 3) DNS through the tunnel.
  if [ -w /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
    cp -a /etc/resolv.conf /etc/resolv.conf.icmptun.bak 2>/dev/null || true
    printf 'nameserver %s\n' "$DNS_FALLBACK" >/etc/resolv.conf
  fi
  log "full-tunnel active: all traffic now goes over ICMP. (Expect it to be slow.)"
}

client_cleanup() {
  local orig_gw="$1" orig_dev="$2"
  warn "restoring client network"
  if [ "${FULL_TUNNEL:-0}" = "1" ]; then
    ip route replace default via "$orig_gw" dev "$orig_dev" 2>/dev/null || true
    ip route del "$SERVER" via "$orig_gw" dev "$orig_dev" 2>/dev/null || true
    [ -f /etc/resolv.conf.icmptun.bak ] && mv -f /etc/resolv.conf.icmptun.bak /etc/resolv.conf 2>/dev/null || true
  fi
  kill "${HANS_PID:-0}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

MODE="${1:-}"; shift || true
[ -n "$MODE" ] || usage 1

PASSWORD=""; SERVER=""; SYSTEMD=0; FULL_TUNNEL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --server)   SERVER="${2:-}"; shift 2 ;;
    --systemd)  SYSTEMD=1; shift ;;
    --full-tunnel) FULL_TUNNEL=1; shift ;;
    --mtu)      MTU="${2:-}"; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$MODE" in
  server) run_server ;;
  client) run_client ;;
  -h|--help|help) usage 0 ;;
  *) die "unknown mode: $MODE (expected 'server' or 'client'; try --help)" ;;
esac
