#!/usr/bin/env python3
"""Local stand-in for the Messages API used by the ClaudeKit integration tests.

Prints the bound port on the first stdout line. Path prefixes select a scenario:
  /v1/messages               streamed response in small chunks
  /overloaded-once/v1/...    first call 529 (retry-after: 0), then a normal stream
  /drop/v1/messages          partial stream, then the connection closes
  /redirect/v1/messages      302 to /v1/messages (clients must not follow)
  /v1/models                 JSON model list
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = "sk-ant-local"
STATE = {"overloaded": 0}
LOCK = threading.Lock()


def sse(event, payload):
    return f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode()


def full_stream(text_parts):
    out = sse("message_start", {"type": "message_start", "message": {"id": "msg_local", "model": "claude-opus-5-5", "usage": {"input_tokens": 5, "output_tokens": 1}}})
    out += b": keep-alive comment\n\n"
    out += sse("ping", {"type": "ping"})
    out += sse("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
    out += sse("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Denke nach…"}})
    out += sse("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "sig-local"}})
    out += sse("content_block_stop", {"type": "content_block_stop", "index": 0})
    out += sse("content_block_start", {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}})
    for part in text_parts:
        out += sse("content_block_delta", {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": part}})
    out += sse("content_block_stop", {"type": "content_block_stop", "index": 1})
    out += sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 9}})
    out += sse("message_stop", {"type": "message_stop"})
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, status, payload, extra=None):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("request-id", "req_local")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if self.headers.get("x-api-key") != API_KEY:
            self.send_json(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path.startswith("/v1/models"):
            self.send_json(200, {"data": [{"id": "claude-opus-5-5"}], "has_more": False})
        else:
            self.send_json(404, {"type": "error", "error": {"type": "not_found_error", "message": "nope"}})

    def stream(self, payload, chunk=7, drop=False):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream; charset=utf-8")
        self.send_header("cache-control", "no-cache")
        self.send_header("request-id", "req_local")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True
        for i in range(0, len(payload), chunk):
            self.wfile.write(payload[i:i + chunk])
            self.wfile.flush()
            time.sleep(0.001)
        if drop:
            self.connection.shutdown(2)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.authorized():
            return
        if self.path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("location", "/v1/messages")
            self.send_header("content-length", "0")
            self.end_headers()
            return
        if body.get("stream") is not True or self.headers.get("anthropic-version") != "2023-06-01":
            self.send_json(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "bad request shape"}})
            return
        if self.path.startswith("/overloaded-once/"):
            with LOCK:
                STATE["overloaded"] += 1
                first = STATE["overloaded"] == 1
            if first:
                self.send_json(529, {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}, {"retry-after": "0"})
                return
        if self.path.startswith("/drop/"):
            payload = full_stream(["abgebrochen"])
            self.stream(payload[: len(payload) // 2], drop=True)
            return
        echo = body["messages"][-1]["content"][0]["text"]
        self.stream(full_stream(["Echo: ", echo, " – ✓"]))


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
