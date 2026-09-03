#!/usr/bin/env python3
"""
Scriptable /health responder + ping receiver for the license_tier matrix.

One process serves both halves of the heartbeat's world so a single run of the
real `scripts/telemetry-ping.sh` can be observed end to end:

  GET  /health    -> whatever the current scenario file says to answer with
  POST /v1/ping   -> appended verbatim to <work>/_pings.jsonl

The scenario is read from <work>/_scenario.json on EVERY /health request, so
the harness rewrites that one file between cases instead of restarting a
server per case. Its shape:

    {"status": 200, "body": "<raw bytes to write>", "delay": 0.0,
     "content_type": "application/json"}

`body` is written as raw bytes with no re-encoding, which is what lets the
matrix cover malformed JSON, a JSON array, a bare string, and an empty body —
cases a dict-shaped fixture could not express.

Run:
    python3 health_server.py <port> <work_dir>

Readiness is signalled by creating <work>/_server_ready.
"""

import sys

print(f"server starting (python {sys.version_info.major}.{sys.version_info.minor})", flush=True)

import http.server
import json
import os
import socketserver
import threading
import time

print("server modules imported", flush=True)

DEFAULT_SCENARIO = {
    "status": 200,
    # When set, /health answers a 3xx carrying this Location instead of a body.
    # The target is served by this same server at /elsewhere and records that it
    # was reached, so a test can assert the probe did NOT follow.
    "location": "",
    # The status and Location for POST /v1/ping. A 3xx here is the case that
    # matters: curl does not follow it, so the receiver never sees the payload,
    # and anything that treats the response as success advances the 7-day stamp
    # on a ping that was never delivered.
    "ping_status": 200,
    "ping_location": "",
    "body": '{"status":"healthy","version":"10.3.0-harness","tier":"Enterprise"}',
    "delay": 0.0,
    "content_type": "application/json",
}


