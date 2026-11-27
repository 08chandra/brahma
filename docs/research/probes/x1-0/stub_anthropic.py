#!/usr/bin/env python3 -I
"""X1-0 probe: a loopback stub of the Anthropic Messages API.

Binds 127.0.0.1 on an ephemeral port (printed on stdout as `PORT <n>` and written to --port-file), serves
`POST /v1/messages` (SSE when `stream: true`, JSON otherwise) and `POST /v1/messages/count_tokens`, and logs every
request: method, full target (path + query), every request header NAME, header values for everything except the
credential headers (`authorization`, `x-api-key`, `cookie`, `proxy-authorization`, and any name containing `auth`,
`token`, `key` or `secret`), which are logged as `<redacted len=N>` only, and a shape summary of the JSON body (model,
max_tokens, stream, system length, tool names, metadata shape, message roles and content-block types). No body text,
no credential value and no file content is ever written to the log.

Behaviours (argv):
  --mode ok|429|400|401|tool-first   (default ok)
  --fail-count N                     for 429/400/401: fail the first N requests, then answer 200 (default: always)
  --ratelimit-headers                add `anthropic-ratelimit-unified-*` headers to 200 responses
  --sse-deviation none|no-message-stop|done-first
  --log PATH                         the request log (appended)
  --port-file PATH                   where the chosen port is written

Standard library only. Run with `python3 -I`.
"""
import argparse
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REDACT_EXACT = {"authorization", "x-api-key", "cookie", "proxy-authorization"}
REDACT_SUBSTR = ("auth", "token", "key", "secret")

STATE = {"requests": 0, "lock": threading.Lock()}
ARGS = None
LOG_LOCK = threading.Lock()


