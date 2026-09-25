# 07 — ICMP / DNS tunneling (break-glass fallbacks)

You asked specifically about **ICMP encoding**. It's real and it has a place, but
set expectations: these are **last-resort, low-speed** transports for when almost
nothing else gets through (e.g. a hard crackdown where only ping or DNS survives).
They are not daily drivers and won't stream video. Keep them as break-glass.

## When these help

During the worst crackdowns Iran sometimes drops toward an allowlist and blocks
most foreign TCP/UDP, but leaves **ICMP (ping)** or **DNS** partially working
because breaking them breaks basic connectivity. If you can `ping` out or resolve
DNS to an external resolver, you can sometimes smuggle a slow tunnel through.

## Ready-to-run script

This repo ships [`scripts/icmp-tunnel.sh`](../scripts/icmp-tunnel.sh), which
sets up a full IP-over-ICMP tunnel with `hans` on both ends:

```bash
# On your VPS (public IP):
sudo ./scripts/icmp-tunnel.sh server --password 'YOURPASS'
sudo ./scripts/icmp-tunnel.sh server --password 'YOURPASS' --systemd   # persistent

# On the machine in Iran:
sudo ./scripts/icmp-tunnel.sh client --server <VPS_PUBLIC_IP> --password 'YOURPASS'
sudo ./scripts/icmp-tunnel.sh client --server <VPS_PUBLIC_IP> --password 'YOURPASS' --full-tunnel
```

It installs `hans`, enables IP forwarding + NAT on the server, and (with
`--full-tunnel`) routes all client traffic through the tunnel while keeping a
host route to the server via the real gateway so you don't cut your own link.
Ctrl-C on the client restores routing and DNS. Details below.

## ICMP tunneling

Encapsulates IP traffic inside ICMP echo request/reply payloads. Tools:

- **hans** — creates a `tun` interface tunneled over ICMP echo. Simple client/server.
- **ptunnel-ng** — modern fork of ptunnel; tunnels TCP over ICMP.
- **icmptunnel** (DhavalKapil) — point-to-point IP-over-ICMP.

Rough shape (hans):

```bash
# Server (VPS) — assigns a tunnel subnet, sets a password
sudo hans -s 10.9.0.1 -p 'YOUR-PASSWORD'

# Client (in Iran) — connect to the VPS public IP over ICMP
sudo hans -c <VPS-IP> -p 'YOUR-PASSWORD'
# then route the traffic you want through the tun interface / 10.9.0.x
```

**Reality check:**
- **Slow and high-latency.** Fine for text, messaging, light browsing; painful
  for anything heavy.
- **ICMP is rate-limitable.** Iran can throttle or drop ICMP, and often does under
  crackdown; when they do, this stops too.
- Needs **root** on both ends and raw-socket capability.
- Traffic is unusual (large/steady ICMP echo volume) and can itself be flagged, so
  don't run it 24/7 as a primary.

## DNS tunneling

Encodes data in DNS queries/responses to a domain whose authoritative server you
control. Tool: **iodine** (also **dnscat2** for shell-style access).

```bash
# You need an NS delegation: t.example.com  ->  ns.example.com (your VPS)
# Server (VPS)
sudo iodined -f -c -P 'YOUR-PASSWORD' 10.8.0.1 t.example.com

# Client (in Iran)
sudo iodine -f -P 'YOUR-PASSWORD' t.example.com
```

**Reality check:**
- **Even slower than ICMP.** Kilobits, not megabits. Text and tiny requests only.
- Requires an **NS-delegated subdomain** you control (uses one of your domains —
  a filtered domain can still work if DNS resolution itself isn't blocked to your
  authoritative server).
- Very distinctive traffic; easy to flag if used heavily.

## Where these fit in your stack

Put an ICMP or DNS tunnel in the **break-glass** slot of your rotation
([06](06-resilience-playbook.md)). During normal filtering, use Reality /
CDN-fronting / Hysteria2. Reach for ICMP/DNS only when the network is so locked
down that those don't pass — to get *some* connectivity (messaging, checking
news) rather than none.

Do **not** expect these to replace a proper proxy for speed. If you need durable
*and* fast, the answer is Reality + IP rotation + a Hysteria2 fast lane, not ICMP.
