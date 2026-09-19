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
    problems += mixed_clocks(path, stripped)
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


CLOCKS = ("tNow", "stamp")
ASSIGN = re.compile(r"^\s*(?:local\s+)?([^=\n]+?)\s*=(?![=])\s*(.+)$", re.M)
TABLE_READ = re.compile(r"^(\w+)\[")
CLOCK_USE = re.compile(r"\b(tNow|stamp)\s*-\s*\(?\s*(\w+)")


def split_commas(s: str) -> list[str]:
    """Top-level comma split: a[i], b[j] must not break inside the brackets."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    return out


def mixed_clocks(path: pathlib.Path, stripped: str) -> list[str]:
    """Subtracting a game-uptime reading from a unix timestamp.

    Detect/Scanner.lua carries two clocks: GetTime() as tNow, seconds since the
    client started, and GetServerTime() as stamp, a unix timestamp. Both are
    plain numbers, so mixing them is silent. It happened: a sweep marker was
    stored as tNow and compared against stamp, which put about 1.7 billion
    between them, so the test it guarded was never satisfied and every descent
    reading in every zone came out flagged as a fragment.

    Nothing in the suite can see that file -- it is all game API -- so its only
    check was a player noticing in a log. This is cheaper.

    Clocks propagate: through multiple assignment, which is how the mistake was
    actually written, and on into the locals that read those tables, which is
    where the comparison sat. The first two versions of this rule handled
    neither and were green against the live bug.
    """
    holds: dict[str, str] = {}
    for _ in range(3):        # a few passes, so order in the file does not matter
        for m in ASSIGN.finditer(stripped):
            names = split_commas(m.group(1))
            values = split_commas(m.group(2))
            for name, value in zip(names, values):
                target = TABLE_READ.match(name)
                key = target.group(1) if target else name.strip()
                if not key.isidentifier():
                    continue
                if value in CLOCKS:
                    holds[key] = value
                    continue
                src = TABLE_READ.match(value)
                if src and src.group(1) in holds:
                    holds[key] = holds[src.group(1)]
                elif value in holds:
                    holds[key] = holds[value]

    problems = []
    for m in CLOCK_USE.finditer(stripped):
        clock, name = m.group(1), m.group(2)
        if holds.get(name) and holds[name] != clock:
            problems.append(
                f"{path.name}:{line_of(stripped, m.start())} subtracts '{name}', "
                f"which holds {holds[name]}, from {clock} -- different clocks"
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
