#!/usr/bin/env python3
"""Keep macos/Onit.xctestplan in step with macos/skipped-tests.txt.

A test plan is JSON, so it can't say why a test is skipped. The reasons live in
skipped-tests.txt, one `Identifier  # reason` per line, and this script checks
that the plan skips exactly those tests and that each still exists.

    scripts/check-ci-testplan.py                     # check (CI runs this)
    scripts/check-ci-testplan.py --write             # rewrite the plan's skippedTests from the list
    scripts/check-ci-testplan.py --skip-testing-args # print -skip-testing flags (see below)

xcodebuild (Xcode 26.0.1) honours a test plan's skippedTests only for XCTest:
it ignores every Swift Testing entry, whole `@Suite` types included, not just
single functions (`xcodebuild -enumerate-tests` lists them as enabled). The
plan's list is therefore not enough on its own, and scripts/ci-test.sh passes
every entry as a `-skip-testing:` flag too, which --skip-testing-args prints,
one per line. Running the plan from Xcode itself still runs those tests.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLAN = ROOT / "macos" / "Onit.xctestplan"
SKIP_LIST = ROOT / "macos" / "skipped-tests.txt"
TESTS_DIR = ROOT / "macos" / "OnitTests"


def read_skip_list():
    ids = []
    for number, line in enumerate(SKIP_LIST.read_text().splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        identifier, sep, reason = stripped.partition("#")
        identifier = identifier.strip()
        if not sep or not reason.strip():
            sys.exit(f"{SKIP_LIST.name}:{number}: '{identifier}' needs a '# reason'")
        ids.append(identifier)
    if len(ids) != len(set(ids)):
        sys.exit(f"{SKIP_LIST.name}: duplicate entries")
    return ids


def declared_names():
    """Suite types (and free functions, as `name()`), and every function name."""
    suites, functions = set(), set()
    for path in TESTS_DIR.rglob("*.swift"):
        text = path.read_text()
        suites.update(re.findall(r"\b(?:class|struct|actor|enum)\s+([A-Za-z0-9_]+)", text))
        # Swift Testing allows free test functions, listed as `name()`.
        suites.update(f"{name}()" for name in re.findall(r"^func\s+([A-Za-z0-9_]+)\s*\(", text, re.M))
        functions.update(re.findall(r"\bfunc\s+([A-Za-z0-9_]+)\s*\(", text))
    return suites, functions


def unknown(identifier, suites, functions):
    """Whether `identifier` names no test in OnitTests (a typo, or a renamed test)."""
    suite, _, method = identifier.partition("/")
    if suite not in suites:
        return True
    # `Suite/test()` (Swift Testing) or `Suite/testMethod` (XCTest)
    return bool(method) and method.removesuffix("()") not in functions


def main():
    write = "--write" in sys.argv[1:]
    skipped = read_skip_list()

    if "--skip-testing-args" in sys.argv[1:]:
        for identifier in skipped:
            print(f"-skip-testing:OnitTests/{identifier}")
        return

    suites, functions = declared_names()
    missing = [i for i in skipped if unknown(i, suites, functions)]
    if missing:
        sys.exit(f"{SKIP_LIST.name}: no such test: {', '.join(missing)}")

    plan = json.loads(PLAN.read_text())
    (target,) = plan["testTargets"]
    if write:
        target["skippedTests"] = sorted(skipped)
        PLAN.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
        print(f"Wrote {len(skipped)} skipped tests to {PLAN.relative_to(ROOT)}")
        return

    in_plan = set(target.get("skippedTests", []))
    if in_plan != set(skipped):
        only_plan = sorted(in_plan - set(skipped))
        only_list = sorted(set(skipped) - in_plan)
        print(f"{PLAN.name} and {SKIP_LIST.name} disagree:", file=sys.stderr)
        for i in only_plan:
            print(f"  skipped in the plan, not listed: {i}", file=sys.stderr)
        for i in only_list:
            print(f"  listed, not skipped in the plan: {i}", file=sys.stderr)
        sys.exit("Run scripts/check-ci-testplan.py --write after editing the list.")
    print(f"{PLAN.name}: {len(skipped)} skipped tests, all listed with a reason.")


if __name__ == "__main__":
    main()
