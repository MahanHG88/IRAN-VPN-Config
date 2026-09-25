#!/usr/bin/env python3
"""
cloudflare-configure.py — set up Cloudflare for the CDN-fronted VPN, automatically.

Run this on YOUR machine (or the VPS). It asks for your Cloudflare API token
(hidden input — never written to disk or the repo) and then configures:

  1. a PROXIED A record   <hostname> -> <VPS IP>     (orange cloud)
  2. SSL/TLS mode          -> Full
  3. WebSockets            -> On
  4. an Origin Rule        -> rewrite origin port to <port>   (so visitors use
                              443 but Cloudflare dials your origin on e.g. 2053)

It's idempotent: re-running updates the same record/rule instead of duplicating.

Stdlib only — no `pip install`. Requires Python 3.7+.

TOKEN PERMISSIONS: create a Cloudflare API token (dashboard -> My Profile ->
API Tokens -> Create Token -> Custom token) with, for the target zone:
  * Zone : Zone           : Read
  * Zone : DNS            : Edit
  * Zone : Zone Settings  : Edit
  * Zone : Config Rules   : Edit   (for the Origin Rule; if missing, that one
                                    step is skipped and you add it by hand)

SECURITY: the token you type is used only to call api.cloudflare.com and is not
saved. If you pasted tokens into a chat earlier, revoke those.
"""
import getpass
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4"


def call(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"success": False, "errors": [{"message": f"HTTP {e.code} {e.reason}"}]}
    except urllib.error.URLError as e:
        return {"success": False, "errors": [{"message": f"network error: {e.reason}"}]}


def ok(resp):
    return bool(resp.get("success"))


def errmsg(resp):
    es = resp.get("errors") or [{"message": "unknown error"}]
    return "; ".join(str(x.get("message", x)) for x in es)


def die(msg):
    print("\n\033[1;31mERROR:\033[0m " + msg)
    sys.exit(1)


def prompt(label, default=None, env=None):
    if env and os.environ.get(env):
        return os.environ[env].strip()
    suffix = f" [{default}]" if default else ""
    val = input(f"{label}{suffix}: ").strip()
    return val or (default or "")


def main():
    print("=== Cloudflare VPN configurator ===\n")

    token = os.environ.get("CF_API_TOKEN") or getpass.getpass(
        "Cloudflare API token (input hidden): ").strip()
    if not token:
        die("no token provided.")

    hostname = prompt("VPN hostname (e.g. vpn.mooooz.lol)", env="CF_HOSTNAME")
    if not hostname or "." not in hostname:
        die("please give a full hostname like vpn.mooooz.lol")
    ip = prompt("VPS public IP (e.g. 49.12.209.153)", env="CF_ORIGIN_IP")
    if not ip:
        die("VPS IP is required.")
    port = prompt("Origin port", default="2053", env="CF_ORIGIN_PORT")
    try:
        port_i = int(port)
    except ValueError:
        die("origin port must be a number.")

    # --- verify token ---
    v = call("GET", "/user/tokens/verify", token)
    if not ok(v):
        die("token verification failed: " + errmsg(v) +
            "\nCheck the token value and its permissions.")
    print("token: valid (" + str(v.get("result", {}).get("status", "active")) + ")")

    # --- find the zone (longest zone name that is a suffix of the hostname) ---
    z = call("GET", "/zones?per_page=50", token)
    if not ok(z):
        die("could not list zones: " + errmsg(z) + "\nDoes the token have Zone:Read?")
    zones = z.get("result", [])
    matches = [zz for zz in zones
               if hostname == zz["name"] or hostname.endswith("." + zz["name"])]
    if not matches:
        names = ", ".join(zz["name"] for zz in zones) or "(none)"
        die(f"no zone on this token matches {hostname}. Zones available: {names}")
    zone = max(matches, key=lambda zz: len(zz["name"]))
    zid = zone["id"]
    print(f"zone:  {zone['name']}  ({zid})\n")

    results = []

    # --- 1) proxied A record ---
    rr = call("GET", f"/zones/{zid}/dns_records?type=A&name={hostname}", token)
    recs = rr.get("result", []) if ok(rr) else []
    body = {"type": "A", "name": hostname, "content": ip, "proxied": True, "ttl": 1}
    if recs:
        r = call("PATCH", f"/zones/{zid}/dns_records/{recs[0]['id']}", token, body)
        verb = "updated"
    else:
        r = call("POST", f"/zones/{zid}/dns_records", token, body)
        verb = "created"
    results.append((f"A record {hostname} -> {ip} (proxied) {verb}",
                    ok(r), "" if ok(r) else errmsg(r)))

    # --- 2) SSL mode -> full ---
    r = call("PATCH", f"/zones/{zid}/settings/ssl", token, {"value": "full"})
    results.append(("SSL/TLS mode -> Full", ok(r), "" if ok(r) else errmsg(r)))

    # --- 3) WebSockets -> on ---
    r = call("PATCH", f"/zones/{zid}/settings/websockets", token, {"value": "on"})
    # On Free this is often on-by-default and not settable; treat failure as non-fatal.
    results.append(("WebSockets -> On", ok(r),
                    "" if ok(r) else "skipped (" + errmsg(r) + ") — usually already on"))

    # --- 4) Origin Rule: rewrite origin port ---
    desc = f"cf-vpn origin port rewrite ({hostname})"
    ep = call("GET", f"/zones/{zid}/rulesets/phases/http_request_origin/entrypoint", token)
    existing = ep.get("result", {}).get("rules", []) if ok(ep) else []
    existing = [rule for rule in existing if rule.get("description") != desc]
    newrule = {
        "action": "route",
        "action_parameters": {"origin": {"port": port_i}},
        "expression": f'(http.host eq "{hostname}")',
        "description": desc,
        "enabled": True,
    }
    put = call("PUT", f"/zones/{zid}/rulesets/phases/http_request_origin/entrypoint",
               token, {"rules": existing + [newrule]})
    results.append((f"Origin Rule: {hostname} -> port {port_i}", ok(put),
                    "" if ok(put) else errmsg(put)))

    # --- summary ---
    print("\n----------------------- results -----------------------")
    all_ok = True
    for label, good, note in results:
        mark = "\033[1;32mOK\033[0m" if good else "\033[1;31mFAILED\033[0m"
        print(f"  [{mark}] {label}" + (f"  ({note})" if note else ""))
        if not good and "skipped" not in note:
            all_ok = False
    print("-------------------------------------------------------")

    if not results[-1][1]:  # Origin Rule failed
        print("\nOrigin Rule not applied automatically. Add it by hand:")
        print("  Cloudflare -> Rules -> Origin Rules -> Create rule")
        print(f"    If hostname equals {hostname}  ->  Rewrite to  Port = {port_i}")
        print("  (Token likely missing 'Zone : Config Rules : Edit'.)")

    print("\nNext: import your vless://...@%s:443... link into Hiddify and connect." % hostname)
    print("Reminder: if you pasted any tokens in a chat, revoke them now.")
    sys.exit(0 if all_ok else 2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\naborted.")
        sys.exit(1)
