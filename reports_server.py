#!/usr/bin/env python3
################################################################################
### c3g_cbioportal_instance - report gatekeeper (PCGR reports, README "PCGR reports")
### Serves /data/reports/<study_id>/<file>.html at /reports/<study_id>/<file>.html,
### shown by cBioPortal as a "resource" tab in the patient view (iframe).
###
### Access: the SAME as the portal. Every request is checked by asking the running cBioPortal
###         GET /api/studies/<study_id> with the viewer's own session cookie:
###           200        -> file served (the viewer may see this study)
###           401 / 3xx  -> 401 (not logged in)
###           any other  -> 404 (no access, unknown study, portal down: fail closed, nothing leaked)
###         --auth false (= CBIO_AUTH=false, local testing only) skips the check.
###
### Started and stopped by /app/entrypoint.sh (service 6/6). Python standard library only.
################################################################################
import argparse
import html
import http.client
import os
import re
import shutil
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit

## Same rules as entrypoint.sh stage_reports: no '/', no leading '.', no '..'
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*\.html$")
ORIGIN_RE = re.compile(r"^https?://[A-Za-z0-9.-]+(:[0-9]+)?$")
CHUNK = 1024 * 1024

ARGS = None
LOG_LOCK = threading.Lock()


def log_line(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n"
    with LOG_LOCK:
        try:
            with open(ARGS.log, "a") as fh:
                fh.write(line)
        except OSError:
            sys.stderr.write(line)


def portal_allows(study_id, cookie):
    """Ask cBioPortal whether the owner of `cookie` may read `study_id`. Returns 200 / 401 / 404."""
    if ARGS.auth == "false":
        return 200
    if not cookie:
        return 401
    conn = http.client.HTTPConnection("127.0.0.1", ARGS.portal_port, timeout=10)
    try:
        conn.request("GET", f"/api/studies/{quote(study_id, safe='')}",
                     headers={"Cookie": cookie, "Accept": "application/json"})
        status = conn.getresponse().status        # http.client never follows redirects
    except (OSError, http.client.HTTPException) as e:
        log_line(f"portal check failed for {study_id}: {e.__class__.__name__}")
        return 404
    finally:
        conn.close()
    if status == 200:
        return 200
    if status == 401 or 300 <= status < 400:      # no / expired session -> login redirect
        return 401
    return 404


class Handler(BaseHTTPRequestHandler):
    server_version = "c3g-reports"
    sys_version = ""
    timeout = 60                                  # drop idle / slow clients

    def log_message(self, fmt, *args):            # requests are logged by _log() instead
        pass

    def _log(self, status, what):
        client = self.headers.get("X-Forwarded-For", self.client_address[0]) if self.headers else self.client_address[0]
        log_line(f"{client} {self.command} {what} {status}")

    def _error(self, status, text):
        body = (f"<!doctype html><meta charset='utf-8'><title>{status}</title>"
                f"<p style='font-family:sans-serif'>{html.escape(text)}</p>").encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve(self):
        path = urlsplit(self.path).path
        if path == "/reports/health":
            self._error(200, "ok")
            return
        parts = path.split("/")                   # ['', 'reports', '<study_id>', '<file>']
        if len(parts) != 4 or parts[0] != "" or parts[1] != "reports":
            self._log(404, path[:200]); self._error(404, "Not found."); return
        study_id, name = unquote(parts[2]), unquote(parts[3])
        if not NAME_RE.match(study_id) or not FILE_RE.match(name):
            self._log(404, path[:200]); self._error(404, "Not found."); return
        what = f"{study_id}/{name}"

        ## Access first, then the file (so the answer never tells who has which report)
        allowed = portal_allows(study_id, self.headers.get("Cookie", ""))
        if allowed == 401:
            self._log(401, what)
            self._error(401, "Log in to the C3G cBioPortal first, then reload this tab.")
            return
        if allowed != 200:
            self._log(404, what); self._error(404, "Not found."); return

        base = os.path.realpath(os.path.join(ARGS.reports_dir, study_id))
        target = os.path.realpath(os.path.join(base, name))
        if os.path.dirname(target) != base or not os.path.isfile(target):
            self._log(404, what); self._error(404, "Not found."); return

        try:
            fh = open(target, "rb")
        except OSError:
            self._log(404, what); self._error(404, "Not found."); return
        with fh:
            size = os.fstat(fh.fileno()).st_size
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "private, no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            ## sandbox: the report's own JS runs, but in an isolated origin (no portal cookies / parent page)
            self.send_header("Content-Security-Policy",
                             "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox allow-downloads; "
                             f"frame-ancestors {ARGS.frame_origin}")
            self.end_headers()
            if self.command != "HEAD":
                try:
                    shutil.copyfileobj(fh, self.wfile, CHUNK)
                except (BrokenPipeError, ConnectionResetError):
                    pass
        self._log(200, what)

    def do_GET(self):
        self._serve()

    def do_HEAD(self):
        self._serve()


def main():
    global ARGS
    p = argparse.ArgumentParser(description="C3G cBioPortal report gatekeeper")
    p.add_argument("--port", type=int, required=True, help="listen port (CBIO_REPORTS_PORT)")
    p.add_argument("--portal-port", type=int, required=True, help="cBioPortal webapp port on 127.0.0.1 (CBIO_PORT)")
    p.add_argument("--reports-dir", required=True, help="folder holding <study_id>/<file>.html")
    p.add_argument("--auth", required=True, choices=["oauth2", "false"], help="CBIO_AUTH")
    p.add_argument("--frame-origin", required=True, help="portal origin allowed to embed the reports (CBIO_PORTAL_ORIGIN)")
    p.add_argument("--log", required=True, help="access log file")
    ARGS = p.parse_args()
    if not ORIGIN_RE.match(ARGS.frame_origin):
        sys.exit(f"ERROR: --frame-origin {ARGS.frame_origin!r} is not like https://host[:port]")
    os.makedirs(ARGS.reports_dir, exist_ok=True)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    httpd = ThreadingHTTPServer(("0.0.0.0", ARGS.port), Handler)
    httpd.daemon_threads = True
    print(f"report server on :{ARGS.port}, reports in {ARGS.reports_dir}, access check: "
          f"{'NONE (CBIO_AUTH=false)' if ARGS.auth == 'false' else f'cBioPortal 127.0.0.1:{ARGS.portal_port}'}",
          flush=True)
    try:
        httpd.serve_forever()
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()


### How to run: ###
# Started by /app/entrypoint.sh start (service 6/6) - not run by hand. Equivalent:
# python3 -I /app/reports_server.py --port 8090 --portal-port 8080 --reports-dir /data/reports \
#   --auth oauth2 --frame-origin https://cbioportal.c3g-app.sd4h.ca --log /data/logs/reports.log
# curl -sI http://127.0.0.1:8090/reports/health
