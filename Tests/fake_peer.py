#!/usr/bin/env python3
"""A tiny LocalSend v2 peer used to test SwiftDrop end-to-end without a phone.

  python3 fake_peer.py serve  --port 53318 --out ./inbox [--https]
      Announces over multicast, answers /register and accepts every upload.
  python3 fake_peer.py send   --to 127.0.0.1:53317 [--https] FILE... [--text "hi"]
      Sends files/text to a LocalSend receiver (e.g. SwiftDrop) like the real app does.
"""
import argparse, http.server, json, os, socket, ssl, struct, subprocess, sys, tempfile, threading, urllib.parse, urllib.request, uuid

GROUP, MPORT = "224.0.0.167", 53317
FP = "fakepeerf640b31c"

def info(port, scheme, announce=None):
    d = {"alias": "Fake Pixel", "version": "2.1", "deviceModel": "Pixel 9", "deviceType": "mobile",
         "fingerprint": FP, "port": port, "protocol": scheme, "download": False}
    if announce is not None: d["announce"] = announce
    return d

def ctx_unverified():
    c = ssl.create_default_context(); c.check_hostname = False; c.verify_mode = ssl.CERT_NONE; return c

def serve(a):
    os.makedirs(a.out, exist_ok=True)
    scheme = "https" if a.https else "http"
    sessions = {}
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *x): pass
        def body(self):
            n = int(self.headers.get("Content-Length", 0)); return self.rfile.read(n) if n else b""
        def reply(self, code, obj=None):
            data = json.dumps(obj).encode() if obj is not None else b""
            self.send_response(code); self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
            if u.path.endswith("/register"):
                peer = json.loads(self.body()); print("EVENT register", peer["alias"], peer.get("protocol"), flush=True)
                return self.reply(200, info(a.port, scheme))
            if u.path.endswith("/prepare-upload"):
                req = json.loads(self.body()); sid = uuid.uuid4().hex
                files = req["files"]; print("EVENT prepare", req["info"]["alias"], [f["fileName"] for f in files.values()], flush=True)
                if all(f["fileType"].startswith("text/") and f.get("preview") for f in files.values()):
                    print("EVENT message", [f["preview"] for f in files.values()], flush=True); return self.reply(204)
                sessions[sid] = {fid: (uuid.uuid4().hex, f) for fid, f in files.items()}
                return self.reply(200, {"sessionId": sid, "files": {fid: t for fid, (t, _) in sessions[sid].items()}})
            if u.path.endswith("/upload"):
                tok, f = sessions[q["sessionId"]][q["fileId"]]
                if tok != q["token"]: return self.reply(403)
                path = os.path.join(a.out, f["fileName"]); os.makedirs(os.path.dirname(path), exist_ok=True)
                left = int(self.headers.get("Content-Length", 0)); n = 0
                with open(path, "wb") as out:
                    while left > 0:
                        chunk = self.rfile.read(min(left, 4 << 20))
                        if not chunk: break
                        out.write(chunk); left -= len(chunk); n += len(chunk)
                if not a.quiet: print("EVENT upload", f["fileName"], n, flush=True)
                return self.reply(200)
            if u.path.endswith("/cancel"):
                print("EVENT cancel", flush=True); return self.reply(200)
            self.reply(404)
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", a.port), H)
    if a.https:
        d = tempfile.mkdtemp()
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=fake",
                        "-keyout", d + "/k.pem", "-out", d + "/c.pem"], check=True, capture_output=True)
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(d + "/c.pem", d + "/k.pem")
        srv.socket = c.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("", MPORT))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4s4s", socket.inet_aton(GROUP), socket.inet_aton("0.0.0.0")))
    try: s.sendto(json.dumps(info(a.port, scheme, True)).encode(), (GROUP, MPORT))
    except OSError as e: print("WARN multicast blocked:", e, "(macOS Local Network permission?)", flush=True)
    print(f"READY {scheme} :{a.port} fp={FP}", flush=True)
    while True:
        data, addr = s.recvfrom(65536)
        try: m = json.loads(data)
        except Exception: continue
        if m.get("fingerprint") == FP: continue
        print("EVENT multicast", m.get("alias"), "announce" if m.get("announce") else "response", addr[0], flush=True)
        if m.get("announce"):
          try: s.sendto(json.dumps(info(a.port, scheme, False)).encode(), (GROUP, MPORT))
          except OSError: pass

def post(url, body, ctype="application/json"):
    req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, context=ctx_unverified(), timeout=300) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def send(a):
    scheme = "https" if a.https else "http"; base = f"{scheme}://{a.to}/api/localsend/v2"
    files, blobs = {}, {}
    for p in a.files:
        fid = uuid.uuid4().hex; data = open(p, "rb").read(); blobs[fid] = data
        files[fid] = {"id": fid, "fileName": os.path.basename(p), "size": len(data), "fileType": "application/octet-stream"}
    if a.text:
        fid = uuid.uuid4().hex; data = a.text.encode(); blobs[fid] = data
        files[fid] = {"id": fid, "fileName": fid + ".txt", "size": len(data), "fileType": "text/plain", "preview": a.text}
    code, body = post(base + "/prepare-upload", json.dumps({"info": info(53318, scheme), "files": files}).encode())
    print("PREPARE", code, body[:200], flush=True)
    if code != 200: return
    resp = json.loads(body)
    for fid, tok in resp["files"].items():
        q = urllib.parse.urlencode({"sessionId": resp["sessionId"], "fileId": fid, "token": tok})
        code, _ = post(f"{base}/upload?{q}", blobs[fid], "application/octet-stream"); print("UPLOAD", files[fid]["fileName"], code, flush=True)

ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
p1 = sub.add_parser("serve"); p1.add_argument("--port", type=int, default=53318); p1.add_argument("--out", default="inbox"); p1.add_argument("--https", action="store_true"); p1.add_argument("--quiet", action="store_true")
p2 = sub.add_parser("send"); p2.add_argument("--to", default="127.0.0.1:53317"); p2.add_argument("--https", action="store_true"); p2.add_argument("files", nargs="*"); p2.add_argument("--text")
a = ap.parse_args(); serve(a) if a.cmd == "serve" else send(a)
