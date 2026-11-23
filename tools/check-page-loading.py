"""Exercise concurrent downloads and early painting against a local slow server."""
import argparse
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "_local/reports/page-loading"
HTML = """<!doctype html><html><head>
<link rel="stylesheet" href="a.css"><link rel="stylesheet" href="b.css">
<link rel="stylesheet" href="a.css" media="print"></head><body>
<h1>Early content</h1><p id="message">Before JavaScript</p>
<script>var order='';</script>
<script src="a.js"></script><script src="b.js"></script>
<script src="c.js" defer></script><script src="d.js" defer></script>
<script defer>var end=Date.now()+800;while(Date.now()<end){}
document.getElementById('message').textContent='After JavaScript';
console.log('ORDER='+order);</script></body></html>"""


class Server(ThreadingHTTPServer):
    daemon_threads = True
    active = peak = 0
    counts = Counter()
    lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        with self.server.lock:
            self.server.counts[self.path] += 1
            self.server.active += 1
            self.server.peak = max(self.server.peak, self.server.active)
        try:
            if self.path == "/":
                body, mime = HTML, "text/html"
            elif self.path.endswith(".css"):
                time.sleep(0.2)
                body, mime = "body{background:white;color:#123456}", "text/css"
            elif self.path.endswith(".js"):
                time.sleep(0.2)
                body = "order+='" + self.path[1].upper() + "';"
                mime = "application/javascript"
            else:
                self.send_error(404)
                return
            data = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        finally:
            with self.server.lock:
                self.server.active -= 1


def run(browser, server, name, check_preview):
    with server.lock:
        server.counts = Counter()
        server.peak = 0
    start = time.perf_counter()
    result = subprocess.run(
        [str(Path(browser).resolve()), "--diagnose",
         f"http://127.0.0.1:{server.server_port}/", str(OUT / f"{name}.json")],
        cwd=ROOT, capture_output=True, timeout=30,
    )
    elapsed = (time.perf_counter() - start) * 1000
    log = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    (OUT / f"{name}.log").write_text(log, encoding="utf-8")
    assert result.returncode == 0, log[-3000:]
    assert "ORDER=ABCD" in log, log[-3000:]
    with server.lock:
        counts, peak = dict(server.counts), server.peak
    assert counts.get("/a.css") == 1, counts
    assert all(counts.get(f"/{c}.js") == 1 for c in "abcd"), counts
    report = {"process_ms": round(elapsed), "concurrent_requests": peak, "requests": counts}
    if check_preview:
        first = float(re.search(r"\[diag\] first-content ([\d.]+)ms", log)[1])
        complete = float(re.search(r"\[diag\] load-complete ([\d.]+)ms", log)[1])
        assert peak >= 2, report
        assert first + 700 < complete, (first, complete)
        report.update(first_content_ms=first, load_complete_ms=complete)
    return report


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--browser", default=str(ROOT / "browser.exe"))
    args.add_argument("--baseline")
    options = args.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        report = {}
        if options.baseline:
            report["baseline"] = run(options.baseline, server, "baseline", False)
        report["updated"] = run(options.browser, server, "updated", True)
        (OUT / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(json.dumps(report, indent=2))
        print("PASS: concurrent downloads, ordered scripts, single CSS download, early content")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
