#!/usr/bin/env python3
"""
TokenTracker Proxy Server

A local HTTP proxy that transparently forwards requests to the Anthropic API,
logs token usage from each response into a SQLite database, and returns the
response unchanged to the caller.

Usage:
    python3 proxy_server.py [--port 5005] [--db ~/.tokentracker/usage.db]

Environment:
    Set ANTHROPIC_BASE_URL=http://localhost:5005 in your shell profile
    so Claude Code and your scripts route through this proxy.
"""

import argparse
import http.client
import json
import logging
import os
import signal
import sqlite3
import ssl
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ANTHROPIC_HOST = "api.anthropic.com"
DEFAULT_PORT = 5005
DEFAULT_DB_PATH = os.path.expanduser("~/.tokentracker/usage.db")
LOG_FORMAT = "%(asctime)s [%(levelname)s] %(message)s"

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

class UsageDatabase:
    """Thread-safe SQLite database for token usage logging."""

    def __init__(self, db_path: str):
        self.db_path = db_path
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self._local = threading.local()
        self._init_db()

    def _get_conn(self) -> sqlite3.Connection:
        if not hasattr(self._local, "conn") or self._local.conn is None:
            self._local.conn = sqlite3.connect(self.db_path)
            self._local.conn.execute("PRAGMA journal_mode=WAL")
            self._local.conn.execute("PRAGMA foreign_keys=ON")
        return self._local.conn

    def _init_db(self):
        conn = self._get_conn()
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS requests (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       TEXT    NOT NULL,
                provider        TEXT    NOT NULL DEFAULT 'anthropic',
                model           TEXT    NOT NULL,
                endpoint        TEXT    NOT NULL,
                input_tokens    INTEGER NOT NULL DEFAULT 0,
                output_tokens   INTEGER NOT NULL DEFAULT 0,
                cache_creation_input_tokens  INTEGER NOT NULL DEFAULT 0,
                cache_read_input_tokens      INTEGER NOT NULL DEFAULT 0,
                status_code     INTEGER,
                request_id      TEXT,
                stop_reason     TEXT,
                caller          TEXT,
                error           TEXT,
                api_key_hint    TEXT    NOT NULL DEFAULT ''
            );

            CREATE INDEX IF NOT EXISTS idx_requests_timestamp
                ON requests(timestamp);
        """)
        # Migrate: add api_key_hint column if missing
        try:
            conn.execute("SELECT api_key_hint FROM requests LIMIT 1")
        except sqlite3.OperationalError:
            conn.execute(
                "ALTER TABLE requests ADD COLUMN api_key_hint TEXT NOT NULL DEFAULT ''")

        # Migrate: add provider column if missing
        try:
            conn.execute("SELECT provider FROM requests LIMIT 1")
        except sqlite3.OperationalError:
            conn.execute(
                "ALTER TABLE requests ADD COLUMN provider TEXT NOT NULL DEFAULT 'anthropic'"
            )
        conn.commit()

    def log_request(self, *, model: str, endpoint: str,
                    input_tokens: int, output_tokens: int,
                    cache_creation_input_tokens: int = 0,
                    cache_read_input_tokens: int = 0, status_code: int = 0,
                    request_id: str = "", stop_reason: str = "",
                    caller: str = "", error: str = "",
                    api_key_hint: str = ""):
        conn = self._get_conn()
        conn.execute("""
            INSERT INTO requests
                (timestamp, provider, model, endpoint, input_tokens, output_tokens,
                 cache_creation_input_tokens, cache_read_input_tokens,
                 status_code, request_id, stop_reason, caller, error,
                 api_key_hint)
            VALUES (?, 'anthropic', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            datetime.now(timezone.utc).isoformat(),
            model, endpoint, input_tokens, output_tokens,
            cache_creation_input_tokens, cache_read_input_tokens,
            status_code, request_id, stop_reason, caller, error,
            api_key_hint,
        ))
        conn.commit()
        logging.info(
            "Logged: model=%s in=%d out=%d cache_create=%d cache_read=%d",
            model, input_tokens, output_tokens,
            cache_creation_input_tokens, cache_read_input_tokens,
        )

# ---------------------------------------------------------------------------
# Proxy Handler
# ---------------------------------------------------------------------------

