# 03 — Reality (VLESS + XTLS-Vision), done right

Reality is currently the most durable single transport against Iran's filtering,
*when configured correctly and pointed directly at your VPS* (grey cloud / raw
IP — never behind a CDN; see [02](02-diagnosing-cloudflare-reality.md)).

## Why Reality is resilient

- **No SNI leak:** the SNI on the wire is a *real, permitted* site's, borrowed
  from your `serverNames`/`dest`. The censor can't block your real domain because
  it never appears.
- **Survives active probing:** if the censor probes your IP:port without the
  right key, your server transparently forwards them to the *real* borrowed site,
  so the prober sees a genuine website and moves on.
- **No TLS-in-TLS:** Reality *is* the outer TLS, so the nested-TLS heuristic
  doesn't apply.
- **Real browser fingerprint:** with uTLS (`fingerprint: chrome`) the ClientHello
  looks like Chrome.

Its one real weakness is **IP blocking** — mitigated by rotating IPs
([06](06-resilience-playbook.md)).

## Choosing a `dest` / `serverNames` (SNI to borrow)

Pick a site that is:

1. **Reachable from Iran and not filtered** (test from an Iranian vantage point).
2. **TLS 1.3 + HTTP/2** capable.
3. **Not behind the same small hosting** as you, and ideally a big, boring,
   high-traffic destination so the traffic pattern is unremarkable.
4. Not a site that itself does aggressive anti-bot blocking of your VPS IP.

Good *categories*: large software/CDN-hosted marketing sites, big media, popular
foreign services that remain reachable. **Test, don't assume** — reachability
changes. Verify with:

```bash
# Does it offer TLS 1.3 + HTTP/2, and is it reachable?
xray tls ping <candidate-host>          # if your build supports it
# or:
curl -sI --tls-max 1.3 --http2 https://<candidate-host>/ | head
```

## Generate keys and IDs

```bash
# X25519 keypair (gives you a Private key + Public key)
xray x25519

# A short ID (0–16 hex chars; "" is also allowed as one entry)
openssl rand -hex 8

# A UUID for the client
xray uuid
```

Keep the **private key** on the server; the **public key** goes in the client.

## Server config

See [`configs/reality/server.json`](../configs/reality/server.json). Key points:

- Listen on `0.0.0.0:443`, `protocol: vless`, `flow: xtls-rprx-vision`.
- `security: reality`, `dest: <borrowed-host>:443`, `serverNames: [<borrowed-host>]`.
- `privateKey` from `xray x25519`; `shortIds` including `""` and your hex id.

## Client config

See [`configs/reality/client.json`](../configs/reality/client.json). It must use:

- The same UUID, `flow: xtls-rprx-vision`.
- `serverName` = the borrowed host, `publicKey` = the server's public key,
  `shortId` = one you configured, `fingerprint: chrome`.
- `address` = your VPS IP (or a grey-cloud DNS name pointing at it).

## Install (Debian/Ubuntu VPS)

```bash
# Official installer (review before running as always)
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
sudo mkdir -p /usr/local/etc/xray
sudo cp server.json /usr/local/etc/xray/config.json
sudo systemctl enable --now xray
sudo journalctl -u xray -f
```

## Sanity checklist

- [ ] DNS record is **grey cloud** (or you're using the raw IP).
- [ ] `dest`/`serverNames` host is reachable from Iran and speaks TLS 1.3 + H2.
- [ ] Client `fingerprint` is set (`chrome`).
- [ ] Public/private key pair matches across client/server.
- [ ] Port 443 open in the VPS firewall / security group.
- [ ] You are **not** behind Cloudflare's orange cloud.
