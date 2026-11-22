"""Run isolated Test262 variants and preserve machine-readable measurements."""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import gzip
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

import yaml

ROOT = Path(__file__).resolve().parent.parent
HOST_APIS = re.compile(r"\$262\s*(?:\.\s*(createRealm|agent|gc|IsHTMLDDA|AbstractModuleSource)\b|\[\s*['\"](createRealm|agent|gc|IsHTMLDDA|AbstractModuleSource)['\"]\s*\])")


def load_report(path):
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'rt', encoding='utf-8-sig') as stream:
        return json.load(stream)


def metadata(source):
    match = re.search(r"/\*---(.*?)---\*/", source, re.S)
    if not match:
        raise ValueError("missing Test262 frontmatter")
    value = yaml.load(match[1], Loader=yaml.BaseLoader)
    if not isinstance(value, dict):
        raise ValueError("invalid Test262 frontmatter")
    for name in ("flags", "features", "includes"):
        if name in value and (not isinstance(value[name], list) or not all(isinstance(x, str) for x in value[name])):
            raise ValueError("invalid " + name)
    negative = value.get("negative")
    if negative is not None and (not isinstance(negative, dict) or
            negative.get("phase") not in ("parse", "resolution", "runtime") or not negative.get("type")):
        raise ValueError("invalid negative metadata")
    return value


def variants(flags):
    if "module" in flags:
        return ["module"]
    if "raw" in flags or "noStrict" in flags:
        return ["normal"]
    if "onlyStrict" in flags:
        return ["strict"]
    return ["normal", "strict"]


def verdict(stdout, code, negative, test_index):
    lines = [line for line in stdout.splitlines() if line.startswith("__262__")]
    if code != 0 or len(lines) != 1:
        return "ERROR", f"process exit={code}; verdicts={len(lines)}"
    line = lines[0]
    if line.startswith("__262__ status=invalid "):
        return "FAIL", line
    if line.startswith("__262__ status=incomplete "):
        return "FAIL", "async/module did not complete: " + line
    if negative:
        fields = dict(re.findall(r"(\w+)=(\S+)", line.split(" msg=", 1)[0]))
        passed = (fields.get("status") == "throw" and fields.get("name") == negative["type"] and
                  fields.get("phase") == negative["phase"] and fields.get("source") == str(test_index) and
                  fields.get("rec") == "0" and
                  (negative["phase"] != "parse" or negative["type"] == "SyntaxError"))
        return ("PASS" if passed else "FAIL"), f"expected {negative['phase']}/{negative['type']}; {line}"
    return ("PASS", "") if line == "__262__ status=pass rec=0" else ("FAIL", line)


def execute(task, args):
    path, variant, fm, source = task
    relative = path.relative_to(args.suite / "test").as_posix()
    flags = fm.get("flags", [])
    row = {"name": relative, "variant": variant,
           "mode": "module" if variant == "module" else "script",
           "async": "async" in flags, "features": fm.get("features", []),
           "negative": fm.get("negative"), "area": "/".join(relative.split("/")[:2])}
    start = time.monotonic()

    def result(status, reason):
        row.update(status=status, reason=reason, durationMs=round((time.monotonic()-start)*1000, 2))
        return row

    if any(flag in flags for flag in ("CanBlockIsFalse", "CanBlockIsTrue")):
        return result("SKIP", "host: CanBlock agent mode unavailable")
    harness = []
    if "raw" not in flags:
        for include in ["sta.js", "assert.js"] + fm.get("includes", []):
            include_path = (args.suite / "harness" / include).resolve()
            if not include_path.is_relative_to(args.suite / "harness"):
                return result("ERROR", "invalid harness path: " + include)
            if not include_path.is_file():
                return result("SKIP", "harness missing: " + include)
            harness.append(include_path)
    for text in [source] + [p.read_text(encoding="utf-8-sig") for p in harness]:
        unsupported = HOST_APIS.search(text)
        if unsupported:
            return result("SKIP", "host: $262." + next(g for g in unsupported.groups() if g))
    command = [str(args.browser), "--js262"]
    if variant == "module":
        command.append("--module")
    if "async" in flags:
        command.append("--async")
    temporary = None
    try:
        entry = path
        if variant == "strict":
            # Keep the entry URL/directory for dynamic imports. Each variant has
            # a unique sibling, so concurrent processes cannot overwrite it.
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", suffix=".js", prefix=".test262-strict-", dir=path.parent, delete=False) as f:
                f.write('"use strict";\n' + source)
                temporary = entry = Path(f.name)
        command.extend(str(p) for p in harness + [entry])
        completed = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace",
                                   timeout=args.timeout, cwd=ROOT, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        status, reason = verdict(completed.stdout, completed.returncode, fm.get("negative"), len(harness))
        if status == "ERROR":
            reason += "; stderr=" + completed.stderr[-1500:].replace("\n", " ")
        return result(status, reason)
    except subprocess.TimeoutExpired:
        return result("ERROR", f"timeout {args.timeout}s")
    except OSError as error:
        return result("ERROR", str(error))
    finally:
        if temporary:
            temporary.unlink(missing_ok=True)


