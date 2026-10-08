#!/usr/bin/env python3
"""Stdlib-only mock of the SafeStack ingest API and the GitHub OIDC token
endpoint, for exercising upload.sh locally without network access.

Usage: mock_server.py <port> <auth-log-path>

Behavior is selected by the `repository` query param on POST requests:
  repo-ok               -> 202 received, then completed on the second poll.
  repo-422              -> 422 invalid_report.
  repo-429-then-ok      -> 429 busy twice, then 202 received.
  repo-500-then-ok      -> 500 twice, then 202 received.
  repo-warnings         -> 202 skipped with a semgrep_integration_active warning.
  anything else         -> 202 received, then completed on the second poll.

Every Authorization header received on a POST is appended to the auth log
file, one per line, so tests can assert which credential was actually sent.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE = {"retry_counts": {}, "poll_counts": {}, "auth_log": "/dev/null"}


def upload_payload(upload_id, repository, status, warnings=None, errors=None):
    return {
        "upload": {
            "id": upload_id,
            "status": status,
            "status_url": f"/api/ingest/uploads/{upload_id}",
            "repository": repository,
            "ref": "refs/heads/main",
            "tools": ["semgrep"],
            "mode": "snapshot",
            "counts": {
                "received": 1,
                "accepted": 1,
                "dropped": 0,
                "skipped": 0,
                "truncated_fields": 0,
            },
            "errors": errors or [],
            "warnings": warnings or [],
        }
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/oidc-token":
            self._send_json(200, {"value": "mock-oidc-jwt-token-value"})
            return
        if parsed.path.startswith("/api/ingest/uploads/"):
            upload_id = parsed.path.rsplit("/", 1)[-1]
            count = STATE["poll_counts"].get(upload_id, 0) + 1
            STATE["poll_counts"][upload_id] = count
            status = "processing" if count < 2 else "completed"
            payload = upload_payload(upload_id, "repo-ok", status)
            if status == "completed":
                payload["upload"]["new"] = 1
                payload["upload"]["updated"] = 0
                payload["upload"]["closed"] = 0
                payload["upload"]["reconciled"] = True
                payload["upload"]["reconcile_reason"] = None
                payload["upload"]["completed_at"] = "2026-10-08T00:00:00Z"
            self._send_json(200, payload)
            return
        self._send_json(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        repository = query.get("repository", [""])[0]
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)

        with open(STATE["auth_log"], "a", encoding="utf-8") as fh:
            fh.write(self.headers.get("Authorization", "") + "\n")

        if repository == "repo-422":
            self._send_json(
                422,
                {
                    "error": "invalid_report",
                    "format": "sarif",
                    "detail": "bad json at offset 4",
                },
            )
            return

        if repository == "repo-429-then-ok":
            count = STATE["retry_counts"].get(repository, 0) + 1
            STATE["retry_counts"][repository] = count
            if count <= 2:
                self._send_json(429, {"error": "busy", "retry_after": 1})
                return

        if repository == "repo-500-then-ok":
            count = STATE["retry_counts"].get(repository, 0) + 1
            STATE["retry_counts"][repository] = count
            if count <= 2:
                self._send_json(500, {"error": "internal_error"})
                return

        if repository == "repo-warnings":
            self._send_json(
                202,
                upload_payload(
                    "upload-warn-1",
                    repository,
                    "skipped",
                    warnings=["semgrep_integration_active"],
                ),
            )
            return

        upload_id = f"upload-{repository or 'ok'}"
        self._send_json(202, upload_payload(upload_id, repository, "received"))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    STATE["auth_log"] = sys.argv[2] if len(sys.argv) > 2 else "/dev/null"
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