def make_handler(work_dir):
    scenario_path = os.path.join(work_dir, "_scenario.json")
    pings_path = os.path.join(work_dir, "_pings.jsonl")
    health_hits_path = os.path.join(work_dir, "_health_hits")
    # Every request that reaches a REDIRECT TARGET, by name. A test asserting
    # "the probe did not follow" reads this: an empty file is the proof, and it
    # is a different observation from "no value was relayed", which a plain
    # network failure would also produce.
    redirect_target_path = os.path.join(work_dir, "_redirect_target_hits")

    def load_scenario():
        try:
            with open(scenario_path) as fh:
                loaded = json.load(fh)
        except (OSError, json.JSONDecodeError):
            return dict(DEFAULT_SCENARIO)
        scenario = dict(DEFAULT_SCENARIO)
        scenario.update(loaded)
        return scenario

    class Handler(http.server.BaseHTTPRequestHandler):
        # Keep harness output readable; assertions read the files, not stderr.
        def log_message(self, *_args, **_kwargs):
            return

        def _record_redirect_target(self, what):
            try:
                with open(redirect_target_path, "a") as fh:
                    fh.write(what + "\n")
            except OSError:
                pass

        def do_GET(self):
            # The target a redirected /health would land on, if anything ever
            # followed one. It answers with values a relay would happily
            # forward, so a test that finds them on the wire has caught the
            # probe reading from a host the caller never configured.
            if self.path == "/elsewhere":
                self._record_redirect_target("GET /elsewhere")
                body = b'{"status":"healthy","version":"9.9.9",'
                body += b'"tier":"LeakedFromElsewhere","edition":"leaked",'
                body += b'"deployment_mode":"leaked"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            # Where a redirected POST would land. A client that followed one
            # would arrive here as a bodyless GET and be answered 200 - which is
            # exactly how a redirect turns into a false delivery.
            if self.path == "/sink":
                self._record_redirect_target("GET /sink")
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            if self.path != "/health":
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            scenario = load_scenario()

            # Count every /health hit. The "exactly one probe per ping" check
            # is what proves license_tier did not smuggle in a second request.
            try:
                with open(health_hits_path, "r+") as fh:
                    n = int(fh.read().strip() or "0") + 1
                    fh.seek(0)
                    fh.write(str(n))
                    fh.truncate()
            except OSError:
                pass

            delay = float(scenario.get("delay") or 0.0)
            if delay > 0:
                time.sleep(delay)

            location = str(scenario.get("location") or "")
            if location:
                # A redirect may carry a BODY, and that is the case that
                # matters: a probe gated only on "not an error" would parse it
                # and relay values from a response the platform never meant as
                # an answer. Sending Content-Length 0 here would make the
                # matrix structurally unable to see that.
                payload = str(scenario.get("body") or "").encode("utf-8")
                self.send_response(int(scenario.get("status") or 302))
                self.send_header("Location", location)
                self.send_header("Content-Type", scenario.get("content_type") or "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except BrokenPipeError:
                    pass
                return

            payload = str(scenario.get("body") or "").encode("utf-8")
            self.send_response(int(scenario.get("status") or 200))
            self.send_header("Content-Type", scenario.get("content_type") or "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except BrokenPipeError:
                # curl --max-time already walked away. That IS the slow case.
                pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b""

            if self.path == "/sink":
                # A followed redirect arrives here. Recorded so a test can
                # distinguish "nothing was delivered" from "delivered somewhere
                # else"; the body length is recorded because a redirected POST
                # arrives with none.
                self._record_redirect_target("POST /sink len=%d" % len(raw))
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            if self.path == "/v1/ping":
                scenario = load_scenario()
                ping_status = int(scenario.get("ping_status") or 200)
                ping_location = str(scenario.get("ping_location") or "")
                if not ping_location and ping_status // 100 != 2:
                    # A non-2xx checkpoint response with no redirect: the ping
                    # was rejected outright. Recorded nowhere, and the stamp
                    # must not advance.
                    self.send_response(ping_status)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if ping_location:
                    # Deliberately BEFORE recording the ping: a redirected POST
                    # is not a delivery, and the file must stay empty so the
                    # matrix's "no heartbeat delivered" and "stamp did not
                    # advance" assertions mean what they say.
                    self.send_response(int(scenario.get("ping_status") or 302))
                    self.send_header("Location", ping_location)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return

                # Store the body verbatim. Re-encoding through json would hide
                # exactly the thing under test: whether the key is ABSENT or
                # merely null/empty.
                with open(pings_path, "ab") as fh:
                    fh.write(raw.replace(b"\n", b" ") + b"\n")
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    return Handler


def main():
    if len(sys.argv) != 3:
        print("usage: health_server.py <port> <work_dir>", file=sys.stderr)
        sys.exit(2)
    port = int(sys.argv[1])
    work_dir = sys.argv[2]
    os.makedirs(work_dir, exist_ok=True)

    for name, initial in (("_health_hits", "0"), ("_redirect_target_hits", "")):
        path = os.path.join(work_dir, name)
        if not os.path.exists(path):
            with open(path, "w") as fh:
                fh.write(initial)

    handler = make_handler(work_dir)

    # Threading matters: the slow-/health case holds one connection open past
    # curl's timeout, and a single-threaded server would wedge every later
    # request behind it.
    class FastThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

        def server_bind(self):
            # Skip socket.getfqdn() — it blocks 30s+ on some macOS runners
            # resolving 127.0.0.1 against an mDNS responder that never answers.
            socketserver.TCPServer.server_bind(self)
            host, self.server_port = self.server_address[:2]
            self.server_name = host

    server = FastThreadingHTTPServer(("127.0.0.1", port), handler)
    server.allow_reuse_address = True

    threading.Thread(target=server.serve_forever, daemon=True).start()

    ready_file = os.path.join(work_dir, "_server_ready")
    with open(ready_file, "w") as fh:
        fh.write("ready\n")
        fh.flush()
        try:
            os.fsync(fh.fileno())
        except OSError:
            pass
    try:
        sys.stdout.write("server ready\n")
        sys.stdout.flush()
    except Exception:
        pass

    while True:
        try:
            time.sleep(3600)
        except KeyboardInterrupt:
            break
    server.shutdown()


if __name__ == "__main__":
    main()
