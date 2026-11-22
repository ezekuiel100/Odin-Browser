"""Fetch a pinned Test262 snapshot without feature exclusions."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "odin-browser-test262"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="main")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--per-dir", type=int, default=5, help="Tests per directory; 0 selects all")
    parser.add_argument("--only", nargs="*", default=["language", "built-ins", "annexB"])
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    if args.per_dir < 0:
        parser.error("--per-dir must be nonnegative")
    out = args.out.resolve()
    if (out / "manifest.json").exists():
        parser.error("Output already has a manifest; choose a new directory to avoid mixing revisions")
    if (out / "test").exists() and any((out / "test").iterdir()):
        parser.error("Output already contains tests; choose a new directory")
    revision = args.revision
    if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision.lower()):
        revision = json.loads(fetch("https://api.github.com/repos/tc39/test262/commits/" + revision))["sha"]
    args.cache.mkdir(parents=True, exist_ok=True)
    archive = args.cache / (revision + ".tar.gz")
    if not archive.exists():
        print("Downloading Test262 " + revision, flush=True)
        archive.write_bytes(fetch("https://codeload.github.com/tc39/test262/tar.gz/" + revision))
    archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    with tarfile.open(archive, "r:gz") as tar:
        members = {}
        for member in tar.getmembers():
            if not member.isfile():
                continue
            relative = PurePosixPath(*PurePosixPath(member.name).parts[1:])
            if ".." in relative.parts or relative.is_absolute() or any(":" in part for part in relative.parts):
                raise ValueError("Unsafe archive path")
            members[str(relative)] = member
        candidates, supporting = [], []
        for name in members:
            if name.startswith("harness/") or name in ("LICENSE", "INTERPRETING.md", "package.json"):
                supporting.append(name)
            elif name.startswith("test/"):
                rel = name[5:]
                if not any(rel == area.rstrip("/") or rel.startswith(area.rstrip("/") + "/") for area in args.only):
                    continue
                if not name.endswith(".js") or "_FIXTURE" in PurePosixPath(name).name:
                    supporting.append(name)
                else:
                    candidates.append(name)
        groups = {}
        for name in candidates:
            groups.setdefault(str(PurePosixPath(name).parent), []).append(name)
        selected = []
        for names in groups.values():
            names.sort(key=lambda name: hashlib.sha256(name.encode()).digest())
            selected.extend(names[:args.per_dir] if args.per_dir else names)
        # Preserve all test files as possible import dependencies, but execute
        # only the manifest selection. This also covers imports of sibling tests.
        for name in sorted(set(supporting + candidates)):
            target = out.joinpath(*PurePosixPath(name).parts)
            if not target.resolve().is_relative_to(out):
                raise ValueError("Archive target escapes output directory")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tar.extractfile(members[name]).read())
        manifest = {
            "schema": 1, "repository": "https://github.com/tc39/test262",
            "revision": revision, "archiveSha256": archive_hash,
            "selection": {"areas": args.only, "perDirectory": args.per_dir,
                          "order": "sha256(path)", "featureExclusions": []},
            "candidateTests": len(candidates), "directories": len(groups),
            "tests": sorted(name[5:] for name in selected),
        }
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"Selected {len(selected)} of {len(candidates)} tests in {len(groups)} directories -> {out}", flush=True)


if __name__ == "__main__":
    main()
