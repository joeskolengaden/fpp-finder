#!/usr/bin/env python3
"""Tiny fake FPP 5.4.1 used by CI (Android emulator smoke test).

Serves the desktop app's recorded fixtures over HTTP, GET only, like a real FPP:
  /api/fppd/version, /api/fppd/status, /api/fppd/multiSyncSystems,
  /api/plugin, /api/network/interface   (anything else, e.g. /api/system/info, is a 404)
Any other method gets 405, which also demonstrates the app never sends one.

usage: fake_fpp.py <fixtures-dir> [port]
"""
import http.server
import pathlib
import sys

FIX = pathlib.Path(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 80
ROUTES = {
    "/api/fppd/version": "fpp-version.json",
    "/api/fppd/status": "fpp-status.json",
    "/api/fppd/multiSyncSystems": "fpp-multisync.json",
    "/api/plugin": "fpp-plugins.json",
    "/api/network/interface": "fpp-interfaces.json",
}


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = ROUTES.get(self.path.split("?")[0])
        if name is None:
            body, code, ctype = b"<html>404</html>", 404, "text/html"
        else:
            body, code, ctype = (FIX / name).read_bytes(), 200, "application/json"
        print("GET", self.path, code, flush=True)
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _no(self):
        print("UNEXPECTED", self.command, self.path, flush=True)
        self.send_response(405)
        self.end_headers()

    do_POST = do_PUT = do_DELETE = do_PATCH = _no

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
