# 01 — How Iran's filtering actually works

To build something that survives, you have to know what you're up against. Iran's
filtering (built around the "National Information Network" and DPI middleboxes at
the international gateways) uses several independent methods. Each one needs a
different countermeasure, which is why single-protocol setups die.

## 1. SNI-based filtering (the most common)

When a TLS connection starts, the client sends a **ClientHello** that includes
the **SNI** (Server Name Indication) — the hostname it wants — *in plaintext*.
The censor reads it and, if the hostname is on a blocklist, drops or RST-resets
the connection.

- **Kills:** any proxy that puts your real (filtered) domain in the SNI.
- **Beaten by:** Reality (borrows a *permitted* site's SNI), ECH where available,
  or CDN fronting (SNI is the CDN's, e.g. a Cloudflare-fronted hostname).

## 2. Active probing

After the DPI sees a suspicious-looking TLS or handshake, the censor's own
machines **connect back to the same IP:port** and poke it to see whether it
behaves like a known proxy (VMess, old VLESS, Shadowsocks without a plugin,
Trojan, etc.). If it responds like a proxy, the IP:port gets blocked.

- **Kills:** protocols that reveal themselves when probed.
- **Beaten by:** Reality (an unauthenticated prober gets forwarded to the *real*
  borrowed site and sees a genuine website, so the probe looks legitimate),
  shadow-tls, and anything that falls through to a real service on failed auth.

## 3. TLS fingerprinting (JA3 / uTLS)

The exact byte layout of the ClientHello (cipher list, extensions, order)
identifies the *library* that made it. Go's crypto/tls, for example, has a
distinct fingerprint that no real browser produces. The censor can block
connections whose fingerprint isn't a real browser.

- **Beaten by:** uTLS — Xray/sing-box mimic Chrome/Firefox fingerprints
  (`fingerprint: chrome`). Always enable this.

## 4. TLS-in-TLS detection

A proxy that does "TLS to the CDN, then another TLS inside it" (e.g. VLESS+WS+TLS
tunneling HTTPS) produces a detectable pattern: nested TLS records, characteristic
packet sizes and timing. Iran has deployed heuristics for this.

- **Weakens:** CDN fronting (VLESS+WS+TLS, Trojan+WS).
- **Beaten by:** Reality (no nested TLS — it *is* the outer TLS), or by adding
  padding/mux and not relying on a single fronting connection.

## 5. IP blocking

The bluntest tool: block the destination IP outright. This is why even a perfect
protocol dies if the IP is exposed and flagged.

- **Beaten by:** hiding behind a CDN (shared IP), and by **rotating IPs** across
  cheap VPSes. IPs are cheaper and faster to replace than reputable domains.

## 6. Throttling / QoS

During protests, Iran doesn't always block — it **throttles** international
traffic to near-unusable speeds, and often **blocks or degrades UDP** (which
kills QUIC-based transports like Hysteria2/TUIC). Sometimes they drop to an
allowlist ("only domestic + a few permitted foreign services").

- **Beaten by:** congestion-control-tuned transports (Hysteria2's Brutal) for
  throttling; a TCP fallback for when UDP is blocked. You need *both* available.

## 7. Protocol / port heuristics

Odd ports, long-lived high-volume TLS to a single unknown IP, and non-standard
handshakes all raise suspicion. Blend in: use 443, look like normal HTTPS, and
prefer identities that resemble ordinary browsing.

## Putting it together

| Method | Primary counter |
|--------|-----------------|
| SNI filtering | Reality (borrowed SNI) / CDN fronting |
| Active probing | Reality / shadow-tls / real-service fallback |
| TLS fingerprint | uTLS (`fingerprint: chrome`) |
| TLS-in-TLS | Reality (no nesting) |
| IP blocking | CDN shared IP + IP rotation |
| Throttling | Hysteria2 (Brutal CC), port hopping |
| UDP blocking | keep a TCP transport ready |

No single protocol beats all of these, which is the whole argument for running
two or three (see [05](05-protocol-diversity.md)) with automatic failover
(see [06](06-resilience-playbook.md)).
