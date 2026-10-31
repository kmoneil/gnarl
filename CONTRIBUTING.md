# Contributing

gnarl builds with Zig 0.17.0 and has no dependencies. `zig build` leaves
the binary in `zig-out/bin/`.

```sh
zig build test              # everything below, in one command
zig build lint              # zigvet over gnarl's own source
zig build fmt               # format the source as zig fmt does
zig build test -Dupdate     # rewrite the golden tables after a deliberate rule change
```

`zig build test` runs the unit tests and the golden tables, checks the
formatting, and holds gnarl to its own complexity baseline. Pull requests
to `main` need it green on Linux, macOS and Windows, in Debug, ReleaseSafe
and ReleaseFast, and `zig build lint` clean.

## gnarl is held to itself

`zig build test` runs `gnarl --check` over gnarl's own source against
`complexity.baseline`. A new function over a critical limit fails it, and
so does a frozen one that gets worse. When a change makes a frozen function
better, `--check` says so: run `gnarl --update-baseline` and commit the
tighter baseline with the change. Before you open a pull request,
`gnarl --diff origin/main` shows what your change did to each function it
touched.

## Counting rules

A counting rule is decided in writing before it is built. The cognitive
rules are [docs/cognitive.md](docs/cognitive.md), and its tests read that
document: every example in it is a test, each function's count and each
line's costs as its comments give them. A change to a rule is a change to
the document, its examples first.

Each counter (`src/cyclomatic.zig`, `src/cognitive.zig`,
`src/nesting.zig`, `src/lines.zig`, `src/params.zig`) has a test per rule,
with the count worked out by hand in a comment beside it, and an
`explain` whose reasons add up to the count, which a test checks on every
golden fixture.

## The golden tables

`test/golden/` holds fixtures and, beside each, the table of every metric
of every function in it. A change that moves a number fails the golden
test. When the move is meant, `zig build test -Dupdate` rewrites the
tables; read the diff before committing it: a table is only as right as
its reading.

## Output

Every document gnarl writes has its fields listed in
[docs/output.md](docs/output.md), and a test keeps the two the same: a
field added to the JSON and not to the document fails it, and so does one
the document lists and the JSON does not hold. The JSON and XML carry a
`schema` number that goes up when a field is renamed, moved or taken away;
a field added leaves it.

`src/skill.md` is what `gnarl skill` prints, and `src/skill.zig` tests
every example in it against the binary. A new flag, metric or format is
named there in the same change.

## Writing

Messages say what is wrong and what to do next, in plain words. Every
number gnarl prints can be explained by `--explain`; a new metric comes
with its explanation.
