# 04 — CDN fronting: VLESS + WebSocket + TLS behind Cloudflare

This is the correct way to hide behind Cloudflare's orange cloud (unlike Reality,
which breaks there — see [02](02-diagnosing-cloudflare-reality.md)). Iran sees
only **Cloudflare's shared IP**, so blocking you means blocking a big chunk of
Cloudflare — expensive for the censor.

Treat this as a **secondary** transport. It is TLS-in-TLS, which Iran's DPI can
sometimes detect ([01 §4](01-how-iran-filtering-works.md)), and Cloudflare-fronted
proxies get disrupted during hard crackdowns. Still very useful in the rotation.

## One-paste setup script

[`scripts/setup-cloudflare-vpn.sh`](../scripts/setup-cloudflare-vpn.sh) builds
this entire setup on a Debian/Ubuntu VPS in one run — installs Xray + Caddy,
generates the UUID + secret path, creates the origin cert, serves a decoy site,
wires the secret WS path to Xray, opens the firewall, and prints the client
link + QR:

```bash
sudo ./scripts/setup-cloudflare-vpn.sh --domain mooooz.lol
# or, with a Cloudflare Origin Certificate (then use SSL mode "Full (strict)"):
sudo ./scripts/setup-cloudflare-vpn.sh --domain mooooz.lol --cert origin.pem --key origin.key
```

By default it makes a **self-signed origin cert** (use Cloudflare SSL mode
**Full**) so you don't have to touch the cert dashboard. Afterwards, in
Cloudflare: point the **orange-cloud** A record at the VPS, set the SSL mode it
tells you, and import the printed link into Hiddify. The manual steps below
explain what the script automates.

## Running it on the same VPS as Reality (or a panel)

If port **443 is already taken** by a direct Reality server or a panel (3x-ui /
Marzban / x-ui), Caddy can't use 443. The script handles this automatically:

- It binds Caddy to **8443** instead (a Cloudflare-supported HTTPS origin port),
  leaving 443 to Reality.
- You then add **one Cloudflare Origin Rule**: *Rules → Origin Rules → if
  hostname equals `<domain>` → Rewrite to Port = 8443*. Visitors still connect on
  443; Cloudflare dials your origin on 8443.
- The WS inbound runs in a dedicated Xray on `127.0.0.1:<port>`, separate from
  your panel's Xray, so the panel and Reality are untouched.

Cloudflare-supported origin HTTPS ports: 443, 8443, 2053, 2083, 2087, 2096.

## Architecture

```
Client ──WSS(443)──► Cloudflare edge ──WSS(443)──► Caddy/nginx (origin TLS)
                                                        │  reverse-proxy the WS path
                                                        ▼
                                                 Xray VLESS+WS  (127.0.0.1:8080)
```

- A normal web server (Caddy here) terminates real TLS on your origin and serves
  an ordinary-looking website on `/`.
- Only a **secret path** (e.g. `/a7Fq2x`) is reverse-proxied to Xray's WS inbound.
- Anyone browsing the domain sees a plain website; only the client that knows the
  path reaches the proxy.

## Cloudflare settings

1. DNS record: **orange cloud (proxied)** — this is the one case where you want it.
2. SSL/TLS mode: **Full (strict)** (Caddy will have a valid origin cert).
3. Make sure **WebSockets** are enabled (Network tab; on by default).
4. Use a standard proxied port (443).

## Origin: Caddy

See [`configs/vless-ws-cdn/Caddyfile`](../configs/vless-ws-cdn/Caddyfile). Caddy
auto-provisions a Let's Encrypt cert, serves a decoy site, and forwards only the
secret WS path to Xray.

## Origin: Xray VLESS + WS

See [`configs/vless-ws-cdn/server-xray.json`](../configs/vless-ws-cdn/server-xray.json).
It listens on `127.0.0.1:8080`, `network: ws`, with `path` matching the Caddy
route. No TLS in Xray itself — Caddy (and Cloudflare) handle TLS.

## Client

Client uses: `address` = your Cloudflare-fronted hostname, `port` 443,
`security: tls`, `network: ws`, `path` = the secret path, `host`/`sni` = the
hostname, `fingerprint: chrome`. See
[`configs/vless-ws-cdn/client.json`](../configs/vless-ws-cdn/client.json).

## Hardening tips

- Give the decoy site real, boring content so casual inspection/probing sees a
  normal website.
- Keep the WS `path` secret and unique; don't reuse it across users.
- Consider `grpc` instead of `ws` as an alternative that some networks fingerprint
  differently — keep both available.
- Don't publish this hostname anywhere; public exposure = fast blocking.
