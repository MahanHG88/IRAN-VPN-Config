# 08 — Apps with an On/Off toggle (no commands on the client)

You don't want to type commands on the client — you want an app with a switch.
Good news: for your real VPN that app already exists and runs on both your
MacBook and the Android phone. Here's the honest breakdown per transport.

## Your daily VPN → Hiddify (one tap, both devices)

**Reality, VLESS+WS+TLS, and Hysteria2 all import into Hiddify**, which is a real
app with a big On/Off toggle. This is the answer for normal use.

### Step 1 — turn your server details into import links (once, on any computer)

```bash
cp configs/client.env.example configs/client.local.env
# edit configs/client.local.env with your real UUID/keys/host/password
./scripts/make-client-links.sh
```

This prints `vless://…` and `hysteria2://…` **share links** and, if `qrencode`
is installed, **QR codes** (also saved as PNGs in `qr/`). It never leaves your
machine.

### Step 2 — import into Hiddify

**Android:**
1. Install **Hiddify** from Google Play (or the APK from the Hiddify GitHub
   releases). Alternatives: v2rayNG, NekoBox.
2. Open it → **+** (Add) → **Scan QR code** (scan from your computer screen) or
   **Import from clipboard** (copy the links).
3. Pick a server → tap the big **power button**. That's your On/Off.

**MacBook:**
1. Install **Hiddify** for macOS (Hiddify GitHub releases; Apple Silicon &
   Intel builds). Alternative: **v2rayN** or **sing-box**.
2. **+** → **Import from clipboard** (paste the links) or add the QR.
3. Toggle **On/Off** from the menu bar / main window.

### Step 3 — let it auto-pick the live server

In Hiddify, put your servers in an **Auto** / **URLTest** group. When one
server's IP gets blocked, the app silently switches to a working one — so your
relative just leaves it on and never edits configs. This is the practical form of
the "rotate IPs, not domains" strategy in [06](06-resilience-playbook.md).

> Re-run `make-client-links.sh` whenever you add/rotate a server, and re-share
> the new link/QR. Keep `client.local.env`, `subscription.local.txt`, and `qr/`
> private — they're gitignored for that reason.

## The ICMP last-resort → honest limitations

ICMP tunneling **cannot** be a normal app on your two devices:

| Device | ICMP tunnel? | Why |
|--------|--------------|-----|
| Android phone | ❌ No | Needs root; a normal phone can't create a tun device over raw ICMP. |
| MacBook (modern macOS) | ❌ Not really | `hans`/`tun` needs a kernel extension Apple deprecated + SIP blocks it. Fragile at best. |
| A Linux box / Pi / VM / router | ✅ Yes | Full raw-socket + tun support. |

So ICMP is realistically a **Linux-client** tool. If you ever run a Linux client:

- **Command way:** [`scripts/icmp-tunnel.sh`](../scripts/icmp-tunnel.sh) (see [07](07-icmp-dns-tunneling.md)).
- **App way (click On/Off):** [`scripts/icmp-tunnel-app.py`](../scripts/icmp-tunnel-app.py):
  ```bash
  sudo python3 scripts/icmp-tunnel-app.py
  # open http://127.0.0.1:8765  → enter server IP + password → click "Turn ON"
  ```
  It's a small local web panel with a real On/Off button, status light, and a
  full-tunnel checkbox. Stdlib only, no installs. Linux only.

### What to use as a last resort on Mac/Android instead

Since ICMP isn't available there, your break-glass options on those devices are:

1. **Hysteria2 with port hopping** — already in your stack; often survives when
   fixed-port transports are throttled. Keep it in the Hiddify list.
2. **A different protocol/SNI in the same Hiddify Auto group** — diversity is
   itself the fallback; if Reality dies, the app rolls to the CDN or Hysteria2
   entry automatically.
3. **Reachability apps built for total shutdowns** (e.g. widely-used
   anti-censorship clients that bundle multiple bridges). These are more
   practical on a phone than ICMP will ever be.

Bottom line: **Hiddify is your On/Off app on both devices.** ICMP stays a
Linux-only, rarely-needed tool — keep it in your back pocket, not on the phone.
