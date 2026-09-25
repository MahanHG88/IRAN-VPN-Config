#!/usr/bin/env bash
#
# make-client-links.sh — turn your server details into one-tap client configs.
#
# Produces standard share links (vless:// and hysteria2://) plus QR codes that
# import directly into Hiddify / v2rayNG / NekoBox / Streisand. Once imported,
# the app is a simple On/Off toggle — no commands on the client at all.
#
# Usage:
#   cp configs/client.env.example configs/client.local.env   # then fill it in
#   ./scripts/make-client-links.sh [path/to/client.local.env]
#
# Output:
#   * prints the share links (copy into the app, or "import from clipboard")
#   * prints a QR code per link in the terminal (if `qrencode` is installed)
#   * saves PNG QR codes into ./qr/ (if `qrencode` is installed)
#   * writes a base64 subscription blob to subscription.local.txt
#
set -euo pipefail

ENV_FILE="${1:-configs/client.local.env}"
[ -f "$ENV_FILE" ] || { echo "config not found: $ENV_FILE"; echo "copy configs/client.env.example to $ENV_FILE and fill it in."; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

have_qr=0; command -v qrencode >/dev/null 2>&1 && have_qr=1
[ "$have_qr" -eq 1 ] || echo "(tip: install 'qrencode' to also get scannable QR codes)"
mkdir -p qr

# RFC3986 percent-encoding for query values / paths.
urlenc() {
  local s="$1" o="" c i
  for ((i=0; i<${#s}; i++)); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) o+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; o+="$c" ;;
    esac
  done
  printf '%s' "$o"
}

LINKS=()

emit() {  # name, link
  local name="$1" link="$2"
  echo
  echo "=== $name ==="
  echo "$link"
  LINKS+=("$link")
  if [ "$have_qr" -eq 1 ]; then
    qrencode -t ANSIUTF8 "$link"
    qrencode -o "qr/${name}.png" "$link"
    echo "(saved qr/${name}.png)"
  fi
}

# --- Reality ---
if [ "${REALITY_ENABLE:-0}" = "1" ]; then
  name="$(urlenc "${NAME_PREFIX}-Reality")"
  link="vless://${REALITY_UUID}@${REALITY_SERVER}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBKEY}&sid=${REALITY_SHORTID}&type=tcp#${name}"
  emit "${NAME_PREFIX}-Reality" "$link"
fi

# --- VLESS + WS + TLS (Cloudflare) ---
if [ "${WS_ENABLE:-0}" = "1" ]; then
  name="$(urlenc "${NAME_PREFIX}-CDN")"
  path="$(urlenc "${WS_PATH}")"
  link="vless://${WS_UUID}@${WS_HOST}:${WS_PORT}?encryption=none&security=tls&sni=${WS_HOST}&fp=chrome&type=ws&host=${WS_HOST}&path=${path}#${name}"
  emit "${NAME_PREFIX}-CDN" "$link"
fi

# --- Hysteria2 ---
if [ "${HY2_ENABLE:-0}" = "1" ]; then
  name="$(urlenc "${NAME_PREFIX}-Hysteria2")"
  pass="$(urlenc "${HY2_PASSWORD}")"   # encode: passwords may contain @ / spaces / specials
  q="sni=${HY2_HOST}"
  [ -n "${HY2_MPORT:-}" ] && q="${q}&mport=${HY2_MPORT}"
  link="hysteria2://${pass}@${HY2_HOST}:${HY2_PORT}?${q}#${name}"
  emit "${NAME_PREFIX}-Hysteria2" "$link"
fi

[ "${#LINKS[@]}" -gt 0 ] || { echo "nothing enabled in $ENV_FILE"; exit 1; }

# Combined base64 "subscription" (paste as subscription content in the app).
printf '%s\n' "${LINKS[@]}" | base64 | tr -d '\n' > subscription.local.txt
echo
echo "-------------------------------------------------------------------"
echo "Wrote subscription.local.txt (base64 of all links)."
echo "In Hiddify you can also just 'Import from clipboard' after copying the"
echo "links above. Then use the big On/Off toggle. Keep these files private."
