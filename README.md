# Durable Anti-Censorship VPN Configs for Iran

A practical, opinionated playbook and set of working example configs for
running a **resilient** personal proxy/VPN into Iran — one that survives the
filtering long enough to be worth running, without buying a new domain every
three days.

> This project is for restoring access to the open internet for people living
> under state censorship (specifically, a family member in Iran). It documents
> standard, publicly-known anti-censorship techniques (Reality, CDN fronting,
> QUIC-based transports, tunneling fallbacks) and how to combine them for
> durability.

## The short version

If you only read one thing, read this:

1. **Public / shared configs die in hours. Private ones last.**
   If you use a "free public config" site, the censor's crawlers scrape those
   configs too and block them almost immediately. A private, personal config
   used by one or two people lasts far longer. This is the single biggest
   reason things get "banned in an afternoon."

2. **Reality behind Cloudflare's orange cloud is broken by design.**
   Reality needs a *direct* TLS connection to your VPS. Cloudflare terminates
   TLS at its edge, so the handshake never reaches your server. Ping works, the
   VPN doesn't. Use grey cloud (DNS-only) for Reality, or switch to
   VLESS+WebSocket+TLS if you want to stay behind Cloudflare. See
   [`docs/02-diagnosing-cloudflare-reality.md`](docs/02-diagnosing-cloudflare-reality.md).

3. **Stop thinking "domain," start thinking "identity + IP rotation."**
   With Reality you borrow a real site's TLS identity (SNI), so your own domain
   being filtered doesn't matter. What gets blocked then is the *IP*, which is
   cheaper and faster to rotate than a clean domain. See
   [`docs/06-resilience-playbook.md`](docs/06-resilience-playbook.md).

4. **Run more than one protocol.** Iran uses several detection methods and
   switches tactics during crackdowns (SNI filtering, active probing, TLS-in-TLS
   heuristics, UDP/QUIC blocking, throttling). If you only run one transport,
   one countermeasure kills you. Diversify. See
   [`docs/05-protocol-diversity.md`](docs/05-protocol-diversity.md).

## Documentation

| Doc | What it covers |
|-----|----------------|
| [01 — How Iran's filtering works](docs/01-how-iran-filtering-works.md) | DPI, SNI filtering, active probing, IP blocking, TLS fingerprinting, throttling, "protocol allowlist" mode |
| [02 — Diagnosing your Cloudflare + Reality problem](docs/02-diagnosing-cloudflare-reality.md) | Exactly why ping works but the VPN doesn't, and the two fixes |
| [03 — Reality (VLESS + XTLS-Vision), done right](docs/03-reality-setup.md) | The most durable primary transport; borrowing an SNI; choosing `dest` |
| [04 — CDN fronting (VLESS + WS + TLS via Cloudflare)](docs/04-cdn-fronting-vless-ws.md) | When you *do* want to hide behind Cloudflare, done correctly |
| [05 — Protocol diversity](docs/05-protocol-diversity.md) | Hysteria2, TUIC, Shadowsocks-2022 + shadow-tls, and when to use each |
| [06 — Resilience playbook](docs/06-resilience-playbook.md) | Multi-server failover, IP rotation, port hopping, avoiding domain churn, client managers |
| [07 — ICMP / DNS tunneling fallbacks](docs/07-icmp-dns-tunneling.md) | Break-glass transports for when almost nothing gets through |
| [08 — Apps with an On/Off toggle](docs/08-apps-and-toggle.md) | Hiddify on Mac + Android (one-tap), generating import links/QR, and ICMP's limits |

## Example configs

See [`configs/`](configs/). These are templates — replace UUIDs, keys, paths,
passwords, and SNIs with your own. **Never commit real secrets.**

- `configs/reality/` — Xray VLESS + Reality server & client
- `configs/vless-ws-cdn/` — VLESS + WebSocket + TLS behind Cloudflare (Xray + Caddy)
- `configs/hysteria2/` — Hysteria2 (QUIC) server & client

## Web UI

- [`web/index.html`](web/index.html) — the "Sentinel" dashboard design (dark/light,
  responsive, self-contained). Currently a **UI mockup with simulated data** — see
  [`web/README.md`](web/README.md) for what it is and how to make it functional
  (the natural next step is a client-side config-link generator).

## Scripts

- [`scripts/make-client-links.sh`](scripts/make-client-links.sh) — turn your
  server details ([`configs/client.env.example`](configs/client.env.example))
  into one-tap **share links + QR codes** for Hiddify (see
  [docs/08](docs/08-apps-and-toggle.md)). This is how you get an On/Off app on
  Mac + Android.
- [`scripts/setup-cloudflare-vpn.sh`](scripts/setup-cloudflare-vpn.sh) —
  one-paste server setup for the **Cloudflare-fronted VLESS+WS+TLS** VPN
  (installs Xray + Caddy, makes the cert, prints the client link/QR; see
  [docs/04](docs/04-cdn-fronting-vless-ws.md)).
- [`scripts/cloudflare-configure.py`](scripts/cloudflare-configure.py) — prompts
  for your Cloudflare API token (hidden, never stored) and auto-configures the
  proxied A record, SSL mode Full, WebSockets, and the Origin Rule. Run it
  yourself; the token stays on your machine.
- [`scripts/icmp-tunnel.sh`](scripts/icmp-tunnel.sh) — set up the last-resort
  ICMP tunnel (Linux; see [docs/07](docs/07-icmp-dns-tunneling.md)).
- [`scripts/icmp-tunnel-app.py`](scripts/icmp-tunnel-app.py) — a local web
  On/Off panel for the ICMP tunnel (Linux only).

## Your specific domains

You mentioned:

- `mooooz.lol` (filtered) — currently orange-clouded on Cloudflare
- `mahanmirzaee.com` (not filtered)
- `thedihmaster.lol` (filtered)

A domain being filtered matters far less than you'd think:

- **For Reality:** the domain barely matters. You point a grey-cloud A record at
  your VPS (or skip your domain entirely) and borrow a *popular site's* SNI. The
  censor sees a connection that looks like traffic to that popular site.
- **For CDN fronting:** use whichever domain is on Cloudflare; the visible IP is
  Cloudflare's, shared with millions of sites.

So you don't need to keep buying domains. You need the right transport and a way
to rotate IPs. That's what the resilience playbook is about.

## Legal / safety note

Circumventing censorship to access information is a recognized digital right and
is supported by mainstream internet-freedom organizations. Use these techniques
for lawful access to the open internet. Do not share personal configs publicly —
both for your security and because public configs get blocked fastest.
