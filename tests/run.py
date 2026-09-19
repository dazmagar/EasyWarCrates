"""Run the addon's specs under a real Lua interpreter.

    .venv/Scripts/python.exe tests/run.py

Only files that make no WoW call at load time can be executed here. That
constraint is the point: it keeps the prediction maths testable instead of only
observable in a live raid. The rest are still parsed, so a syntax error shows
up here rather than as a dead addon in the client.
"""
import pathlib
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
    "Core/Zones.lua",
    "Detect/Shard.lua",
    "Detect/Heading.lua",
    "Detect/Predict.lua",
    "Track/Timers.lua",
    "Track/Learn.lua",
    "Track/Route.lua",
    "Track/Airtime.lua",
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
    "Core/Commands.lua",
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


def main() -> int:
    syntax_bad = check_syntax()
    lint_bad = lint.main(ROOT, ADDON_FILES + GAME_ONLY_FILES)
    passed, failed = run_specs()
    print("-" * 58)
    print(f"{passed} passed, {failed} failed, "
          f"{syntax_bad} syntax errors, {lint_bad} lint problems")
    return 1 if (failed or syntax_bad or lint_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
