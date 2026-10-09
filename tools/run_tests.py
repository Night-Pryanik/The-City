#!/usr/bin/env python3
"""Headless test runner for The City.

Every test is an independent SceneTree script run as its own process:

    godot --headless --path . --script res://tests/<name>.gd

This launcher runs them from a single place, in parallel, and applies the same
verdict rules to all of them, so a run cannot be green because a failure was
printed to stderr instead of stdout, or because a test silently produced no
verdict at all.

Why not a test framework (GUT / gdUnit): the 38 existing tests are plain
SceneTree scripts with a hand-rolled contract (a "TEST OK" line and/or an exit
code, plus tests/watchdog.gd for hangs). Wrapping them in a framework would mean
rewriting all of them for no behavioural gain.

Verdict rules, in order:
  1. Engine errors. SCRIPT ERROR / Parse Error / "Failed to load script" on
     stderr is a FAIL regardless of exit code -- the diary records a real case
     of assertions passing while the integration test printed engine errors that
     a stdout-only FAIL filter never saw.
  2. Timeout. The process is killed; this is a FAIL. The per-test limit is
     derived from the watchdog timeout the test arms for itself, plus slack.
  3. exit code != 0 -> FAIL. 0 -> PASS, BUT
  4. ... only if the test also printed a verdict marker ("TEST OK", its own
     success line) or opted out of markers (see `MARKERLESS`). A test that
     exits 0 without saying anything is a FAIL: an empty run is not a pass.
  5. `test_pause_menu_confirm` is special (see NEEDS_SENTINEL): it kills its own
     process to verify the exit confirmation, so its exit code proves nothing --
     a sentinel file written just before the final click is the real verdict.

Usage:
    python tools/run_tests.py                 # fast suite
    python tools/run_tests.py --all           # every test
    python tools/run_tests.py --only road,sea # substring filter on test names
    python tools/run_tests.py --only town_economy --case=readiness
    python tools/run_tests.py --only cancel_actions --repeat=5
    python tools/run_tests.py --list
    python tools/run_tests.py -j 1            # serial (for debugging output)

Output: one line per test, a failure report with the relevant log lines, and a
per-run log under tools/test_logs/.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = PROJECT_ROOT / "tests"
LOG_DIR = PROJECT_ROOT / "tools" / "test_logs"

# The user data directory Godot writes to. APPDATA redirects it on Windows, so
# each parallel worker gets its own sandbox and two tests can never read or
# write the same settings.cfg / savegame.json / sentinel. Two tests really do
# touch it: test_resource_display_interval writes settings.cfg, and
# test_pause_menu_confirm writes a sentinel file.
USER_DATA_RELATIVE = Path("Godot") / "app_userdata" / "The City"

# A test that prints no verdict line and is not in MARKERLESS is treated as
# broken, not as passing. Tests that end with their own wording of success:
MARKERLESS = {
    "test_town_economy",  # prints "все проверки пройдены"
}

# This test verifies the pause menu's exit confirmation, which terminates the
# process itself. A clean exit code therefore proves nothing -- if the final
# step never ran, the process would simply not exist and still return 0. The
# test writes a sentinel file immediately before the final click; the run counts
# only when the sentinel is present. The sentinel must be removed before the
# test starts, or a stale file from an earlier run would fake a pass.
NEEDS_SENTINEL = {
    "test_pause_menu_confirm": "test_pause_menu_confirm.done",
}

# Tests whose engine-error output is expected and must not flip the verdict.
# (Empty today; kept as the single place to record such an exception.)
IGNORE_ENGINE_ERRORS: set[str] = set()

# Godot prints these at normal exit; they are noise, not test failures.
BENIGN_STDERR = re.compile(
    r"ObjectDB instances were leaked at exit"
    r"|resources still in use at exit"
    r"|^\s*at: (cleanup|clear) \(",
    re.MULTILINE,
)

ENGINE_ERROR = re.compile(
    r"SCRIPT ERROR|Parse Error|Failed to load script|Invalid access to property",
    re.MULTILINE,
)

# "X TEST OK", "TEST OK: ...", "VALIDATION TEST OK", "все проверки пройдены"
VERDICT_OK = re.compile(
    r"TEST OK|.\bOK:\s|ПРОВЕРКИ ПРОЙДЕНЫ|все проверки пройдены", re.IGNORECASE
)
# These must never appear on a passing run.
VERDICT_BAD = re.compile(r"TEST FAILED|ASSERT FAILED|WATCHDOG .*HUNG", re.IGNORECASE)

WATCHDOG_ARM = re.compile(r"WATCHDOG\.arm\(\s*self\s*,\s*([0-9.]+)\s*\)")
# Slack on top of the watchdog limit: process start + data load + report print.
TIMEOUT_SLACK_SECONDS = 30.0
DEFAULT_TIMEOUT_SECONDS = 180.0

# Suites. "fast" is the pre-commit set: everything that does not depend on
# whole-map generation or long economic simulation. Tests not listed anywhere
# below are still run by --all and REPORTED as unclassified, so a new test
# cannot be silently left out of the fast suite.
SLOW = {
    "test_road_building",
    "test_road_levels",
    "test_road_capacity",
    "test_town_roads",
    "test_improvement_road",
    "test_town_start_area",
    "test_town_priorities",
    "test_town_reachability",
    "test_town_fill_region",
    "test_town_fill_fog",
    "test_debug_whole_map_fill",
    "test_sea_coast",
    "test_river_rendering",
    "test_breeding_terrains",
    "test_cartography_gate",
    "test_scouting_frontier",
    "test_territory_costs",
    "test_town_food_fields",
    "test_town_economy",
    "test_data_validation",
    "test_quality_price",
}


@dataclass
class TestCase:
    name: str
    script: str  # res:// path
    timeout: float
    sentinel: str | None = None
    passed: bool = False
    reason: str = ""
    duration: float = 0.0
    exit_code: int | None = None
    stdout: str = ""
    stderr: str = ""
    critical: list[str] = field(default_factory=list)


def discover() -> list[TestCase]:
    """Every tests/*.gd except the shared helper (watchdog.gd is not test_*)."""
    cases: list[TestCase] = []
    for path in sorted(TESTS_DIR.glob("test_*.gd")):
        name = path.stem
        text = path.read_text(encoding="utf-8", errors="replace")
        timeout = DEFAULT_TIMEOUT_SECONDS
        match = WATCHDOG_ARM.search(text)
        if match:
            # The test's own hang limit is the authority; overwaiting only
            # wastes time on a genuinely hung test.
            timeout = float(match.group(1)) + TIMEOUT_SLACK_SECONDS
        cases.append(
            TestCase(
                name=name,
                script=f"res://tests/{path.name}",
                timeout=timeout,
                sentinel=NEEDS_SENTINEL.get(name),
            )
        )
    return cases


def find_godot() -> str:
    env = os.environ.get("GODOT")
    if env and Path(env).exists():
        return env
    # Local install first: it is the version the project is developed against.
    for candidate in (
        Path("D:/Program Files/Godot/godot.exe"),
        Path("C:/Program Files/Godot/godot.exe"),
        Path("/d/Program Files/Godot/godot.exe"),
    ):
        if candidate.exists():
            return str(candidate)
    found = shutil.which("godot") or shutil.which("godot4")
    if found:
        return found
    sys.exit(
        "Godot executable not found. Set the GODOT environment variable to the "
        "path of the engine binary."
    )


def run_one(case: TestCase, godot: str, appdata_root: Path, cases: list[str] | None = None,
            attempt: int = 0) -> TestCase:
    # Each attempt works on its own copy: the verdict fields are mutated below,
    # and reusing one object across attempts would leak a reason (or a pass)
    # from the previous attempt into the next.
    case = dataclasses.replace(case)

    # Each attempt gets its own sandbox: a repeat is meant to be an independent
    # run, and sharing user data between attempts would carry state across.
    sandbox = appdata_root / f"{case.name}-{attempt}"
    sandbox.mkdir(parents=True, exist_ok=True)

    sentinel_path = None
    if case.sentinel:
        sentinel_path = sandbox / USER_DATA_RELATIVE / case.sentinel
        # A stale sentinel would fake a pass; the test itself does not clear it.
        if sentinel_path.exists():
            sentinel_path.unlink()

    env = dict(os.environ)
    env["APPDATA"] = str(sandbox)

    cmd = [
        godot,
        "--headless",
        "--path",
        str(PROJECT_ROOT),
        "--script",
        case.script,
    ]

    # `--` is the separator Godot reserves: everything after it reaches the test
    # through OS.get_cmdline_user_args(). Tests read the `--case=` filters there
    # (see tests/watchdog.gd); a test that declares no cases ignores them.
    if cases:
        cmd.append("--")
        cmd.extend(f"--case={name}" for name in cases)

    started = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(PROJECT_ROOT),
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=case.timeout,
        )
        case.stdout, case.stderr = proc.stdout, proc.stderr
        case.exit_code = proc.returncode
    except subprocess.TimeoutExpired as exc:
        case.stdout = exc.stdout or ""
        case.stderr = exc.stderr or ""
        case.duration = time.monotonic() - started
        case.passed = False
        case.reason = f"timeout after {case.timeout:.0f}s (watchdog limit + slack)"
        return case

    case.duration = time.monotonic() - started

    if isinstance(case.stdout, bytes):
        case.stdout = case.stdout.decode("utf-8", "replace")
    if isinstance(case.stderr, bytes):
        case.stderr = case.stderr.decode("utf-8", "replace")

    stderr_clean = BENIGN_STDERR.sub("", case.stderr)

    # 1. Engine errors beat a green exit code.
    if case.name not in IGNORE_ENGINE_ERRORS:
        engine_hits = ENGINE_ERROR.findall(stderr_clean)
        if engine_hits:
            case.critical = _critical_lines(stderr_clean)
            case.passed = False
            case.reason = f"engine error on stderr ({engine_hits[0]})"
            return case

    # 2. Explicit failure markers.
    bad = VERDICT_BAD.search(case.stdout) or VERDICT_BAD.search(stderr_clean)
    if bad:
        case.critical = _critical_lines(case.stdout + "\n" + stderr_clean)
        case.passed = False
        case.reason = f"'{bad.group(0)}' printed"
        return case

    # 3. Exit code.
    if case.exit_code != 0:
        case.critical = _critical_lines(case.stdout + "\n" + stderr_clean)
        case.passed = False
        if case.exit_code == 2:
            case.reason = "exit 2: watchdog fired or the test's own _failed path"
        else:
            case.reason = f"exit code {case.exit_code}"
        return case

    # 4. Sentinel-based verdict (the test verifies its own process death).
    if sentinel_path is not None:
        if sentinel_path.exists():
            case.passed = True
        else:
            case.passed = False
            case.reason = (
                f"no sentinel '{case.sentinel}': the test never reached its final "
                "step (a clean exit code here proves nothing)"
            )
        return case

    # 5. A test must say it passed.
    if VERDICT_OK.search(case.stdout):
        case.passed = True
        return case

    if case.name in MARKERLESS:
        case.passed = True
        return case

    case.passed = False
    case.reason = "exit 0 but no verdict line in stdout (silent run)"
    return case


def _critical_lines(output: str, limit: int = 12) -> list[str]:
    """The lines worth showing for a failure: errors and assertions."""
    picked = [
        line.rstrip()
        for line in output.splitlines()
        if re.search(
            r"SCRIPT ERROR|Parse Error|ASSERT|FAIL|ERROR|WATCHDOG|Invalid|"
            r"at: |^ERROR",
            line,
        )
    ]
    if not picked:
        # No obvious error line: show the tail, which is where a crash lands.
        picked = [line.rstrip() for line in output.splitlines()[-limit:]]
    return picked[-limit:]


def write_log(case: TestCase, path: Path) -> None:
    verdict = "PASS" if case.passed else "FAIL"
    header = [
        f"# {case.name}: {verdict}"
        f" (exit={case.exit_code}, {case.duration:.1f}s)"
        + (f" -- {case.reason}" if case.reason else ""),
        f"# godot --headless --path . --script {case.script}",
        "",
    ]
    path.write_text(
        "\n".join(header) + "--- stdout ---\n" + case.stdout + "\n--- stderr ---\n" + case.stderr,
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--all", action="store_true", help="run every test, including slow ones")
    parser.add_argument("--fast", action="store_true", help="run only the fast suite (default)")
    parser.add_argument(
        "--only",
        default="",
        help="comma-separated substrings; run tests whose name contains any of them",
    )
    parser.add_argument("-j", "--jobs", type=int, default=0, help="parallel workers (default: cpu-2)")
    parser.add_argument("--list", action="store_true", help="list tests and exit")
    parser.add_argument("--verbose", "-v", action="store_true", help="stream each test's log path")
    parser.add_argument(
        "--case",
        action="append",
        default=[],
        metavar="NAME",
        help=(
            "run only the named case(s) inside each test, repeatable. Matched as a "
            "case-insensitive substring against the case names the test declares. "
            "Tests without cases ignore it. Best paired with --only."
        ),
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        metavar="N",
        help="run each test N times to expose flakiness (default 1). "
             "A test that passes some runs and fails others is reported FLAKY.",
    )
    args = parser.parse_args()

    if args.repeat < 1:
        parser.error("--repeat must be at least 1")

    cases = discover()
    if args.list:
        for case in cases:
            suite = "slow" if case.name in SLOW else "fast"
            print(f"{suite:5} {case.name}  (timeout {case.timeout:.0f}s)")
        print(f"\n{len(cases)} tests, {len(SLOW)} slow")
        return 0

    if args.only:
        wanted = [s.strip() for s in args.only.split(",") if s.strip()]
        cases = [c for c in cases if any(w in c.name for w in wanted)]
        if not cases:
            print(f"no test matches {wanted!r}", file=sys.stderr)
            return 2
    elif not args.all and not args.fast:
        cases = [c for c in cases if c.name not in SLOW]

    jobs = args.jobs or max(1, (os.cpu_count() or 4) - 2)
    godot = find_godot()

    stamp = time.strftime("%Y%m%d-%H%M%S")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    appdata_root = Path(tempfile.mkdtemp(prefix="city-tests-"))

    print(f"Godot:  {godot}")
    suite_label = "all" if args.all else "fast/only"
    extra = []
    if args.case:
        extra.append(f"cases={','.join(args.case)}")
    if args.repeat > 1:
        extra.append(f"repeat={args.repeat}")
    suffix = f"   {'   '.join(extra)}" if extra else ""
    print(f"Tests:  {len(cases)}   Workers: {jobs}   Suite: {suite_label}{suffix}")
    print("-" * 72)

    try:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            jobs_list = [
                (case, attempt)
                for case in cases
                for attempt in range(args.repeat)
            ]
            raw = list(
                pool.map(
                    lambda job: run_one(job[0], godot, appdata_root, args.case, job[1]),
                    jobs_list,
                )
            )
    finally:
        shutil.rmtree(appdata_root, ignore_errors=True)

    # Collapse the attempts back into one result per test. A test that fails on
    # every attempt is FAIL; one that passes some and fails others is FLAKY --
    # the whole reason to repeat is to surface exactly that.
    by_name: dict[str, list[TestCase]] = {}
    for case in raw:
        by_name.setdefault(case.name, []).append(case)

    results: list[TestCase] = []
    for name, attempts in by_name.items():
        merged = attempts[0]
        n_pass = sum(1 for a in attempts if a.passed)
        merged.duration = sum(a.duration for a in attempts)
        failed = [a for a in attempts if not a.passed]
        if n_pass == len(attempts):
            merged.passed = True
            merged.reason = ""
            merged.critical = []
        elif n_pass == 0:
            merged.passed = False
            merged.reason = attempts[0].reason or "failed on every attempt"
            merged.critical = attempts[0].critical
        else:
            merged.passed = False
            # Name the failure, not just the count: an intermittent test is only
            # actionable if you can see what it complains about when it breaks.
            merged.reason = (
                f"FLAKY: passed {n_pass}/{len(attempts)} attempts -- "
                f"on failure: {failed[0].reason}"
            )
            # Show a failing attempt's output, not a passing one's.
            merged.stdout, merged.stderr = failed[0].stdout, failed[0].stderr
            merged.exit_code = failed[0].exit_code
            merged.critical = failed[0].critical
        results.append(merged)

    for case in sorted(results, key=lambda c: c.name):
        suite = "slow" if case.name in SLOW else "fast"
        mark = "PASS" if case.passed else "FAIL"
        line = f"{mark}  {case.name:<38} {case.duration:6.1f}s  [{suite}]"
        if not case.passed:
            line += f"  {case.reason}"
        print(line)
        if args.verbose:
            print(f"      log: {LOG_DIR / (case.name + '.log')}")

    # Logs are always written: a passing run is worth keeping when a later
    # change breaks the same test.
    for case in results:
        write_log(case, LOG_DIR / f"{case.name}.log")

    failed = [c for c in results if not c.passed]
    total = sum(c.duration for c in results)

    print("-" * 72)
    if failed:
        print(f"FAILURES ({len(failed)}/{len(results)}):")
        for case in failed:
            print(f"\n### {case.name}: {case.reason}")
            for line in case.critical:
                print(f"    {line}")
    print(
        f"{len(results) - len(failed)}/{len(results)} passed"
        f"   (wall {total:.1f}s of test time, {jobs} workers)"
    )
    print(f"logs: {LOG_DIR}")

    with (LOG_DIR / f"run-{stamp}.txt").open("w", encoding="utf-8") as handle:
        handle.write(
            f"{len(results) - len(failed)}/{len(results)} passed\n"
            + "\n".join(
                f"{'PASS' if c.passed else 'FAIL'} {c.name} {c.duration:.1f}s {c.reason}"
                for c in sorted(results, key=lambda c: c.name)
            )
        )

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