class ProxyHandler(BaseHTTPRequestHandler):
    """Handles incoming HTTP requests and proxies them to the Anthropic API."""

    # Class-level references (set before server starts)
    db: UsageDatabase = None

    # Suppress default logging to stderr; we use our own logger
    def log_message(self, format, *args):
        logging.debug("HTTP: %s", format % args)

    def _proxy_request(self):
        """Forward request to Anthropic, log usage, return response."""
        path = self.path
        method = self.command

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        # Parse request body to extract model and detect streaming
        request_json = {}
        is_streaming = False
        model = "unknown"
        if body:
            try:
                request_json = json.loads(body)
                model = request_json.get("model", "unknown")
                is_streaming = request_json.get("stream", False)
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass

        # Identify caller from custom header (optional)
        caller = self.headers.get("X-TokenTracker-Caller", "")

        # Capture masked API key hint (last 8 chars) for segregation
        api_key = self.headers.get("x-api-key", "")
        api_key_hint = f"...{api_key[-8:]}" if len(api_key) >= 8 else ""

        # Connect to Anthropic API
        context = ssl.create_default_context()
        conn = http.client.HTTPSConnection(
            ANTHROPIC_HOST, 443, context=context, timeout=300
        )

        # Build headers to forward (skip hop-by-hop headers)
        skip_headers = {
            "host", "connection", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "te", "trailers",
            "transfer-encoding", "upgrade", "x-tokentracker-caller",
        }
        forward_headers = {}
        for key, value in self.headers.items():
            if key.lower() not in skip_headers:
                forward_headers[key] = value
        forward_headers["Host"] = ANTHROPIC_HOST

        try:
            conn.request(method, path, body=body, headers=forward_headers)
            response = conn.getresponse()
        except Exception as e:
            logging.error("Failed to connect to %s: %s", ANTHROPIC_HOST, e)
            self._send_error(502, f"Proxy error: {e}")
            self.db.log_request(
                model=model, endpoint=path, input_tokens=0,
                output_tokens=0, caller=caller,
                api_key_hint=api_key_hint,
                error=f"Connection failed: {e}",
            )
            return

        status = response.status
        response_headers = response.getheaders()

        if is_streaming and status == 200:
            self._handle_streaming(
                response, response_headers, status,
                model=model, endpoint=path, caller=caller,
                api_key_hint=api_key_hint,
            )
        else:
            self._handle_non_streaming(
                response, response_headers, status,
                model=model, endpoint=path, caller=caller,
                api_key_hint=api_key_hint,
            )

        conn.close()

    def _handle_non_streaming(self, response, headers, status, *,
                              model, endpoint, caller, api_key_hint=""):
        """Handle a non-streaming Anthropic API response."""
        body = response.read()

        # Send response to client
        self.send_response(status)
        for key, value in headers:
            if key.lower() not in ("transfer-encoding", "connection"):
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

        # Parse and log usage
        self._parse_and_log_usage(body, status, model=model,
                                  endpoint=endpoint, caller=caller,
                                  api_key_hint=api_key_hint)

    def _handle_streaming(self, response, headers, status, *,
                          model, endpoint, caller, api_key_hint=""):
        """Handle a streaming SSE response from Anthropic, forwarding chunks in real time."""
        # Send response headers to client
        self.send_response(status)
        for key, value in headers:
            if key.lower() not in ("transfer-encoding", "connection"):
                self.send_header(key, value)
        # Use chunked encoding for streaming to client
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        # Read and forward SSE stream, collecting usage data
        usage_data = {}
        request_id = ""
        stop_reason = ""
        accumulated = b""

        try:
            while True:
                chunk = response.read(4096)
                if not chunk:
                    break

                # Forward chunk to client (chunked encoding)
                self._write_chunk(chunk)
                accumulated += chunk

            # Send final empty chunk to signal end
            self._write_chunk(b"")

        except (BrokenPipeError, ConnectionResetError):
            logging.warning("Client disconnected during streaming")
        except Exception as e:
            logging.error("Streaming error: %s", e)

        # Parse accumulated SSE data for usage information
        try:
            lines = accumulated.decode("utf-8", errors="replace").split("\n")
            for line in lines:
                if not line.startswith("data: "):
                    continue
                data_str = line[6:].strip()
                if data_str == "[DONE]":
                    continue
                try:
                    event = json.loads(data_str)
                except json.JSONDecodeError:
                    continue

                event_type = event.get("type", "")

                # message_start contains the model and initial usage
                if event_type == "message_start":
                    msg = event.get("message", {})
                    model = msg.get("model", model)
                    request_id = msg.get("id", "")
                    u = msg.get("usage", {})
                    usage_data["input_tokens"] = u.get("input_tokens", 0)
                    usage_data["cache_creation_input_tokens"] = u.get(
                        "cache_creation_input_tokens", 0)
                    usage_data["cache_read_input_tokens"] = u.get(
                        "cache_read_input_tokens", 0)

                # message_delta contains output tokens and stop reason
                elif event_type == "message_delta":
                    u = event.get("usage", {})
                    usage_data["output_tokens"] = u.get("output_tokens", 0)
                    stop_reason = event.get("delta", {}).get(
                        "stop_reason", "")

        except Exception as e:
            logging.error("Failed to parse SSE stream for usage: %s", e)

        # Log usage
        self.db.log_request(
            model=model,
            endpoint=endpoint,
            input_tokens=usage_data.get("input_tokens", 0),
            output_tokens=usage_data.get("output_tokens", 0),
            cache_creation_input_tokens=usage_data.get(
                "cache_creation_input_tokens", 0),
            cache_read_input_tokens=usage_data.get(
                "cache_read_input_tokens", 0),
            status_code=status,
            request_id=request_id,
            stop_reason=stop_reason,
            caller=caller,
            api_key_hint=api_key_hint,
        )

    def _write_chunk(self, data: bytes):
        """Write a chunk in HTTP chunked transfer encoding."""
        self.wfile.write(f"{len(data):x}\r\n".encode())
        self.wfile.write(data)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _parse_and_log_usage(self, body: bytes, status: int, *,
                             model, endpoint, caller, api_key_hint=""):
        """Parse a non-streaming Anthropic response body and log usage."""
        request_id = ""
        stop_reason = ""
        input_tokens = 0
        output_tokens = 0
        cache_creation = 0
        cache_read = 0
        error = ""

        try:
            data = json.loads(body)
            if status == 200:
                request_id = data.get("id", "")
                stop_reason = data.get("stop_reason", "")
                model = data.get("model", model)
                usage = data.get("usage", {})
                input_tokens = usage.get("input_tokens", 0)
                output_tokens = usage.get("output_tokens", 0)
                cache_creation = usage.get(
                    "cache_creation_input_tokens", 0)
                cache_read = usage.get("cache_read_input_tokens", 0)
            else:
                err_obj = data.get("error", {})
                error = err_obj.get("message", json.dumps(data)[:200])
        except (json.JSONDecodeError, UnicodeDecodeError):
            error = f"Non-JSON response (status {status})"

        self.db.log_request(
            model=model, endpoint=endpoint,
            input_tokens=input_tokens, output_tokens=output_tokens,
            cache_creation_input_tokens=cache_creation,
            cache_read_input_tokens=cache_read,
            status_code=status, request_id=request_id,
            stop_reason=stop_reason, caller=caller, error=error,
            api_key_hint=api_key_hint,
        )

    def _send_error(self, code: int, message: str):
        """Send an error response to the client."""
        body = json.dumps({"error": {"type": "proxy_error",
                                     "message": message}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # Route all HTTP methods through the proxy
    def do_POST(self):
        self._proxy_request()

    def do_GET(self):
        # Health check endpoint
        if self.path == "/_health":
            body = json.dumps({"status": "ok", "proxy": "TokenTracker"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self._proxy_request()

    def do_PUT(self):
        self._proxy_request()

    def do_DELETE(self):
        self._proxy_request()

    def do_PATCH(self):
        self._proxy_request()

    def do_OPTIONS(self):
        self._proxy_request()

# ---------------------------------------------------------------------------
# Threaded Server
# ---------------------------------------------------------------------------

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """HTTPServer that handles each request in a new thread."""
    daemon_threads = True
    allow_reuse_address = True

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="TokenTracker Proxy Server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"Port to listen on (default: {DEFAULT_PORT})")
    parser.add_argument("--db", type=str, default=DEFAULT_DB_PATH,
                        help=f"SQLite database path (default: {DEFAULT_DB_PATH})")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Enable verbose logging")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format=LOG_FORMAT,
    )

    db = UsageDatabase(args.db)

    ProxyHandler.db = db

    # Retry binding up to 3 times
    server = None
    for attempt in range(3):
        try:
            server = ThreadedHTTPServer(("127.0.0.1", args.port), ProxyHandler)
            break
        except OSError as e:
            if attempt < 2:
                logging.warning("Port %d busy, retrying in 2s... (%s)", args.port, e)
                time.sleep(2)
            else:
                logging.error("Cannot bind to port %d: %s", args.port, e)
                sys.exit(1)

    logging.info("TokenTracker proxy listening on http://127.0.0.1:%d", args.port)
    logging.info("Targeting %s", ANTHROPIC_HOST)
    logging.info("Database: %s", args.db)
    logging.info("Set ANTHROPIC_BASE_URL=http://localhost:%d in your shell", args.port)

    def shutdown(sig, frame):
        logging.info("Shutting down proxy...")
        threading.Thread(target=server.shutdown).start()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    server.serve_forever()

if __name__ == "__main__":
    main()
