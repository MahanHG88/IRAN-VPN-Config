#!/usr/bin/env python3
"""
icmp-tunnel-app.py — a tiny local On/Off panel for the ICMP tunnel (LINUX only).

This gives you a click-not-commands experience for the last-resort ICMP tunnel:
run it once with sudo, open the page it prints, and use the On/Off button.

    sudo python3 scripts/icmp-tunnel-app.py
    # then open http://127.0.0.1:8765 in a browser

WHY LINUX ONLY:
    ICMP tunneling (hans) needs a `tun` device and raw sockets. That works on
    Linux. It does NOT work on a normal Android phone (no root) and is broken on
    modern macOS (deprecated tun kernel extensions + SIP). So run this on a Linux
    client — a spare PC, a Raspberry Pi, a router, or a Linux VM.

It wraps `hans` directly: starts/stops it, and (optionally) full-tunnels your
traffic through it while keeping a host route to the server via your real
gateway so you don't cut your own link. Everything is restored when you turn it
Off or quit. Stdlib only — no pip installs.
"""
import http.server
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.parse

TUN_DEV = "tun0"
TUN_SERVER_IP = "10.9.0.1"   # server side of the tunnel
MTU = "1200"
DNS_FALLBACK = "1.1.1.1"
LISTEN = ("127.0.0.1", 8765)

STATE = {
    "connected": False,
    "server": "",
    "full_tunnel": False,
    "orig_gw": "",
    "orig_dev": "",
    "pid": None,
    "last_error": "",
}


