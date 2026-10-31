---
title: Configuration and CI
nav_order: 5
---

# Configuration and CI
{: .no_toc }

1. TOC
{:toc}

## Limits by class of code

Code is hot, normal or cold, by globs in `complexity.zon` in the
directory gnarl runs in (or the file `--config` names); with no file,
every file is normal. Default limits, warning then critical; nesting and
params have a warning limit only, so they mark a row `!` but never fail
`--check`:

| | cyclomatic | cognitive | lines | nesting | params |
| --- | --- | --- | --- | --- | --- |
| hot | 8, 12 | 10, 15 | 40, 80 | 3 | 4 |
| normal | 10, 15 | 15, 25 | 50, 100 | 4 | 4 |
| cold | critical 20 | critical 35 | | | |
| tests | critical 20 | critical 35 | | | |

```zig
.{
    .hot = .{ "src/parse/**" },
    .cold = .{ "build.zig", "tools/**" },
    .exclude = .{ "test/fixtures" },
    .thresholds = .{
        .hot = .{ .cognitive = .{ .warning = 8, .critical = 12 } },
        .tests = .{ .lines = .{ .warning = 150 } },
    },
}
```

- `*` matches within a path segment, `**` across them, `?` one character.
  A path both a hot and a cold glob match is hot.
- A metric named under a class replaces both its limits there; the rest
  keep their defaults.
- A test block is held to `tests` wherever it lives: Zig keeps tests
  beside the code, so no glob could tell them apart, and a long test is
  usually a table of cases.
- `.exclude` leaves out what a glob matches, or what is inside it, as
  what git ignores is: not read under a directory named, read when named
  outright.

## Freezing the debt you have

On a codebase with debt already, write a baseline and commit it:

```console
$ gnarl --update-baseline
gnarl: complexity.baseline: note: wrote 1 function over a critical threshold
```

`complexity.baseline` is sorted plain text, a function a line, so a change
to it reads as a diff. From then on `gnarl --check` holds to it: a
function not in it over a critical limit fails, and so does one above its
number there. Within its limits, a function may change freely.

```console
$ gnarl --check
gnarl: --check: 1 function fails against complexity.baseline:
  tally.zig:7  tally: cognitive 34, above its baseline 33
gnarl --explain tally.zig:7 says why the first scores what it does
```

When a frozen function gets better, `--check` says so, and
`gnarl --update-baseline` tightens the ratchet; when it is within every
limit again, the update drops it. Debt can only shrink.

{: .note }
A function is known by its path and its name, so a rename or a move to
another file is a new function: update the baseline in the same change.

## In a pull request

```sh
gnarl --check                          # the gate
gnarl --diff origin/main --format md   # what the change did, for the review
```

`--diff` lists only the functions the change touched, with their numbers
before and after, says plainly when nothing got worse, and ends by saying
whether any of them is over a critical limit now.

## In GitHub Actions

A released binary, pinned and checked against its release's checksums:

```yaml
- name: install gnarl
  env:
    GNARL: v0.1.0
  run: |
    dir="$RUNNER_TEMP/gnarl" && mkdir -p "$dir" && cd "$dir"
    base="https://github.com/kmoneil/gnarl/releases/download/$GNARL"
    curl -fsSL --remote-name-all "$base/gnarl-linux-amd64" "$base/SHA256SUMS"
    grep ' gnarl-linux-amd64$' SHA256SUMS | sha256sum -c -
    mv gnarl-linux-amd64 gnarl && chmod +x gnarl
    echo "$dir" >> "$GITHUB_PATH"
- name: complexity
  run: gnarl --check
```

On a runner with Zig 0.17 it can be built instead:
`git clone --depth 1 https://github.com/kmoneil/gnarl`, then
`zig build -Doptimize=ReleaseFast` in it, and its `zig-out/bin` on the
`PATH`.
