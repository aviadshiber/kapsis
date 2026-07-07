#!/usr/bin/env python3
"""
Minimal mock Anthropic Messages API server for Kapsis integration tests.

Speaks just enough of the streaming API to cause Claude Code to:
  1. Execute a Bash tool call → fires PostToolUse hooks
  2. Finish with end_turn   → fires Stop hooks

Usage:
    python3 mock-api-server.py [port]

Prints "READY:{port}" to stdout once the server is accepting connections.
Accepts any ANTHROPIC_API_KEY value — no real credentials needed.

Set in the test environment:
    ANTHROPIC_BASE_URL=http://127.0.0.1:{port}
    ANTHROPIC_API_KEY=mock-key-kapsis-test
"""
import json
import socket
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT = int(sys.argv[1]) if len(sys.argv) > 1 else _free_port()


# ---------------------------------------------------------------------------
# Response builders
# ---------------------------------------------------------------------------

def _sse(*events) -> bytes:
    """Encode a sequence of (event_type, data_dict) pairs as SSE bytes."""
    parts = []
    for event_type, data in events:
        parts.append(f"event: {event_type}\ndata: {json.dumps(data)}\n\n")
    return "".join(parts).encode()


def _tool_use_sse() -> bytes:
    return _sse(
        ("message_start", {
            "type": "message_start",
            "message": {
                "id": "msg_mock_001", "type": "message", "role": "assistant",
                "content": [], "model": "claude-haiku-4-5-20251001",
                "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 50, "output_tokens": 0},
            },
        }),
        ("content_block_start", {
            "type": "content_block_start", "index": 0,
            "content_block": {
                "type": "tool_use", "id": "toolu_mock_001",
                "name": "Bash", "input": {},
            },
        }),
        ("content_block_delta", {
            "type": "content_block_delta", "index": 0,
            "delta": {
                "type": "input_json_delta",
                "partial_json": json.dumps({"command": "echo kapsis-mock-hook-ran"}),
            },
        }),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": "tool_use", "stop_sequence": None},
            "usage": {"output_tokens": 25},
        }),
        ("message_stop", {"type": "message_stop"}),
    )


def _end_turn_sse() -> bytes:
    return _sse(
        ("message_start", {
            "type": "message_start",
            "message": {
                "id": "msg_mock_002", "type": "message", "role": "assistant",
                "content": [], "model": "claude-haiku-4-5-20251001",
                "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 80, "output_tokens": 0},
            },
        }),
        ("content_block_start", {
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""},
        }),
        ("content_block_delta", {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": "Done."},
        }),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": 5},
        }),
        ("message_stop", {"type": "message_stop"}),
    )


def _tool_use_json() -> bytes:
    return json.dumps({
        "id": "msg_mock_001", "type": "message", "role": "assistant",
        "content": [{
            "type": "tool_use", "id": "toolu_mock_001", "name": "Bash",
            "input": {"command": "echo kapsis-mock-hook-ran"},
        }],
        "model": "claude-haiku-4-5-20251001",
        "stop_reason": "tool_use", "stop_sequence": None,
        "usage": {"input_tokens": 50, "output_tokens": 25},
    }).encode()


def _end_turn_json() -> bytes:
    return json.dumps({
        "id": "msg_mock_002", "type": "message", "role": "assistant",
        "content": [{"type": "text", "text": "Done."}],
        "model": "claude-haiku-4-5-20251001",
        "stop_reason": "end_turn", "stop_sequence": None,
        "usage": {"input_tokens": 80, "output_tokens": 5},
    }).encode()


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------

class MockAPIHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        """Catch-all for health checks, model listing, etc."""
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "11")
        self.end_headers()
        self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            req = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            req = {}

        # If any message contains a tool_result block this is the follow-up
        # request → respond with end_turn so Claude Code finishes cleanly.
        has_tool_result = any(
            isinstance(msg.get("content"), list)
            and any(b.get("type") == "tool_result" for b in msg["content"])
            for msg in req.get("messages", [])
        )

        if req.get("stream", False):
            body_bytes = _end_turn_sse() if has_tool_result else _tool_use_sse()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)
        else:
            body_bytes = _end_turn_json() if has_tool_result else _tool_use_json()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)

    def log_message(self, fmt, *args):  # suppress access logs
        pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), MockAPIHandler)
    print(f"READY:{PORT}", flush=True)
    server.serve_forever()
