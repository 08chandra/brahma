#!/usr/bin/env python3 -I
"""X1-0 probe: a deny-all HTTP proxy on 127.0.0.1.

Logs every `CONNECT host:port` and every plain (absolute-form) request target it receives, answers 403 to all of them,
and never opens a connection anywhere. The log is one JSON line per request: method, target, Host header, the other
header NAMES (values of `proxy-authorization`/`authorization` and the like are never logged).

  --log PATH          the request log (appended)
  --port-file PATH    where the chosen ephemeral port is written

Standard library only. Run with `python3 -I`.
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
LOCK = threading.Lock()
COUNT = {"n": 0}


def log(obj):
    with LOCK:
        with open(ARGS.log, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, sort_keys=True) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "x1-0-deny/1"
    sys_version = ""

    def log_message(self, fmt, *args):
        return

    def _deny(self):
        with LOCK:
            COUNT["n"] += 1
            n = COUNT["n"]
        log({"n": n, "t": round(time.time(), 3), "method": self.command, "target": self.path,
             "host": self.headers.get("Host"), "header_names": list(self.headers.keys())})
        body = b"x1-0 deny proxy: refused\n"
        self.send_response(403)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    do_CONNECT = _deny
    do_GET = _deny
    do_POST = _deny
    do_PUT = _deny
    do_HEAD = _deny
    do_DELETE = _deny
    do_OPTIONS = _deny
    do_PATCH = _deny


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--log", required=True)
    p.add_argument("--port-file", default=None)
    ARGS = p.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    port = server.server_address[1]
    if ARGS.port_file:
        with open(ARGS.port_file, "w", encoding="utf-8") as f:
            f.write(str(port))
    log({"deny_proxy": "start", "port": port, "t": round(time.time(), 3)})
    print("PORT %d" % port, flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
