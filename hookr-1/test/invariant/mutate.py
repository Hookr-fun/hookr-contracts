#!/usr/bin/env python3
"""Mutation gate runner. Applies each mutant of test/invariant/mutants.py to a source file, runs the suites the
catalog names for it, and requires one of them to fail.

  test/invariant/mutate.py                        every mutant, one worker
  test/invariant/mutate.py --only HookrRoot       the mutants of one contract (repeatable)
  test/invariant/mutate.py --id RT-3 --id RT-4    named mutants (or --id RT-3,RT-4)
  test/invariant/mutate.py --jobs 4               four workers, each on its own copy of the tree (see below)
  test/invariant/mutate.py --jobs 4 --isolated    the same, the first worker on a copy as well
  test/invariant/mutate.py --list                 print the catalog and exit
  test/invariant/mutate.py --contracts            print the contracts as a JSON list (CI builds its matrix from it)
  test/invariant/mutate.py --check                apply every mutant to a scratch copy of its file and confirm each
                                                  anchor matches exactly once and each mutation changes the text; no build
  test/invariant/mutate.py --baseline             before mutating, run each distinct suite once unmutated and require it
                                                  to pass and to run at least one test; a failure in setUp counts as a kill only
                                                  after this check (CI always passes it)

Each mutant edits one src file, builds what the selected suites import, and runs them with a fixed fuzz seed
(0x7e57a11, or SEED). The result is one of
  KILLED     a selected suite failed (a failure in setUp counts: see --baseline)
  SURVIVED   every selected suite passed; the gate fails
  INVALID    the mutated tree did not compile, or a suite selected no test; the catalog entry is wrong
The original text is restored after every mutant and on exit. Workers other than the first run on a copy of the
tree in <root>-mutants/w<N> (built output included; a copy-on-write clone where the file system has one), so the
tree being tested is never edited by two runs at once. A run
prints one line per mutant and a summary, writes JSON lines to $MUTATION_LOG (default mutation-results.jsonl in the
scratch directory it names), and exits 0 when every mutant was killed, 1 when one survived, 2 when one was invalid or
the unmutated suites fail.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mutants import MUTANTS  # noqa: E402

SEED = os.environ.get("SEED", "0x7e57a11")
TIMEOUT = int(os.environ.get("MUTANT_TIMEOUT", "3000"))
LOCK = threading.Lock()
SKIP_COPY = {".git", "broadcast"}


def say(line):
    with LOCK:
        print(line, flush=True)


def forge(root, profile, args):
    env = dict(os.environ, FOUNDRY_PROFILE=profile)
    cmd = ["forge", "test", "--fuzz-seed", SEED, *args]
    try:
        run = subprocess.run(cmd, cwd=root, env=env, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
    return run.returncode, run.stdout + "\n" + run.stderr


def verdict(code, out):
    """KILLED, SURVIVED, or INVALID for one forge run of a mutated tree.

    A failure in setUp counts as a kill: the suites passed unmutated (`--baseline`, which CI always passes, checks it), so
    the mutation is what made the fixture fail, as when it breaks a guard the fixture itself exercises."""
    if code == 124:
        return "KILLED", "timeout (a mutant that hangs a suite is caught)"
    if re.search(r"Compiler run failed|^Error \(\d+\)|^error\[", out, re.M) and not re.search(
        r"^\[(PASS|FAIL)", out, re.M
    ):
        return "INVALID", first(out, r"(Compiler run failed.*|Error \(\d+\).*|error\[.*)")
    if "No tests match" in out or "no tests to run" in out.lower():
        return "INVALID", "the suite selects no test"
    fails = [line for line in out.splitlines() if line.startswith("[FAIL")]
    if code != 0 and fails:
        real = [line for line in fails if "] setUp()" not in line]
        return "KILLED", (real or [f.replace("setUp()", "setUp()  (the fixture)") for f in fails])[0][:160]
    if code != 0:
        return "INVALID", "forge failed without a test failure: " + out.strip().splitlines()[-1][:120]
    if not re.search(r"^\[PASS\]", out, re.M):
        return "INVALID", "no test passed"
    return "SURVIVED", first(out, r"(\d+ tests passed.*)")


def first(text, pattern):
    m = re.search(pattern, text)
    return (m.group(1) if m else text.strip().splitlines()[-1] if text.strip() else "")[:160]


def apply(path, anchor, replacement):
    text = open(path).read()
    count = text.count(anchor)
    if count != 1:
        raise ValueError(f"anchor found {count} times in {os.path.relpath(path, ROOT)}: {anchor[:90]!r}")
    if anchor == replacement:
        raise ValueError("replacement equals the anchor")
    return text.replace(anchor, replacement)


def prepare(worker, isolated):
    if worker == 0 and not isolated:
        return ROOT
    base = ROOT.rstrip("/") + "-mutants"
    wdir = os.path.join(base, f"w{worker}")
    if isolated and os.path.isdir(wdir):
        shutil.rmtree(wdir)
    if not os.path.isdir(wdir):
        os.makedirs(base, exist_ok=True)
        say(f"worker {worker}: copying the tree to {wdir}")
        # A copy-on-write clone where the file system has one (APFS, btrfs, XFS), so the copy of a built tree (several GB of
        # artifacts) costs no space and no time until a worker recompiles.
        clone = ["cp", "-cR", ROOT, wdir] if sys.platform == "darwin" else ["cp", "-a", "--reflink=auto", ROOT, wdir]
        if subprocess.run(clone, capture_output=True).returncode != 0:
            shutil.rmtree(wdir, ignore_errors=True)
            shutil.copytree(ROOT, wdir, symlinks=True, ignore=shutil.ignore_patterns(*SKIP_COPY))
    return wdir


def run_mutant(root, m):
    path = os.path.join(root, m["file"])
    original = open(path).read()
    started = time.time()
    results = []
    try:
        mutated = apply(path, m["from"], m["to"])
        with open(path, "w") as f:
            f.write(mutated)
        status, why = "SURVIVED", ""
        for profile, args in m["suites"]:
            code, out = forge(root, profile, args)
            status, why = verdict(code, out)
            results.append({"profile": profile, "args": args, "status": status})
            if status != "SURVIVED":
                break
    except ValueError as e:
        status, why = "INVALID", str(e)
    finally:
        with open(path, "w") as f:
            f.write(original)
    return {
        "id": m["id"],
        "contract": m["contract"],
        "file": m["file"],
        "status": status,
        "why": why,
        "seconds": round(time.time() - started),
        "runs": results,
    }


def baseline(roots, mutants):
    """Runs each distinct suite of `mutants` once, unmutated, spread over the workers' trees; returns how many failed or
    ran no test."""
    seen = {}
    for m in mutants:
        for profile, args in m["suites"]:
            seen[(profile, tuple(args))] = None
    queue = list(seen)
    qlock = threading.Lock()
    bad = [0]

    def worker(root):
        while True:
            with qlock:
                if not queue:
                    return
                profile, args = queue.pop(0)
            code, out = forge(root, profile, list(args))
            ok = code == 0 and re.search(r"^\[PASS\]", out, re.M) and not re.search(r"^\[FAIL", out, re.M)
            say(f"baseline {'ok  ' if ok else 'FAIL'} {profile} {' '.join(args)}")
            if not ok:
                bad[0] += 1

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(roots)) as pool:
        for f in [pool.submit(worker, root) for root in roots]:
            f.result()
    return bad[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--id", action="append", default=[])
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--list", action="store_true")
    ap.add_argument(
        "--contracts", action="store_true", help="print the catalog's contracts as a JSON list (CI's matrix)"
    )
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--baseline", action="store_true")
    ap.add_argument(
        "--isolated",
        action="store_true",
        help="run every worker, the first too, on a fresh copy of the tree, so the tree itself can be edited meanwhile",
    )
    args = ap.parse_args()

    ids = [m["id"] for m in MUTANTS]
    if len(ids) != len(set(ids)):
        sys.exit("duplicate mutant ids in the catalog")
    wanted = [i for value in args.id for i in value.split(",")]
    chosen = [m for m in MUTANTS if (not args.only or m["contract"] in args.only) and (not wanted or m["id"] in wanted)]
    if not chosen:
        sys.exit("no mutant selected")
    if args.contracts:
        print(json.dumps(list(dict.fromkeys(m["contract"] for m in MUTANTS))))
        return 0
    if args.list:
        for m in chosen:
            print(f'{m["id"]:8} {m["contract"]:22} {m["file"]}')
        print(f"{len(chosen)} mutants, {len({m['contract'] for m in chosen})} contracts")
        return 0
    if args.check:
        bad = 0
        for m in chosen:
            try:
                apply(os.path.join(ROOT, m["file"]), m["from"], m["to"])
            except ValueError as e:
                say(f'{m["id"]}: {e}')
                bad += 1
        say(f"{len(chosen)} mutants checked, {bad} bad")
        return 2 if bad else 0
    if not subprocess.run(["git", "diff", "--quiet", "--", "src"], cwd=ROOT).returncode == 0:
        say("src has uncommitted changes; the gate edits src files and restores the committed text")
        return 2

    log = os.environ.get("MUTATION_LOG") or os.path.join(tempfile.mkdtemp(prefix="mutation-"), "results.jsonl")
    say(f"mutation gate: {len(chosen)} mutants, {args.jobs} worker(s), fuzz seed {SEED}, log {log}")
    first_build = subprocess.run(["forge", "build"], cwd=ROOT, capture_output=True, text=True)
    if first_build.returncode != 0:
        say("forge build failed\n" + first_build.stderr[-800:])
        return 2
    roots = [prepare(n, args.isolated) for n in range(args.jobs)]
    if args.baseline and baseline(roots, chosen):
        say("an unmutated suite fails, so no mutant can be judged")
        return 2

    queue = list(chosen)
    qlock = threading.Lock()
    results = []

    def worker(n):
        root = roots[n]
        while True:
            with qlock:
                if not queue:
                    return
                m = queue.pop(0)
            r = run_mutant(root, m)
            with LOCK:
                results.append(r)
                with open(log, "a") as f:
                    f.write(json.dumps(r) + "\n")
            say(f'{r["id"]:8} {r["status"]:8} {r["seconds"]:5}s  {m["contract"]}: {m["title"]}  [{r["why"]}]')

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for f in [pool.submit(worker, n) for n in range(args.jobs)]:
                f.result()
    finally:
        subprocess.run(["git", "checkout", "--", "src"], cwd=ROOT)
    counts = {s: sum(1 for r in results if r["status"] == s) for s in ("KILLED", "SURVIVED", "INVALID")}
    say(
        f"{len(results)} mutants: {counts['KILLED']} killed, {counts['SURVIVED']} survived, {counts['INVALID']} invalid"
    )
    for r in results:
        if r["status"] != "KILLED":
            say(f'  {r["status"]}: {r["id"]} {r["contract"]} {r["why"]}')
    if counts["INVALID"]:
        return 2
    return 1 if counts["SURVIVED"] else 0


sys.exit(main())
