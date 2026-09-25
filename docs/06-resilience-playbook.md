# 06 — Resilience playbook: "works for a day then dies"

This doc is the heart of the project. If your setup **connects fine, then gets
banned in 1–3 days**, the problem is almost never your domain. It's one of these:

## Why a working setup dies in a day or two

1. **The IP gets behaviorally flagged.** A fresh VPS IP that suddenly carries
   continuous, heavy, long-lived encrypted traffic to a single client in Iran is
   statistically obvious. Reality hides the handshake, but not the fact that your
   raw IP is a 24/7 high-volume tunnel. Automated scoring takes hours-to-days,
   then blocks **the IP**. A new domain pointing at the same IP dies just as fast —
   because the domain was never what got blocked.

2. **TLS-in-TLS detection.** If the thing that "worked for a day" is actually
   VLESS+WS+TLS behind Cloudflare (the only VLESS variant that works through the
   orange cloud — real Reality can't), that nested-TLS pattern passes at first and
   gets flagged within days by DPI heuristics ([01 §4](01-how-iran-filtering-works.md)).

3. **Active probing succeeds late.** A slightly-off Reality config (wrong `dest`,
   SNI mismatch, missing fallback) survives casual traffic but fails a probe. Once
   probed and confirmed, the IP:port is blocked.

4. **IP reputation / ASN.** Some VPS provider ranges are pre-scored or get scanned
   constantly. Cheap "proxy-friendly" ASNs are exactly where the censor looks first.

5. **Config reuse / leakage.** Reusing the same UUID, WS path, port, or borrowed
   SNI across servers lets the censor correlate and block them together. Public or
   semi-public configs die fastest of all.

## The durable model: rotate IPs, not domains

Accept that **any single exposed IP will eventually be flagged.** Design for it:

- **Keep 3–5 cheap VPSes** in *different providers and ASNs*, ideally different
  regions. $3–5/mo boxes are fine.
- **Run the same multi-protocol stack on each** (Reality primary + VLESS-WS
  secondary + Hysteria2). See [05](05-protocol-diversity.md).
- **Put them all in one subscription** and let the client fail over automatically
  (Hiddify / sing-box / Nekoray). When one IP dies, your relative doesn't touch
  anything — the client picks a live server.
- **Replace a dead IP in minutes** (rebuild a VPS or get a new IP), not a new
  domain in days. With Reality you need **no domain at all**, so the domain
  treadmill ends here.

This is the direct answer to *"I don't want to keep getting domains."* You stop
buying domains and instead rotate cheap, instantly-replaceable IPs — and Reality
means the filtered/unfiltered status of your domains stops mattering.

## Cut the behavioral signature

- **Use 443**, real browser fingerprint (`fingerprint: chrome`), and a **real
  decoy site** on the origin so casual inspection/probing sees a normal website.
- **Prefer Reality direct (grey cloud)** over CDN-fronted TLS-in-TLS as your
  primary — fewer heuristics apply to it.
- **For the longest-lived hiding**, keep one **CDN-fronted** endpoint
  (VLESS+WS+TLS via Cloudflare) as a fallback: Iran sees a Cloudflare shared IP,
  so behavioral IP-blocking is far less effective. Accept the TLS-in-TLS risk.
- **Consider port hopping** (Hysteria2) so there's no single port to block.
- **Don't run one enormous tunnel** if you can split usage; spikey, single-flow
  traffic to a raw IP is the most flaggable pattern.

## Provider/ASN selection

- Providers vary enormously in how long their ranges survive in Iran. Some cloud
  ASNs get blocked wholesale; others last months.
- Big-CDN shared IPs (Cloudflare, Fastly) last longest but carry the TLS-in-TLS
  caveat.
- Test a couple of providers, keep the ones that survive, drop the ones that die
  in a day.

## Hygiene checklist (do this per server)

- [ ] Fresh **UUID**, fresh **WS path**, fresh **shortId** — never reused.
- [ ] Different **borrowed SNI** per server where practical.
- [ ] **Never** post configs publicly or in group chats that could be scraped.
- [ ] Origin serves a plausible **decoy site**.
- [ ] Client fingerprint = `chrome`; transport on **443**.
- [ ] Server is in the **subscription** so failover is automatic.

## A concrete rotation you could run today

| Server | Provider/ASN | Primary | Secondary | Fast |
|--------|--------------|---------|-----------|------|
| A | Provider 1 | Reality (grey cloud, SNI-X) | — | Hysteria2 |
| B | Provider 2 | Reality (grey cloud, SNI-Y) | — | Hysteria2 |
| C | Provider 3 | — | VLESS+WS+TLS via Cloudflare (`mooooz.lol`) | — |

All three in one Hiddify/sing-box subscription. When A's IP dies, the client uses
B; you rebuild A on a fresh IP at your leisure. C (Cloudflare-fronted) is the
"nothing direct works" fallback.

## Client managers that do the failover for you

- **Hiddify** — purpose-built for this audience; subscription + auto-select.
- **sing-box** (SFA/SFI/desktop) — URLTest/failover outbound groups.
- **Nekoray / NekoBox** — desktop/Android, subscription + latency test.
- **v2rayN** (Windows), **Streisand** (iOS).

Configure a **URLTest / auto-select** group so the fastest *live* server is used
and dead ones are skipped automatically.
