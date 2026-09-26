# Contributing

Bug reports are as welcome as patches, and a log is worth more than either. If
something reads wrong in game, `/ewc scan`, `/ewc comm` or `/ewc phase` usually
says why, and the addon keeps its own log -- `/reload` writes it to
SavedVariables, so it survives the session.

## Running the tests

```
python -m venv .venv
.venv/Scripts/python.exe -m pip install lupa
.venv/Scripts/python.exe tests/run.py
```

`lupa` is the only dependency. The suite runs the addon's own Lua under a real
interpreter, parses every file, and lints for two mistakes that cost this
project a shipped bug each.

## What the suite can and cannot see

Files above `UI/Model.lua` in the `.toc` load under a plain interpreter: their
WoW calls are injected or sit inside function bodies, never at load time. Those
are tested. Everything below creates frames or registers events at load, so it
is only parsed.

Two traps follow from that, and both have bitten:

**The interpreter is Lua 5.5 and the game is a 5.1 dialect.** `goto`, labels
and anything else added after 5.1 parse cleanly here and fail in the client.
Write to 5.1 and do not read a green parse as proof a construct exists.

**A local read or called above its own declaration is a nil global**, not an
error, so it fails in game and nowhere else. The lint catches both now because
it did not catch either the first time.

## House rules

**Show a check red before trusting it green.** Every check in this repository
has been watched failing against the bug it guards. One that has only ever
passed has not been tested, it has been observed.

**Look at the artefact, not the exit code.** A pipeline returns the status of
its last command, so anything ending in `| tail` is always green. What matters
is the row that changed, the file that appeared, the message that was sent.

**Measure rather than assume.** Nearly every number here -- cycle lengths,
descent times, the release bias, the drop points -- was read off live play and
can be re-read. A figure with no source is a guess wearing a decimal point, and
where one is unavoidable the comment says whose guess it is.

**Vignette ids live in `Data/Vignettes.lua` and nowhere else.** They were
cross-checked against three addons and will be renumbered by some patch. When
that happens exactly one file should need editing, and `/ewc scan` prints what
the game is really sending so the new numbers can be read straight off.

**Nothing is bundled.** LibDeflate and AceSerializer are borrowed at runtime
through LibStub from whatever addon already loaded them. If neither is present
the affected feature says so and the rest carries on.

## Commit messages

Say why, not what. The diff already says what. A message that explains the
constraint, the measurement or the mistake being corrected is the only record
of it that survives; `git log` in this repository is closer to a lab notebook
than a changelog, and that is deliberate.

## Pull requests

Fork, branch, and open a PR against `master`. Keep the tests green, and if you
are fixing a bug, add the check that would have caught it.
