"""Catch a local used before it is declared.

In Lua, a reference to a name that has no local in scope YET compiles to a
global lookup. So calling a `local function` that is declared further down the
file is not a syntax error and not a load error -- it is a nil call the moment
that line runs, which for an addon means in game, in combat, once.

Shipped exactly that bug: Scanner.Poll called dropStaleTracks, declared 80
lines below it, so every poll tick threw and everything after that call in the
function silently never ran.

A forward declaration (`local f` early, `f = function` later) is correct and is
not flagged, because the `local f` line is what counts.
"""
import pathlib
import re

DECL_FUNC = re.compile(r"^\s*local\s+function\s+([A-Za-z_]\w*)", re.M)
DECL_VAR = re.compile(r"^\s*local\s+([A-Za-z_]\w*)\s*(?:=|$|,)", re.M)
CALL = re.compile(r"(?<![\w.:])([A-Za-z_]\w*)\s*\(")


def line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")

    # Strip comments so a name mentioned in prose is not read as a call.
    stripped = re.sub(r"--\[\[.*?\]\]", "", text, flags=re.S)
    stripped = re.sub(r"--[^\n]*", "", stripped)

    declared: dict[str, int] = {}
    for pattern in (DECL_FUNC, DECL_VAR):
        for m in pattern.finditer(stripped):
            name = m.group(1)
            ln = line_of(stripped, m.start())
            declared[name] = min(declared.get(name, ln), ln)

    problems = []
    for m in CALL.finditer(stripped):
        name = m.group(1)
        if name not in declared:
            continue
        ln = line_of(stripped, m.start())
        if ln < declared[name]:
            problems.append(
                f"{path.name}:{ln} calls '{name}', but its local is declared at "
                f"line {declared[name]} -- this reads a nil global at runtime"
            )
    return problems


def main(root: pathlib.Path, files: list[str]) -> int:
    problems = []
    for rel in files:
        problems += check_file(root / rel)
    for p in problems:
        print("LINT  " + p)
    if not problems:
        print(f"ok   lint                       {len(files)} files, no use-before-declare")
    return len(problems)
