# Vendored libraries

Not written here. Committed rather than fetched at build time so that a clone
of this repo deploys and runs without a second step: `tools/deploy.py` copies
exactly what the `.toc` lists, and a `.toc` naming files that are not in the
tree fails by the addon quietly not working.

| Library | Version | Why it is here |
| --- | --- | --- |
| LibStub | minor 2 | Every library below finds the others through it. |
| CallbackHandler-1.0 | minor 8 | Required by both LibDataBroker and LibDBIcon. |
| LibDataBroker-1.1 | minor 4 | The data object LibDBIcon draws. |
| LibDBIcon-1.0 | minor 56 | The minimap button itself. |

Taken from the copies BugSack ships, on 2 Oct 2026. That is not laziness about
the canonical source: LibDBIcon and BugSack have the same maintainer, so the
copy BugSack carries is the one its author is shipping.

## Why the button is not hand-rolled any more

It was, in 107 lines, and the reasoning is in this repo's history. What that
missed is that the libraries are not bought for square-minimap support. They
are bought for the name: every button organiser in the ecosystem decides what
to leave alone by looking for `LibDBIcon` in a frame's name.

Leatrix Plus walks `Minimap:GetChildren()` and, for any named button without
it, hides the button, installs an `OnShow` that hides it again, and stands its
own proxy in the place -- which loses the tooltip, and the tooltip is the
reason to hover a minimap button at all. ElvUI and SexyMap collect buttons the
same way.

## Licensing, stated honestly

LibStub says in its own header that it is in the public domain.
CallbackHandler-1.0 is part of Ace3, whose licence requires that the copyright
notice travel with any redistribution, so `Ace3-LICENSE.txt` sits beside it.

LibDataBroker-1.1 and LibDBIcon-1.0 carry no licence text in the copies taken,
and theirs has not been verified here. Both are redistributed inside hundreds
of published addons, so this is a paperwork gap and not a dispute -- but it is
a gap, and the licence files should be pulled from their own repositories
before the next release rather than assumed.

## Updating

Replace the file, update the minor in the table above, and run `tests/run.py`
and `tools/firstrun.py`. Nothing in this folder is linted or unit-tested: the
harness works from its own list of our files, deliberately, because a lint rule
written for this addon's conventions has nothing useful to say about somebody
else's library.
