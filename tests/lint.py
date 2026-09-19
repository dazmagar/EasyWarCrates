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


def blank_out(text: str, pattern: re.Pattern) -> str:
    """Replace each match with spaces, keeping every line number intact."""
    return pattern.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


# Long strings first, then comments, then quoted strings. Order matters: a
# comment inside a string is not a comment, and vice versa.
LONG_STR = re.compile(r"\[\[.*?\]\]", re.S)
BLOCK_COMMENT = re.compile(r"--\[\[.*?\]\]", re.S)
LINE_COMMENT = re.compile(r"--[^\n]*")
QUOTED = re.compile(r'"(?:\\.|[^"\\\n])*"' r"|'(?:\\.|[^'\\\n])*'")


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")

    # Blank out anything that is not code. String literals matter as much as
    # comments here: a format string like "%s (%d)" otherwise reads as a call
    # to a function named s, which this tool duly reported against Main.lua.
    # A linter that cries wolf gets switched off, and then it is worth nothing.
    stripped = blank_out(text, BLOCK_COMMENT)
    stripped = blank_out(stripped, LONG_STR)
    stripped = blank_out(stripped, LINE_COMMENT)
    stripped = blank_out(stripped, QUOTED)

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
