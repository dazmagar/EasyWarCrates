"""Run the addon's specs under a real Lua interpreter.

    .venv/Scripts/python.exe tests/run.py

Only files that make no WoW call at load time can be executed here. That
constraint is the point: it keeps the prediction maths testable instead of only
observable in a live raid. The rest are still parsed, so a syntax error shows
up here rather than as a dead addon in the client.
"""
import pathlib
import re
import subprocess
import sys

import lint
from lupa import LuaRuntime

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Load order mirrors the TOC.
ADDON_FILES = [
    "Core/Init.lua",
    "Data/Zones.lua",
    "Data/DropPoints.lua",
    "Data/Vignettes.lua",
    "Data/Announcers.lua",
    "Core/Zones.lua",
    "Detect/Shard.lua",
    "Detect/Heading.lua",
    "Detect/Predict.lua",
    "Track/Timers.lua",
    "Track/Learn.lua",
    "Track/Route.lua",
    "Track/Remote.lua",
    "Track/Phase.lua",
    "Track/Airtime.lua",
    "UI/Model.lua",
    "UI/Manage.lua",
]

# Create frames and register events at load, so they only run in game.
#
# Note on what the syntax pass can and cannot tell you: lupa runs Lua 5.5, and
# WoW runs a 5.1-based dialect. Anything 5.2+ only -- goto and ::labels:: are
# the ones that come up -- parses cleanly here and may not in the client. This
# check catches typos, not version mismatches, so write to 5.1 and do not lean
# on a green pass as proof a construct is available in game.
GAME_ONLY_FILES = [
    "Detect/Scanner.lua",
    "Core/Main.lua",
    "Core/Comm.lua",
    "Core/Commands.lua",
    "UI/Window.lua",
    "UI/Minimap.lua",
    "UI/DataPanel.lua",
    "UI/Settings.lua",
]

SPECS = sorted(p.name for p in (ROOT / "tests").glob("spec_*.lua"))


def check_syntax() -> int:
    lua = LuaRuntime(unpack_returned_tuples=True)
    loadfile = lua.eval("function(p) local f, err = loadfile(p) return f ~= nil, err end")
    failed = 0
    for rel in ADDON_FILES + GAME_ONLY_FILES:
        okay, err = loadfile(str(ROOT / rel))
        if not okay:
            print(f"SYNTAX {rel}\n       {err}")
            failed += 1
    if not failed:
        print(f"ok   syntax                     {len(ADDON_FILES + GAME_ONLY_FILES)} files parse")
    return failed


def run_specs() -> tuple[int, int]:
    total_pass = total_fail = 0
    for spec in SPECS:
        lua = LuaRuntime(unpack_returned_tuples=True)
        loadfile = lua.eval("function(p) return assert(loadfile(p)) end")

        ns = lua.eval("{}")
        ns["__root"] = ROOT.as_posix()
        for rel in ADDON_FILES:
            loadfile(str(ROOT / rel))("EasyWarCrates", ns)

        T = loadfile(str(ROOT / "tests" / "framework.lua"))()
        loadfile(str(ROOT / "tests" / spec))(ns, T)
        passed, failed = T.run()

        print(f"{'ok  ' if failed == 0 else 'FAIL'} {spec:<26} {passed} passed, {failed} failed")
        for i in range(1, failed + 1):
            f = T.failures[i]
            print(f"       - {f['name']}")
            print(f"         {f['msg']}")

        total_pass += passed
        total_fail += failed
    return total_pass, total_fail


# An upload token in a public repository is the one mistake here that cannot be
# taken back by a commit: it has to be revoked and reissued. .gitignore is not
# enough on its own -- `git add -f` ignores it, and `git add -A` has swept files
# in twice on this project already -- so the suite refuses one outright.
#
# Shapes rather than entropy: a CurseForge or Wago upload token is a UUID and
# reads as ordinary text, so what gives it away is the name it is assigned to.
SECRET_SHAPES = [
    (re.compile(r"(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{16,}"), "a GitHub token"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "a GitHub fine-grained token"),
    (re.compile(
        r"(CF_API_KEY|CF_API_TOKEN|WAGO_API_TOKEN|WOWI_API_TOKEN|GITHUB_OAUTH)"
        r"[ \t]*[:=][ \t]*[\"']?"
        r"([0-9a-fA-F-]{8,}|[A-Za-z0-9._-]{12,})"),
     "an upload token assigned in the clear"),
]


def tracked_files() -> list[pathlib.Path]:
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        return []
    return [ROOT / line for line in out.stdout.splitlines() if line]


def check_secrets() -> int:
    found = 0
    for path in tracked_files():
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue          # a screenshot is not going to hold a token
        for pattern, what in SECRET_SHAPES:
            for m in pattern.finditer(text):
                # The workflow names these and reads them from secrets, which is
                # the whole point of it -- that is not a leak.
                if "${{" in m.group(0) or "secrets." in text[max(0, m.start() - 40):m.end() + 40]:
                    continue
                line = text.count("\n", 0, m.start()) + 1
                rel = path.relative_to(ROOT).as_posix()
                print(f"SECRET  {rel}:{line} looks like {what} -- revoke it and reissue")
                found += 1
    if not found:
        print(f"ok   secrets                    {len(tracked_files())} tracked files, nothing token-shaped")
    return found


def main() -> int:
    # Windows hands stdout a cp1252 encoder, which raises on the first
    # non-ASCII character. A spec that fails on a Cyrillic announcer phrase
    # would take the whole run down with a traceback instead of naming the test
    # that failed -- a suite that cannot report a failure is worse than one
    # that has none.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")

    syntax_bad = check_syntax()
    lint_bad = lint.main(ROOT, ADDON_FILES + GAME_ONLY_FILES)
    secrets_bad = check_secrets()
    passed, failed = run_specs()
    print("-" * 58)
    print(f"{passed} passed, {failed} failed, "
          f"{syntax_bad} syntax errors, {lint_bad} lint problems"
          + (f", {secrets_bad} leaked secrets" if secrets_bad else ""))
    return 1 if (failed or syntax_bad or lint_bad or secrets_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
