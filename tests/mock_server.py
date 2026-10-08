#!/usr/bin/env python3
"""Stdlib-only mock of the SafeStack ingest API and the GitHub OIDC token
endpoint, for exercising upload.sh locally without network access.

Usage: mock_server.py <port> <auth-log-path>

Behavior is selected by the `repository` query param on POST requests, or by
the repository encoded in the upload id on GET status polls (the id is
always `upload-<repository>`):
  repo-ok                    -> 202 received, then completed on 2nd poll.
  repo-422                   -> 422 invalid_report.
  repo-422-injection         -> 422 with a detail field containing CR/LF and
                                 `::` workflow-command-like text, to check
                                 the action escapes it rather than passing
                                 it through raw.
  repo-429-then-ok           -> 429 busy twice, then 202 received.
  repo-429-huge-retry-after  -> 429 forever, with a retry_after far above
                                 any sane ceiling, to check the action
                                 clamps it before sleeping.
  repo-429-negative-retry-after -> 429 once with a negative retry_after,
                                 then 202 received, to check the action
                                 falls back to its own backoff instead of
                                 passing the negative value to sleep.
  repo-500-then-ok           -> 500 twice, then 202 received.
  repo-warnings              -> 202 skipped with a warning, at create time.
  repo-skip-with-drop        -> 202 skipped with status_reason
                                 ref_not_tracked AND an unrelated per-finding
                                 drop in errors[], to check the action reads
                                 status_reason rather than errors[0].reason.
  repo-failed                -> 202 received, then status_reason
                                 payload_corrupt on the first poll.
  repo-needs-confirmation    -> 202 received, completed with reconciled
                                 false / reconcile_reason needs_confirmation
                                 on the 2nd poll.
  repo-poll-403              -> 202 received, then every poll returns 403.
  repo-poll-404              -> 202 received, then every poll returns 404.
  repo-poll-500-then-ok      -> 202 received, polls 500 twice, then
                                 completes normally.
  repo-warn-on-complete      -> 202 received with no warnings, completed
                                 with a warning on the 2nd poll.
  anything else              -> 202 received, then completed on 2nd poll.

Every Authorization header received on a POST is appended to the auth log
file, one per line, so tests can assert which credential was actually sent.
Every GET to /oidc-token appends the request path (including its query
string) to `<auth-log-path>.oidc`, so tests can assert the audience param
was encoded correctly.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE = {"retry_counts": {}, "poll_counts": {}, "auth_log": "/dev/null"}

COMPLETED_FIELDS = {
    "new": 1,
    "updated": 0,
    "closed": 0,
    "reconciled": True,
    "reconcile_reason": None,
    "completed_at": "2026-10-08T00:00:00Z",
}


def upload_payload(upload_id, repository, status, status_reason=None, warnings=None, errors=None, extra=None):
    upload = {
        "id": upload_id,
        "status": status,
        "status_reason": status_reason,
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
    if extra:
        upload.update(extra)
    return {"upload": upload}


def poll_response(upload_id, repository, count):
    """Returns (http_status, payload) for a GET status poll."""
    if repository == "repo-failed":
        return 200, upload_payload(upload_id, repository, "failed", status_reason="payload_corrupt")

    if repository == "repo-needs-confirmation":
        if count < 2:
            return 200, upload_payload(upload_id, repository, "processing")
        extra = dict(COMPLETED_FIELDS, closed=12, reconciled=False, reconcile_reason="needs_confirmation")
        return 200, upload_payload(upload_id, repository, "completed", extra=extra)

    if repository == "repo-poll-403":
        return 403, {"error": "forbidden"}

    if repository == "repo-poll-404":
        return 404, {"error": "upload_not_found"}

    if repository == "repo-poll-500-then-ok":
        if count <= 2:
            return 500, {"error": "internal_error"}
        if count == 3:
            return 200, upload_payload(upload_id, repository, "processing")
        return 200, upload_payload(upload_id, repository, "completed", extra=COMPLETED_FIELDS)

    if repository == "repo-warn-on-complete":
        if count < 2:
            return 200, upload_payload(upload_id, repository, "processing")
        return 200, upload_payload(
            upload_id, repository, "completed", warnings=["warning_on_complete"], extra=COMPLETED_FIELDS
        )

    if count < 2:
        return 200, upload_payload(upload_id, repository, "processing")
    return 200, upload_payload(upload_id, repository, "completed", extra=COMPLETED_FIELDS)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send_json(self, status, payload):
        self._send_raw(status, json.dumps(payload).encode(), content_type="application/json")

    def _send_raw(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/oidc-token":
            with open(STATE["auth_log"] + ".oidc", "a", encoding="utf-8") as fh:
                fh.write(self.path + "\n")
            self._send_json(200, {"value": "mock-oidc-jwt-token-value"})
            return
        if parsed.path.startswith("/api/ingest/uploads/"):
            upload_id = parsed.path.rsplit("/", 1)[-1]
            prefix = "upload-"
            repository = upload_id[len(prefix):] if upload_id.startswith(prefix) else upload_id
            count = STATE["poll_counts"].get(upload_id, 0) + 1
            STATE["poll_counts"][upload_id] = count
            status_code, payload = poll_response(upload_id, repository, count)
            self._send_json(status_code, payload)
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

        if repository == "repo-422-injection":
            # Deliberately not JSON: the action echoes the raw response body
            # verbatim on a non-2xx status, so this simulates a misbehaving
            # endpoint or intermediary proxy putting real CR/LF/'%' bytes
            # (not JSON-escaped \n/\r) straight into that body.
            self._send_raw(
                422, b'{"error": "invalid_report"}\n::error::injected from server\r::warning::also injected 50% done'
            )
            return

        if repository == "repo-429-then-ok":
            count = STATE["retry_counts"].get(repository, 0) + 1
            STATE["retry_counts"][repository] = count
            if count <= 2:
                self._send_json(429, {"error": "busy", "retry_after": 1})
                return

        if repository == "repo-429-huge-retry-after":
            self._send_json(429, {"error": "busy", "retry_after": 999999})
            return

        if repository == "repo-429-negative-retry-after":
            count = STATE["retry_counts"].get(repository, 0) + 1
            STATE["retry_counts"][repository] = count
            if count <= 1:
                self._send_json(429, {"error": "busy", "retry_after": -5})
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
                    status_reason="ref_not_tracked",
                    warnings=["semgrep_integration_active"],
                ),
            )
            return

        if repository == "repo-skip-with-drop":
            self._send_json(
                202,
                upload_payload(
                    f"upload-{repository}",
                    repository,
                    "skipped",
                    status_reason="ref_not_tracked",
                    errors=[{"index": 0, "reason": "unrelated_drop_reason"}],
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
