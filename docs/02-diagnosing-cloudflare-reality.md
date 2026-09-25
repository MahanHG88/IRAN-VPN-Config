# 02 — Diagnosing your Cloudflare + Reality problem

This is the exact situation you described:

> I can ping `mooooz.lol` from an Iranian IP and it reaches Cloudflare's edge,
> but the Xray Reality VLESS VPN does not connect. The domain is orange-clouded
> (proxied) on Cloudflare.

That's not a tuning problem. **Reality and Cloudflare's proxy are fundamentally
incompatible.** Here is why, and the two ways to fix it.

## Why ping works but the VPN doesn't

With the record **orange-clouded (proxied)**, the path is:

```
Client (Iran) ──TLS──► Cloudflare edge IP ──HTTP──► your VPS (origin)
```

1. Your relative's client connects to a **Cloudflare** IP. Cloudflare answers
   ICMP, so `ping` succeeds and the IP looks perfectly reachable. This is a red
   herring — you're pinging Cloudflare, not your server.

2. Cloudflare **terminates TLS itself**, presenting **Cloudflare's** certificate.
   But Reality's entire mechanism depends on the client completing a TLS
   handshake whose certificate/identity is **borrowed from a real site by your
   origin**. That handshake never reaches your VPS, so Reality can't do its job.

3. Cloudflare then forwards **plain HTTP(S)** to your origin. Your Xray Reality
   inbound is not an HTTP server — it's performing a raw TLS interception trick
   on port 443. Cloudflare speaks HTTP; Reality speaks "raw TLS I control." They
   never agree, so the tunnel fails to establish even though every lower layer
   (ICMP, TCP, edge TLS) looks healthy.

**In short:** Reality must own the TLS handshake end-to-end with the client.
A CDN that terminates TLS at its edge removes that ability. Orange cloud breaks
Reality every time.

## Quick confirmation from the server side

On your VPS, watch for the handshake actually arriving:

```bash
# Are connections even reaching your origin on 443?
sudo ss -tnp | grep ':443'

# Xray log — with Reality behind CF you'll see either nothing (CF never
# forwards raw TLS) or malformed/HTTP requests, not real Reality sessions.
sudo journalctl -u xray -f      # or: tail -f /var/log/xray/error.log
```

If the origin sees Cloudflare's IPs making HTTP-shaped requests (not your
client's Reality handshake), that confirms the diagnosis.

## Fix A — Keep Reality: switch to grey cloud (recommended)

Reality doesn't want a CDN in front of it. Point the record **directly** at your
VPS:

1. In Cloudflare DNS, set the A/AAAA record for the host to **DNS only (grey
   cloud)**. Now the client connects straight to your VPS IP.
2. Even better: **you don't need `mooooz.lol` to be unfiltered at all.** In your
   Reality config, set `dest`/`serverNames` to a *popular, permitted* site. The
   SNI the censor sees is that site's, so your filtered domain is irrelevant. You
   can point a grey-cloud record from `mahanmirzaee.com` (your unfiltered domain)
   at the VPS just for convenience, or use the raw IP.

See [03 — Reality setup](03-reality-setup.md) for the full config.

**Trade-off:** grey cloud exposes your VPS IP, so the IP can be blocked directly.
That's the normal Reality failure mode, and the answer is IP rotation across a
few cheap servers — see [06](06-resilience-playbook.md). This is a *much* better
position than "domain filtered in a day," because a fresh IP is cheap and instant.

## Fix B — Keep Cloudflare fronting: drop Reality, use VLESS + WS + TLS

If you specifically want Iran to see only Cloudflare's shared IP, you must use a
transport Cloudflare understands. WebSocket-over-TLS is HTTP-compatible, so
Cloudflare will proxy it:

```
Client ──TLS(WS)──► Cloudflare edge ──TLS(WS)──► your origin (Caddy/nginx) ──► Xray VLESS+WS
```

See [04 — CDN fronting](04-cdn-fronting-vless-ws.md) for the full Xray + Caddy
config and the Cloudflare SSL settings.

**Trade-off:** this is VLESS+WS+TLS, which is **TLS-in-TLS** and therefore more
detectable by DPI heuristics than Reality (see
[01 §4](01-how-iran-filtering-works.md)). Iran has periodically disrupted
Cloudflare-fronted proxies. It's a good *secondary*, not always the most durable
primary.

## Recommended outcome for you

- Make **Reality (grey cloud, borrowed SNI)** your **primary** — it's the most
  robust against SNI filtering, active probing, and fingerprinting, and it frees
  you from the domain treadmill.
- Keep **VLESS+WS+TLS behind Cloudflare** on `mooooz.lol` (orange cloud) as a
  **secondary** for when your Reality IP gets blocked.
- Add **Hysteria2** as a **third** for speed under throttling.
- Put all three in one subscription so the client auto-fails-over
  (see [06](06-resilience-playbook.md)).