def aggregate(rows, key):
    groups = defaultdict(Counter)
    for row in rows:
        values = row[key] if key == "features" else [row[key]]
        for value in values:
            groups[str(value)][row["status"]] += 1
    return {name: dict(counts) for name, counts in sorted(groups.items())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, default=ROOT / "tests/test262")
    parser.add_argument("--browser", type=Path, default=ROOT / "browser.exe")
    parser.add_argument("--filter", default="")
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--report", type=Path, default=ROOT / "_local/reports/test262-latest.json")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--show-throw", action="store_true")
    args = parser.parse_args()
    args.suite = args.suite.resolve()
    args.browser = args.browser.resolve()
    if args.jobs < 1 or args.timeout <= 0 or not args.browser.is_file():
        parser.error("require existing --browser, --jobs >= 1, --timeout > 0")
    started = datetime.now(timezone.utc).isoformat()
    manifest_path = args.suite / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else None
    paths = [args.suite / "test" / p for p in manifest["tests"]] if manifest else sorted((args.suite / "test").rglob("*.js"))
    tasks, rows = [], []
    files = 0
    for path in paths:
        relative = path.relative_to(args.suite / "test").as_posix()
        if "_FIXTURE" in path.name or path.name.startswith(".test262-") or args.filter.lower().replace("\\", "/") not in relative.lower():
            continue
        files += 1
        try:
            source = path.read_bytes().decode("utf-8-sig")
            fm = metadata(source)
            for variant in variants(fm.get("flags", [])):
                tasks.append((path, variant, fm, source))
        except (OSError, ValueError, yaml.YAMLError) as error:
            rows.append({"name": relative, "variant": "metadata", "mode": "unknown", "async": False,
                         "features": [], "area": "/".join(relative.split("/")[:2]),
                         "status": "ERROR", "reason": str(error), "durationMs": 0})
    if not files:
        parser.error("No matching tests: check suite and filter")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    print(f"Test262: {files} files, {len(tasks)} variants, {args.jobs} processes", flush=True)
    print(f"Suite: {args.suite}; revision: {manifest['revision'] if manifest else 'legacy/unpinned'}", flush=True)
    start = time.monotonic()
    with args.report.with_suffix(".jsonl").open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row) + "\n")
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [pool.submit(execute, task, args) for task in tasks]
            for future in as_completed(futures):
                row = future.result()
                rows.append(row)
                stream.write(json.dumps(row) + "\n")
                stream.flush()
                if args.verbose or (args.show_throw and row["status"] != "PASS"):
                    print(f"{row['status']:5} {row['name']} [{row['variant']}] {row['reason']}", flush=True)
                if len(rows) % 500 == 0:
                    print(f"Progress {len(rows)}/{len(tasks)}: {dict(Counter(r['status'] for r in rows))}", flush=True)
    rows.sort(key=lambda r: (r["name"], r["variant"]))
    counts = {s: sum(r["status"] == s for r in rows) for s in ("PASS", "FAIL", "ERROR", "SKIP")}
    report = {"schema": 1, "startedUtc": started, "durationSeconds": round(time.monotonic()-start, 2),
              "browser": str(args.browser), "browserSha256": hashlib.sha256(args.browser.read_bytes()).hexdigest(),
              "suiteRevision": manifest["revision"] if manifest else None,
              "suiteManifestSha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest() if manifest else None,
              "selection": manifest["selection"] if manifest else {"legacy": True},
              "filter": args.filter, "files": files, "variants": len(rows), "counts": counts,
              "timeoutSeconds": args.timeout, "jobs": args.jobs,
              "byArea": aggregate(rows, "area"), "byMode": aggregate(rows, "mode"),
              "byAsync": aggregate(rows, "async"), "byFeature": aggregate(rows, "features"),
              "skipReasons": dict(Counter(r["reason"] for r in rows if r["status"] == "SKIP")), "results": rows}
    if args.baseline:
        old = load_report(args.baseline)
        if old["suiteRevision"] != report["suiteRevision"] or old["filter"] != args.filter:
            parser.error("Baseline revision/filter differs; refusing a misleading comparison")
        before = {(r["name"], r["variant"]): r["status"] for r in old["results"]}
        after = {(r["name"], r["variant"]): r["status"] for r in rows}
        if before.keys() != after.keys():
            parser.error("Baseline selection differs; refusing a misleading comparison")
        report["changes"] = [{"name": k[0], "variant": k[1], "before": before[k], "after": after[k]}
                             for k in sorted(after) if before[k] != after[k]]
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("\nArea                                              PASS  FAIL ERROR  SKIP")
    for area, group in report["byArea"].items():
        print(f"{area:48}" + "".join(f"{group.get(s, 0):6}" for s in counts))
    for name, count in report["skipReasons"].items():
        print(f"SKIP {count}: {name}")
    print("TOTAL: " + " / ".join(f"{count} {status}" for status, count in counts.items()) + f" (de {len(rows)})", flush=True)
    print("Report: " + str(args.report), flush=True)
    return int(counts["FAIL"] > 0 or counts["ERROR"] > 0)


if __name__ == "__main__":
    raise SystemExit(main())