def sh(args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def require_linux_root():
    if platform.system() != "Linux":
        sys.exit("This panel only works on Linux (see the header comment for why).")
    if os.geteuid() != 0:
        sys.exit("Run with sudo:  sudo python3 scripts/icmp-tunnel-app.py")
    if not shutil.which("hans"):
        sys.exit("'hans' is not installed. Install it (e.g. apt install hans) or "
                 "use scripts/icmp-tunnel.sh which installs it for you.")


def tun_up():
    try:
        sh(["ip", "link", "show", TUN_DEV])
        return True
    except subprocess.CalledProcessError:
        return False


def default_route():
    out = sh(["ip", "route", "show", "default"]).stdout.split()
    gw = dev = ""
    if "via" in out:
        gw = out[out.index("via") + 1]
    if "dev" in out:
        dev = out[out.index("dev") + 1]
    return gw, dev


def connect(server, password, full_tunnel):
    if STATE["connected"]:
        return
    if not server or not password:
        raise ValueError("server IP and password are required")

    gw, dev = default_route()
    if not gw or not dev:
        raise RuntimeError("could not detect your current default route")
    STATE["orig_gw"], STATE["orig_dev"] = gw, dev

    proc = subprocess.Popen(
        ["hans", "-f", "-c", server, "-p", password, "-d", TUN_DEV, "-m", MTU, "-i"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    STATE["pid"] = proc.pid

    for _ in range(30):
        if tun_up():
            break
        if proc.poll() is not None:
            raise RuntimeError("hans exited immediately — check server IP / password / that ICMP reaches the server")
        time.sleep(1)
    else:
        proc.terminate()
        raise RuntimeError(f"tunnel device {TUN_DEV} did not come up")

    if full_tunnel:
        sh(["ip", "route", "replace", server, "via", gw, "dev", dev])
        sh(["ip", "route", "replace", "default", "via", TUN_SERVER_IP, "dev", TUN_DEV])
        try:
            if os.path.exists("/etc/resolv.conf"):
                shutil.copy2("/etc/resolv.conf", "/etc/resolv.conf.icmptun.bak")
            with open("/etc/resolv.conf", "w") as f:
                f.write(f"nameserver {DNS_FALLBACK}\n")
        except OSError as e:
            STATE["last_error"] = f"DNS switch failed (non-fatal): {e}"

    STATE.update(connected=True, server=server, full_tunnel=full_tunnel, last_error="")


def disconnect():
    if STATE["full_tunnel"]:
        gw, dev, server = STATE["orig_gw"], STATE["orig_dev"], STATE["server"]
        if gw and dev:
            sh(["ip", "route", "replace", "default", "via", gw, "dev", dev], check=False)
            sh(["ip", "route", "del", server, "via", gw, "dev", dev], check=False)
        if os.path.exists("/etc/resolv.conf.icmptun.bak"):
            shutil.move("/etc/resolv.conf.icmptun.bak", "/etc/resolv.conf")
    if STATE["pid"]:
        try:
            os.kill(STATE["pid"], signal.SIGTERM)
        except ProcessLookupError:
            pass
    STATE.update(connected=False, pid=None, full_tunnel=False)


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ICMP Tunnel</title><style>
:root{color-scheme:light dark}
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:440px;
margin:40px auto;padding:0 16px}
h1{font-size:1.3rem}
.card{border:1px solid #8884;border-radius:12px;padding:20px;margin-top:16px}
label{display:block;margin:10px 0 4px;font-size:.9rem}
input,button{font-size:1rem;padding:10px;border-radius:8px;border:1px solid #8886;width:100%;box-sizing:border-box}
.row{display:flex;gap:8px;align-items:center}.row input[type=checkbox]{width:auto}
.toggle{margin-top:16px;font-weight:600;color:#fff;border:none;cursor:pointer}
.on{background:#137333}.off{background:#b3261e}
.status{margin-top:14px;font-size:.95rem}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;vertical-align:middle}
.err{color:#b3261e;font-size:.85rem;margin-top:8px;white-space:pre-wrap}
small{opacity:.7}
</style></head><body>
<h1>ICMP Tunnel <small>(last resort)</small></h1>
<div class="card">
  <label>Server IP (your VPS)</label><input id="server" placeholder="1.2.3.4">
  <label>Password (must match the server)</label><input id="password" type="password">
  <label class="row"><input type="checkbox" id="full"> Route ALL traffic through it (full tunnel)</label>
  <button id="btn" class="toggle off">Turn ON</button>
  <div class="status"><span id="dot" class="dot" style="background:#b3261e"></span><span id="st">Off</span></div>
  <div class="err" id="err"></div>
  <p><small>Slow by design. If plain <code>ping</code> to the server fails, this will too.</small></p>
</div>
<script>
async function refresh(){
  const r=await fetch('/status');const s=await r.json();
  document.getElementById('st').textContent=s.connected?('On — '+s.server+(s.full_tunnel?' (full tunnel)':'')):'Off';
  document.getElementById('dot').style.background=s.connected?'#137333':'#b3261e';
  const b=document.getElementById('btn');
  b.textContent=s.connected?'Turn OFF':'Turn ON';
  b.className='toggle '+(s.connected?'on':'off');
  document.getElementById('err').textContent=s.last_error||'';
  b.dataset.on=s.connected?'1':'0';
}
document.getElementById('btn').onclick=async()=>{
  const on=document.getElementById('btn').dataset.on==='1';
  document.getElementById('err').textContent='';
  if(on){await fetch('/disconnect',{method:'POST'});}
  else{
    const body=new URLSearchParams({server:document.getElementById('server').value,
      password:document.getElementById('password').value,
      full:document.getElementById('full').checked?'1':'0'});
    const r=await fetch('/connect',{method:'POST',body});
    if(!r.ok){document.getElementById('err').textContent=await r.text();}
  }
  refresh();
};
refresh();setInterval(refresh,2000);
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            self._send(200, PAGE)
        elif self.path == "/status":
            self._send(200, json.dumps({
                "connected": STATE["connected"], "server": STATE["server"],
                "full_tunnel": STATE["full_tunnel"], "last_error": STATE["last_error"],
            }), "application/json")
        else:
            self._send(404, "not found")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        data = urllib.parse.parse_qs(self.rfile.read(n).decode())
        try:
            if self.path == "/connect":
                connect(data.get("server", [""])[0].strip(),
                        data.get("password", [""])[0],
                        data.get("full", ["0"])[0] == "1")
                self._send(200, "ok")
            elif self.path == "/disconnect":
                disconnect()
                self._send(200, "ok")
            else:
                self._send(404, "not found")
        except Exception as e:  # surface the reason to the UI
            STATE["last_error"] = str(e)
            self._send(500, str(e))


def main():
    require_linux_root()
    httpd = http.server.HTTPServer(LISTEN, Handler)
    url = f"http://{LISTEN[0]}:{LISTEN[1]}"
    print(f"ICMP tunnel panel running at {url}")
    print("Open that in your browser. Ctrl-C here to quit (also turns the tunnel Off).")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if STATE["connected"]:
            disconnect()
        print("\nstopped, network restored.")


if __name__ == "__main__":
    main()
