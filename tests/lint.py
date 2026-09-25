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


def strip_code(text: str) -> str:
    """Everything that is not code, blanked out, line numbers intact.

    String literals matter as much as comments: a format string like "%s (%d)"
    otherwise reads as a call to a function named s, which this tool duly
    reported against Main.lua. A linter that cries wolf gets switched off, and
    then it is worth nothing.
    """
    stripped = blank_out(text, BLOCK_COMMENT)
    stripped = blank_out(stripped, LONG_STR)
    stripped = blank_out(stripped, LINE_COMMENT)
    return blank_out(stripped, QUOTED)


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    stripped = strip_code(text)

    declared: dict[str, int] = {}
    for pattern in (DECL_FUNC, DECL_VAR):
        for m in pattern.finditer(stripped):
            name = m.group(1)
            ln = line_of(stripped, m.start())
            declared[name] = min(declared.get(name, ln), ln)

    problems = []
    problems += mixed_clocks(path, stripped)
    problems += read_before_declared(path, stripped)
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
    problems += stale_call_sites(root, files)
    for p in problems:
        print("LINT  " + p)
    if not problems:
        print(f"ok   lint                       {len(files)} files, no use-before-declare, no stale call sites")
    return len(problems)


DEF_METHOD = re.compile(r"^function\s+([A-Z]\w*)\.(\w+)\s*\(([^)]*)\)", re.M)
CALL_METHOD = re.compile(r"(?<![\w.])(?:ns\.)?([A-Z]\w*)\.(\w+)\s*\(")


def arg_text(stripped: str, open_paren: int) -> str | None:
    """What sits between this '(' and its match."""
    depth = 0
    for i in range(open_paren, len(stripped)):
        if stripped[i] in "([{":
            depth += 1
        elif stripped[i] in ")]}":
            depth -= 1
            if depth == 0:
                return stripped[open_paren + 1:i]
    return None


def stale_call_sites(root: pathlib.Path, files: list[str]) -> list[str]:
    """An argument passed into a parameter of a different name.

    Lua does not check arity. A call with too few arguments leaves the rest
    nil, so inserting a parameter in the middle of a signature and missing one
    caller is silent everywhere the suite can see: Route.Plan grew a shardOf
    ahead of its now, and /ewc route went on passing four arguments. The timer
    it then tried to call as a function was the number now. Green tests, green
    deploy, and the command was dead for anyone who had actually set a route.

    Arity alone cannot find this -- trailing arguments are legitimately dropped
    all over this addon. What gives it away is a bare name that matches a
    parameter of the callee at a different position, which is what a stale call
    looks like after a signature grows in the middle.
    """
    params: dict[tuple[str, str], list[str]] = {}
    stripped_of: dict[str, str] = {}
    for rel in files:
        text = strip_code((root / rel).read_text(encoding="utf-8"))
        stripped_of[rel] = text
        for m in DEF_METHOD.finditer(text):
            names = [a.strip() for a in m.group(3).split(",") if a.strip()]
            params[(m.group(1), m.group(2))] = names

    problems = []
    for rel, text in stripped_of.items():
        for m in CALL_METHOD.finditer(text):
            key = (m.group(1), m.group(2))
            if key not in params or text[m.start():].startswith("function"):
                continue
            body = arg_text(text, m.end() - 1)
            if body is None or not body.strip():
                continue
            args = split_commas(body)
            for i, arg in enumerate(args):
                if not arg.isidentifier():
                    continue
                if arg in params[key] and params[key].index(arg) != i:
                    problems.append(
                        f"{pathlib.Path(rel).name}:{line_of(text, m.start())} passes "
                        f"'{arg}' as argument {i + 1} to {key[0]}.{key[1]}, which "
                        f"takes {len(params[key])} and whose '{arg}' is argument "
                        f"{params[key].index(arg) + 1}"
                    )
    return problems


# Only file-scope locals: no leading whitespace. A name declared inside some
# function is a different name, and treating it as this one is how a rule like
# this starts crying wolf.
DECL_TOP = re.compile(r"^local\s+(?:function\s+)?([A-Za-z_]\w*)", re.M)
WORD = re.compile(r"(?<![\w.:])([A-Za-z_]\w*)")


def read_before_declared(path: pathlib.Path, stripped: str) -> list[str]:
    """A file-scope local READ above the line that declares it.

    The rule above catches it being called. Reading it is the same bug and was
    not caught: liveSpectral was declared beside the table it belongs with, six
    hundred lines below the function that iterates it, and pairs(liveSpectral)
    is a call to pairs with a nil global as its argument. Tests green, lint
    green, deploy green, and /ewc show dead.

    Scoped to declarations at file level on purpose, and only to names this file
    declares at all -- anything else is a global, which may legitimately be a
    WoW API that happens to share the name.
    """
    declared = {}
    for m in DECL_TOP.finditer(stripped):
        ln = line_of(stripped, m.start())
        declared[m.group(1)] = min(declared.get(m.group(1), ln), ln)

    problems, seen = [], set()
    for m in WORD.finditer(stripped):
        name = m.group(1)
        if name not in declared:
            continue
        ln = line_of(stripped, m.start())
        if ln >= declared[name] or (name, ln) in seen:
            continue
        seen.add((name, ln))
        problems.append(
            f"{path.name}:{ln} reads '{name}', whose file-scope local is declared at "
            f"line {declared[name]} -- until that line it is a nil global"
        )
    return problems
