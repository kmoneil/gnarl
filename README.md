# gnarl

**Find the gnarled code in your Zig. See exactly why it is gnarled. Cut it
with a plan, and keep it cut.**

gnarl measures every function in a Zig codebase (cyclomatic and cognitive
complexity, logical lines, nesting depth, parameters) and then does the
part other metrics tools leave to you: it explains each number construct
by construct, points at the lines worth lifting out, predicts what the
refactor will leave before you make it, and holds the line in CI so the
debt you have cannot grow.

[![ci](https://github.com/kmoneil/gnarl/actions/workflows/ci.yml/badge.svg)](https://github.com/kmoneil/gnarl/actions/workflows/ci.yml)

`Zig 0.17` · `one binary` · `no build step` · `no dependencies` ·
`all of Zig's standard library in a fifth of a second`

It reads source with the compiler's own parser, `std.zig.Ast`: no build,
no semantic analysis, nothing to configure before the first run.

## What it looks like

```console
$ gnarl
cyclomatic  cognitive  lines  nesting  params  weighted  location     function
      11!        33!!   23        5!      4         4    tally.zig:7  tally

1 function in 1 file: 1 over a critical threshold (!!), 0 more over a warning one (!).
Thresholds for normal code (warning, critical): cyclomatic 10, 15; cognitive 15, 25; lines 50, 100; nesting 4; params 4.
```

`!` is over a warning limit, `!!` over a critical one. By default gnarl
lists only what needs attention; `--all` lists everything.

## Why gnarl

- **It counts Zig, not C.** A `try` is not a branch. `catch unreachable`
  and `orelse unreachable` have no other path, so they cost nothing. An
  `inline else` counts once, as the one prong it is written as. A flat
  `switch` of
  forty prongs is one decision to a reader, and cognitive complexity says
  so. Functions declared inside functions are measured, and named, on
  their own.
- **Every number explains itself.** `--explain` lists each construct
  counted, where it is, what it costs, and how much of that cost is its
  depth. No number is a black box.
- **It tells you where to cut.** The regions of a function show which
  statements carry the cost. For a function over a limit, gnarl suggests
  the ranges worth lifting out, best first.
- **It predicts the refactor.** `--explain path:A-B` says what lines A to
  B cost, what a function of their own would score, what it would take
  as parameters and give back, and which `return`, `break` or `continue`
  would need reworking. All before you touch the code.
- **It shows the before and after.** `--diff HEAD` lists each function
  your change touched, with its numbers then and now: worse, mixed,
  added, the same, better or removed.
- **It holds the line in CI.** A baseline freezes the debt you have:
  `--check` fails only what is new or worse, so a legacy codebase can
  adopt it today.
- **It knows hot code from cold.** Classes of code by path glob, each
  with its own limits; test blocks are held as tests wherever they live.
- **It speaks every format.** text, Markdown, JSON, XML, csv and tsv;
  the JSON and XML carry everything stderr says, versioned.
- **It teaches itself to AI agents.** `gnarl skill` prints what an agent
  needs to use it well, kept true by gnarl's own tests.

## Install

gnarl needs Zig 0.17.

```sh
git clone https://github.com/kmoneil/gnarl
cd gnarl
zig build -Doptimize=ReleaseFast
cp zig-out/bin/gnarl ~/.local/bin/   # or anywhere on your PATH
```

## The loop

```sh
gnarl                      # what is over a limit, worst first
gnarl --explain tally      # why, construct by construct, and where to cut
# ...refactor...
gnarl --diff HEAD          # what your change did, function by function
gnarl --check              # in CI: exit 1 on what is new or worse
```

## One function, start to finish

Here is `tally`, gnarled the usual way: two near-copies of a loop under an
`if`, each with an insert-or-add tucked inside. (The line numbers below
are the whole file's, which starts with its imports and an `Item` type,
so `tally` is on line 7.)

```zig
pub fn tally(items: []const Item, wanted: []const u8, strict: bool, out: *std.StringHashMap(u32)) !u32 {
    var total: u32 = 0;
    for (items) |item| {
        if (item.qty == 0) continue;
        if (strict) {
            for (item.tags) |tag| {
                if (std.mem.eql(u8, tag, wanted)) {
                    const entry = try out.getOrPut(tag);
                    if (entry.found_existing) {
                        entry.value_ptr.* += item.qty;
                    } else {
                        entry.value_ptr.* = item.qty;
                    }
                    total += item.qty;
                }
            }
        } else {
            for (item.tags) |tag| {
                if (std.mem.startsWith(u8, tag, wanted) or std.mem.endsWith(u8, tag, wanted)) {
                    // ...the same insert-or-add, again...
                }
            }
        }
    }
    return total;
}
```

### Ask why

`gnarl --explain tally` lists every construct and its cost (abridged
here) and then the parts of the function that carry it:

```console
$ gnarl --explain tally
cognitive 33, over the critical limit (25): the sum of these
  9:5    for   +1
  10:9   if    +2  1 for its depth
  11:9   if    +2  1 for its depth
  12:13  for   +3  2 for its depth
  13:17  if    +4  3 for its depth
  15:21  if    +5  4 for its depth
  ...
regions: the signature and the body's statements, one that held most of the cost opened into its parts (indented); what each adds
  lines  cyclomatic  cognitive  logical  deepest
  7      +0          +0         1        0        pub fn tally(items: []const Item, wanted: []const u8, str...
  8      +0          +0         1        0        var total: u32 = 0;
  9      +1          +1         1        1        for (items) |item| {
  10     +1          +2         1        2          if (item.qty == 0) continue;
  11     +1          +3         2        2          if (strict) {
  12-22  +3          +13        8        5            for (item.tags) |tag| {
  24-34  +4          +14        8        5            for (item.tags) |tag| {
  37     +0          +0         1        0        return total;
worth lifting out, best first; --explain path:A-B says more of each:
  24-34  a function of cyclomatic 5, cognitive 8, params 4; tally keeps cyclomatic 7, cognitive 19; gives back total
  15-19  a function of cyclomatic 2, cognitive 2, params 2; tally keeps cyclomatic 10, cognitive 27
```

The cost is depth, not branching: the `if`s five levels in cost five each.
The two loops carry 27 of the 33, and the insert-or-add (15-19) is worth
lifting out on its own, which is how the duplicate shows itself.

### Ask what a cut would leave

```console
$ gnarl --explain tally.zig:24-34
lines 24-34: cyclomatic +4, cognitive +14 (9 of it for depth), 8 logical lines, the deepest level 5
moved into a function of its own, about: that function cyclomatic 5, cognitive 8, nesting 3, params 4; tally keeps cyclomatic 7, cognitive 19, lines 16
it would take item, wanted: []const u8, out: *std.StringHashMap(u32), total: u32; and give back total (assigned in the lines, read after them)
no return, break or continue leaves those lines
```

For a straight move of the lines, the estimate has matched the result in
every refactor of gnarl's own code.

### Cut, and check

Merge the two loops behind a `matches`, lift the insert-or-add into an
`add`, and ask what changed:

```console
$ gnarl --diff HEAD
change  cyclomatic  cognitive  lines    nesting  params  weighted  location      function
added   3           2          3        1        3       3         tally.zig:20  matches
added   2           1          3        1        3       3         tally.zig:25  add
better  11 -> 5     33 -> 8    23 -> 9  5 -> 3   4       4         tally.zig:7   tally

3 functions touched in 1 file since HEAD: 0 worse, 0 mixed, 2 added, 0 the same, 1 better, 0 removed.
Nothing got worse.
None of them is over a critical limit now.
```

Cognitive 33 to 8, nesting 5 to 3, and nothing left over a limit.

## What it measures

| Metric | What it counts |
| --- | --- |
| cyclomatic | 1, and 1 for each `if`, loop, `and`, `or`, `orelse`, real `catch`, and switch prong but a plain `else` |
| cognitive | each structure once, plus 1 for every level it is nested in; `and`/`or` runs, labeled jumps that cut across, `errdefer` |
| lines | logical lines: no blanks, comment-only lines or lone closing brackets |
| nesting | how many levels deep the code goes |
| params | parameters, a leading `self`, `Allocator` and `Io` left out |
| weighted | the same, a type parameter and an `anytype` counted twice |

`--explain` also tallies what runs at compile time (`comptime` blocks,
`inline` loops, reflection builtins, comptime and `anytype` parameters)
and names what the source alone cannot show, such as the members of an
inferred error set, rather than leaving it out. `gnarl --files` lists
each file's fan-out and fan-in:

```console
$ gnarl --files --top 3
fan-out  fan-in  modules  file
     27       0        4  src/main.zig
     16       2        1  src/explain.zig
      1      15        1  src/functions.zig
```

The cognitive rules, each with a worked example the tests are held to,
are in [docs/cognitive.md](docs/cognitive.md).

## Holding the line in CI

On a codebase with debt already, freeze it. After the report, gnarl says:

```console
$ gnarl --update-baseline
gnarl: complexity.baseline: note: wrote 1 function over a critical threshold
```

Commit `complexity.baseline`. From then on `gnarl --check` passes what was
already there and fails what is new or worse. After the report, it names
the function, the metric, and the `--explain` to run:

```console
$ gnarl --check
gnarl: --check: 1 function fails against complexity.baseline:
  tally.zig:7  tally: cognitive 34, above its baseline 33
gnarl --explain tally.zig:7 says why the first scores what it does
```

When a frozen function improves, `--check` says so, and
`--update-baseline` tightens the ratchet. Debt can only shrink.

## Hot, normal and cold code

`complexity.zon` in the directory gnarl runs in sorts paths into classes,
each with its own limits, and leaves out what should not be read:

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

Test blocks are held as tests wherever they live: a long test is usually
a table of cases, so only a test with real logic in it is flagged.

## Output for people and for programs

`--format` takes `text` (the default), `md` (for a pull request comment),
`json` or `xml` (every field, and everything said on stderr, versioned),
`csv` or `tsv`. Every document's fields are listed in
[docs/output.md](docs/output.md), and a test keeps that list and the
documents the same.

```sh
gnarl --diff origin/main --format md   # paste into a review
gnarl --json src | jq '.functions[0]'  # feed a dashboard
```

## Built for AI agents

An agent pays for every row it reads and acts on every number it is
given, so gnarl is built for that: output is economical by default,
every number can be explained, every message says what to do next, and
`--json` never needs a line of stderr scraped.

```sh
gnarl skill                       # print the guide an agent needs
gnarl skill --install ~/.skills   # write it to ~/.skills/gnarl/SKILL.md
```

The skill is embedded in the binary and tested against it: every example
in it is measured as it says.

## gnarl measures itself

`zig build test` runs the tests, checks the formatting, and runs
`gnarl --check` on gnarl's own source against its own baseline. The
baseline holds one function: a `switch` over every syntax node tag with
no `else`, so that a new Zig release that adds a tag breaks the build
rather than a count. It has cyclomatic complexity 33 and cognitive 3,
by design. Everything else is within its limits.

## Developing

```sh
zig build test              # tests, formatting, and gnarl held to its own baseline
zig build fmt               # format the source
zig build test -Dupdate     # rewrite the golden tables after a deliberate rule change
```

[CONTRIBUTING.md](CONTRIBUTING.md) says what a change needs.

## License

Apache License 2.0; see [LICENSE](LICENSE).
