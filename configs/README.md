# Example configs

Templates only. Replace every `REPLACE-WITH-...` placeholder with your own
values, and **never commit real UUIDs, keys, passwords, or hostnames.**

| Folder | Transport | Role | Notes |
|--------|-----------|------|-------|
| `reality/` | VLESS + Reality (XTLS-Vision) | **Primary** | Direct to VPS (grey cloud / raw IP). Never behind Cloudflare orange cloud. Most durable. |
| `vless-ws-cdn/` | VLESS + WebSocket + TLS | **Secondary** | Behind Cloudflare orange cloud. Survives IP blocks; TLS-in-TLS is more detectable. Xray + Caddy. |
| `hysteria2/` | Hysteria2 (QUIC/UDP) | **Fast lane** | Great under throttling; UDP can be blocked in hard crackdowns. Supports port hopping. |

## Generating secrets

```bash
xray uuid                 # UUID for clients
xray x25519               # Reality private/public keypair
openssl rand -hex 8       # Reality shortId
openssl rand -hex 12      # a random secret WS path suffix / passwords
```

## Recommended: run all three and let the client fail over

Put the resulting server entries into a single subscription and use a client
manager with a URLTest/auto-select group (Hiddify, sing-box, Nekoray). When one
server's IP is blocked, the client silently switches to a live one — see
[`../docs/06-resilience-playbook.md`](../docs/06-resilience-playbook.md).

## Keeping secrets out of git

A `.gitignore` at the repo root ignores common "real config" filenames
(`*.local.json`, `config.local.*`, `secrets*`, etc.). Keep your filled-in
configs under those names, or outside the repo entirely.