def log(line):
    with LOG_LOCK:
        with open(ARGS.log, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def redact_name(name):
    n = name.lower()
    return n in REDACT_EXACT or any(s in n for s in REDACT_SUBSTR)


def shape_id(value):
    """A string with every hex/uuid run replaced by `<hex N>` (identifiers are logged by shape, never by value)."""
    if not isinstance(value, str):
        return repr(type(value).__name__)
    return re.sub(r"[0-9a-fA-F-]{8,}", lambda m: "<hex %d>" % len(m.group(0)), value)


def summarize_content(content):
    if isinstance(content, str):
        return "text(len=%d)" % len(content)
    if isinstance(content, list):
        out = []
        for block in content:
            if not isinstance(block, dict):
                out.append(type(block).__name__)
                continue
            t = block.get("type")
            if t == "text":
                out.append("text(len=%d)" % len(block.get("text", "")))
            elif t == "tool_use":
                out.append("tool_use(name=%s,id=%s)" % (block.get("name"), shape_id(block.get("id", ""))))
            elif t == "tool_result":
                inner = block.get("content")
                out.append("tool_result(id=%s,is_error=%s,content=%s)" % (
                    shape_id(block.get("tool_use_id", "")), block.get("is_error"), summarize_content(inner)))
            else:
                out.append(str(t))
        return "[" + ", ".join(out) + "]"
    return type(content).__name__


def summarize_body(raw):
    try:
        body = json.loads(raw.decode("utf-8")) if raw else {}
    except Exception as e:  # noqa: BLE001
        return {"parse_error": str(e), "len": len(raw)}
    if not isinstance(body, dict):
        return {"type": type(body).__name__}
    s = {"keys": sorted(body.keys())}
    s["model"] = body.get("model")
    s["max_tokens"] = body.get("max_tokens")
    s["stream"] = body.get("stream")
    system = body.get("system")
    if isinstance(system, str):
        s["system"] = "str(len=%d)" % len(system)
    elif isinstance(system, list):
        s["system"] = "blocks(n=%d, total_len=%d, cache_control=%s)" % (
            len(system), sum(len(b.get("text", "")) for b in system if isinstance(b, dict)),
            any(isinstance(b, dict) and "cache_control" in b for b in system))
    else:
        s["system"] = None if system is None else type(system).__name__
    tools = body.get("tools")
    if isinstance(tools, list):
        s["tools"] = [t.get("name", t.get("type")) if isinstance(t, dict) else "?" for t in tools]
    md = body.get("metadata")
    if isinstance(md, dict):
        s["metadata"] = {k: shape_id(v) for k, v in md.items()}
    msgs = body.get("messages")
    if isinstance(msgs, list):
        s["messages"] = [{"role": m.get("role"), "content": summarize_content(m.get("content"))}
                         for m in msgs if isinstance(m, dict)]
    for k in ("temperature", "thinking", "tool_choice", "stop_sequences", "top_p", "top_k", "output_format"):
        if k in body:
            v = body[k]
            s[k] = v if isinstance(v, (int, float, bool, str)) or v is None else (
                {"keys": sorted(v.keys())} if isinstance(v, dict) else "list(n=%d)" % len(v))
    return s


def pick_tool(body_summary):
    tools = body_summary.get("tools") or []
    for name in ("Read", "Glob", "Grep", "LS", "TodoWrite"):
        if name in tools:
            return name
    return tools[0] if tools else None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "x1-0-stub/1"
    sys_version = ""

    def log_message(self, fmt, *args):  # silence the default stderr log
        return

    def _read_body(self):
        length = self.headers.get("Content-Length")
        if length:
            return self.rfile.read(int(length))
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            data = b""
            while True:
                line = self.rfile.readline().strip()
                size = int(line.split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                data += self.rfile.read(size)
                self.rfile.readline()
            return data
        return b""

    def _log_request(self, raw):
        with STATE["lock"]:
            STATE["requests"] += 1
            n = STATE["requests"]
        headers = []
        for name, value in self.headers.items():
            if redact_name(name):
                headers.append("%s: <redacted len=%d>" % (name, len(value)))
            else:
                headers.append("%s: %s" % (name, value))
        entry = {
            "n": n, "t": round(time.time(), 3), "method": self.command, "target": self.path,
            "version": self.request_version, "header_names": [h.split(":")[0] for h in headers],
            "headers": headers, "body": summarize_body(raw),
        }
        log(json.dumps(entry, sort_keys=True))
        return n, entry

    def _send(self, status, body, extra=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("request-id", "req_stub_%d" % STATE["requests"])
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def _ratelimit_headers(self):
        if not ARGS.ratelimit_headers:
            return {}
        now = int(time.time())
        return {
            "anthropic-ratelimit-unified-status": "allowed",
            "anthropic-ratelimit-unified-representative-claim": "five_hour",
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
            "anthropic-ratelimit-unified-5h-reset": str(now + 3600),
            "anthropic-ratelimit-unified-7d-utilization": "0.25",
            "anthropic-ratelimit-unified-7d-reset": str(now + 86400),
            "anthropic-ratelimit-unified-reset": str(now + 3600),
            "anthropic-ratelimit-unified-overage-status": "allowed",
        }

    def _error(self, status, kind):
        self._send(status, {"type": "error", "error": {"type": kind, "message": "Brahma: test"}})
        log(json.dumps({"n": STATE["requests"], "response": status, "error_type": kind}))

    def do_GET(self):
        raw = self._read_body()
        self._log_request(raw)
        self._send(404, {"type": "error", "error": {"type": "not_found_error", "message": "stub: not found"}})
        log(json.dumps({"n": STATE["requests"], "response": 404, "note": "GET"}))

    def do_POST(self):
        raw = self._read_body()
        n, entry = self._log_request(raw)
        path = self.path.split("?", 1)[0]
        if path.endswith("/v1/messages/count_tokens"):
            self._send(200, {"input_tokens": 42})
            log(json.dumps({"n": n, "response": 200, "note": "count_tokens"}))
            return
        if not path.endswith("/v1/messages"):
            self._send(404, {"type": "error", "error": {"type": "not_found_error", "message": "stub: not found"}})
            log(json.dumps({"n": n, "response": 404, "note": "unknown path"}))
            return
        mode = ARGS.mode
        failing = ARGS.fail_count is None or n <= ARGS.fail_count
        if mode == "429" and failing:
            return self._error(429, "rate_limit_error")
        if mode == "400" and failing:
            return self._error(400, "invalid_request_error")
        if mode == "401" and failing:
            return self._error(401, "authentication_error")
        body = entry["body"]
        model = body.get("model") or "stub-model"
        tool_first = mode == "tool-first" and n == 1
        tool = pick_tool(body) if tool_first else None
        if tool_first and tool is None:
            log(json.dumps({"n": n, "note": "tool-first asked but the request lists no tools; answering text"}))
        if body.get("stream"):
            self._stream(n, model, tool)
        else:
            self._json(n, model, tool)

    def _json(self, n, model, tool):
        if tool:
            content = [{"type": "tool_use", "id": "toolu_stub_%d" % n, "name": tool,
                        "input": {"file_path": "hello.txt"} if tool == "Read" else {}}]
            stop = "tool_use"
        else:
            content = [{"type": "text", "text": "ok"}]
            stop = "end_turn"
        msg = {"id": "msg_stub_%d" % n, "type": "message", "role": "assistant", "model": model, "content": content,
               "stop_reason": stop, "stop_sequence": None,
               "usage": {"input_tokens": 25, "output_tokens": 7, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}
        self._send(200, msg, self._ratelimit_headers())
        log(json.dumps({"n": n, "response": 200, "note": "json", "stop_reason": stop, "tool": tool}))

    def _stream(self, n, model, tool):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.send_header("request-id", "req_stub_%d" % n)
        for k, v in self._ratelimit_headers().items():
            self.send_header(k, v)
        self.end_headers()

        def ev(name, obj):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(obj))).encode())
            self.wfile.flush()

        dev = ARGS.sse_deviation
        sent = []
        if dev == "done-first":
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            sent.append("[DONE]")
        ev("message_start", {"type": "message_start", "message": {
            "id": "msg_stub_%d" % n, "type": "message", "role": "assistant", "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 25, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}})
        sent.append("message_start")
        if tool:
            ev("content_block_start", {"type": "content_block_start", "index": 0,
                                       "content_block": {"type": "tool_use", "id": "toolu_stub_%d" % n, "name": tool, "input": {}}})
            args = json.dumps({"file_path": "hello.txt"} if tool == "Read" else {})
            half = len(args) // 2
            for part in (args[:half], args[half:]):
                ev("content_block_delta", {"type": "content_block_delta", "index": 0,
                                           "delta": {"type": "input_json_delta", "partial_json": part}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            sent += ["content_block_start(tool_use)", "content_block_delta(input_json_delta)x2", "content_block_stop"]
            stop = "tool_use"
        else:
            ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            for part in ("o", "k"):
                ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": part}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            sent += ["content_block_start(text)", "content_block_delta(text_delta)x2", "content_block_stop"]
            stop = "end_turn"
        ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                             "usage": {"output_tokens": 7}})
        sent.append("message_delta(%s)" % stop)
        if dev != "no-message-stop":
            ev("message_stop", {"type": "message_stop"})
            sent.append("message_stop")
        log(json.dumps({"n": n, "response": 200, "note": "sse", "events": sent, "tool": tool, "deviation": dev}))


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--mode", default="ok", choices=["ok", "429", "400", "401", "tool-first"])
    p.add_argument("--fail-count", type=int, default=None)
    p.add_argument("--ratelimit-headers", action="store_true")
    p.add_argument("--sse-deviation", default="none", choices=["none", "no-message-stop", "done-first"])
    p.add_argument("--log", required=True)
    p.add_argument("--port-file", default=None)
    ARGS = p.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    port = server.server_address[1]
    if ARGS.port_file:
        with open(ARGS.port_file, "w", encoding="utf-8") as f:
            f.write(str(port))
    log(json.dumps({"stub": "start", "port": port, "mode": ARGS.mode, "fail_count": ARGS.fail_count,
                    "ratelimit_headers": ARGS.ratelimit_headers, "sse_deviation": ARGS.sse_deviation, "t": round(time.time(), 3)}))
    print("PORT %d" % port, flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
