# 05 — Protocol diversity: run more than one

Iran uses several detection methods and switches tactics during crackdowns. If
you run one protocol, one countermeasure ends you. The durable posture is **two
or three transports** with automatic failover ([06](06-resilience-playbook.md)).

## The shortlist

### 1. Reality (VLESS + XTLS-Vision) — primary
- **Best against:** SNI filtering, active probing, TLS fingerprinting, TLS-in-TLS.
- **Weakness:** IP blocking (rotate IPs).
- **Use as:** your default daily driver. See [03](03-reality-setup.md).

### 2. VLESS + WS + TLS behind Cloudflare — secondary
- **Best against:** IP blocking (hides behind CF shared IP).
- **Weakness:** TLS-in-TLS detection; CF disruption during crackdowns.
- **Use as:** fallback when your Reality IP gets blocked. See [04](04-cdn-fronting-vless-ws.md).

### 3. Hysteria2 (QUIC/UDP) — speed under throttling
- **Best against:** throttling of international links. Its Brutal congestion
  control pushes usable speed through lossy/throttled paths where TCP collapses.
  Supports **port hopping** (spreads across a UDP port range, hard to block by port).
- **Weakness:** it's UDP — during hard crackdowns Iran degrades/blocks UDP, which
  kills QUIC. So it must not be your *only* option.
- **Use as:** the fast option when the link is throttled but UDP still flows. See
  [`configs/hysteria2/`](../configs/hysteria2/).

### 4. TUIC (QUIC/UDP) — alternative to Hysteria2
- Similar profile to Hysteria2 (UDP/QUIC, fast). Handy as a different UDP
  implementation if one gets specifically fingerprinted.

### 5. Shadowsocks-2022 + shadow-tls — lightweight resister
- SS-2022 is a modern, hard-to-fingerprint AEAD cipher suite. Wrapping it in
  **shadow-tls** makes it present as a TLS handshake to a real site, defeating
  active probing and SNI filtering similarly to Reality.
- Very light on the server; good on a small VPS.

### 6. ICMP / DNS tunneling — break-glass only
- For when almost nothing else gets through. Slow. See [07](07-icmp-dns-tunneling.md).

## How to choose your mix

For your situation (one relative, want durability + speed, tired of buying
domains):

| Slot | Protocol | Why |
|------|----------|-----|
| Primary | Reality (grey cloud, borrowed SNI) | Most durable; no domain needed |
| Secondary | VLESS+WS+TLS via Cloudflare (`mooooz.lol`) | Survives IP blocks |
| Fast | Hysteria2 (port hopping) | Speed when throttled |
| Break-glass | ICMP/DNS tunnel | Last resort during full crackdown |

Put Reality + VLESS-WS + Hysteria2 in a single subscription and let the client
manager pick whichever is alive (next doc).

## Recommended engines/clients that support all of these

- **sing-box** (server + client) — one binary speaks Reality, VLESS+WS,
  Hysteria2, TUIC, Shadowsocks. Easiest way to run a multi-protocol stack.
- **Xray-core** — Reality, VLESS+WS, VMess, Trojan, Shadowsocks.
- **Hysteria2** — its own binary.

Client apps that handle subscriptions + failover:
- **Hiddify** (Windows/Android/iOS/macOS/Linux) — built for exactly this audience.
- **Nekoray / NekoBox** (desktop / Android).
- **sing-box / SFA / SFI** clients.
- **v2rayN** (Windows), **Streisand** (iOS).
