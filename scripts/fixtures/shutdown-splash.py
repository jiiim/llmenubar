#!/usr/bin/python3
# SPDX-FileCopyrightText: Copyright James Martin
# SPDX-License-Identifier: MIT

"""Manual lifecycle fixture. Implements health endpoints, not inference."""
import argparse
import http.server
import os
import signal

parser = argparse.ArgumentParser()
parser.add_argument("--version", action="version", version="Splash 1.6.1")
parser.add_argument("command", nargs="?", default="serve")
parser.add_argument("--model")
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=18991)
args, _ = parser.parse_known_args()
if os.environ.get("LLMENUBAR_FIXTURE_IGNORE_TERM") == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ok"
        self.send_response(200 if self.path in ("/ready", "/health") else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class Server(http.server.HTTPServer):
    allow_reuse_address = True

server = Server((args.host, args.port), Handler)
print(f"Shutdown fixture ready: PID {os.getpid()}, port {args.port}", flush=True)
server.serve_forever()
