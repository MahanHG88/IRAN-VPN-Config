# Web UI — "Sentinel" dashboard

`web/index.html` is the dashboard design (Sentinel) for the project. It's a
self-contained page — open it in any browser, no build step, no dependencies
(fonts load from Google Fonts; everything else is inline). Dark/light themes,
responsive down to phone width.

## Important: this is a UI mockup, not a working VPN client (yet)

Right now the page is a **front-end design with simulated data**:

- The power button, throughput chart, ping/uptime counters, exit-node list, and
  blocked-tracker count are all animated **demo values** generated in the browser.
- Clicking the power toggle does **not** start or stop a real tunnel.
- The exit-node IPs and the "128.4 / 500 GB" quota are placeholder content.

That's normal for a design — it shows how the app should look and feel. Turning
it into something that actually controls a connection is a separate step (below).

## What it would take to make it real

The honest options, easiest first:

1. **Config-link generator (fully client-side, safe to host anywhere).**
   Repurpose this UI into a page that takes your server details and outputs the
   Hiddify import links + QR codes — the browser version of
   [`../scripts/make-client-links.sh`](../scripts/make-client-links.sh). No
   backend, no secrets leave the browser. This is the most useful realistic form.

2. **Local control panel for a real client.** Wire the toggle to a local agent
   (like [`../scripts/icmp-tunnel-app.py`](../scripts/icmp-tunnel-app.py), or a
   sing-box/Xray control socket) running on the same machine. Requires that
   agent + appropriate privileges; only works on the device it runs on.

3. **Full app.** Rebuild it as a real VPN client on top of sing-box/Xray with
   the platform's tunnel API. That's a large project — for actual use on the
   phone/Mac, **Hiddify already does this well**; see
   [`../docs/08-apps-and-toggle.md`](../docs/08-apps-and-toggle.md).

> For your relative's daily use, Hiddify remains the practical client. This
> dashboard is a great base if you later want your own branded generator or
> control panel — option 1 is the natural next step.
