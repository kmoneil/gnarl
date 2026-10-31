---
name: gnarl
description: Complexity of each Zig function (cyclomatic, cognitive, logical lines, nesting depth, parameters), worst first, with every number explainable line by line. Use when asked how complex Zig code is or which functions to refactor first, before and after refactoring a Zig function to see what moved, and to gate CI on complexity.
---

# gnarl: how complex each Zig function is

gnarl reads Zig source with the compiler's own parser, with no build and
no semantic analysis, and measures every function and test block. It is
fast (all of Zig's standard library in a quarter of a second), so run it
as often as it helps.

## The loop

1. `gnarl --json src` lists the functions over a threshold, worst first.
   The summary says how many more are within limits; `--all` lists every
   function and `--top <n>` keeps the worst n. To read many rows cheaply,
   `--format tsv`.
2. `gnarl --explain <function>` for the one to work on. `<function>` is
   `path:line` as the report prints it, any line inside the function, or
   its name (or the end of it: `record` finds `Validator.record`). It
   lists each construct counted and where (for cognitive complexity, how
   much of each cost is its depth), the regions of the body (the
   signature and each statement, what each adds, so the costliest
   stand out; one that holds most of the cost is opened into its
   parts, a switch's prongs, a loop's statements), the deepest nesting
   chain, how
   the lines divide, and each parameter: aim the refactor at those lines.
   `gnarl --explain path:A-B` says what lines A to B cost and about what
   moving them into a function of their own would leave, before you do.
3. Change the code, then `gnarl --diff HEAD` lists each function the
   change touched (uncommitted edits and new files included) with its
   numbers before and after: worse first, then mixed (some numbers up and
   some down, as a function made simpler at the price of a parameter),
   added, the same, better and removed, and says plainly when nothing got
   worse. A function split in two shows as one changed and one added.
   `gnarl --function <function>
   src` measures one function again, whatever its numbers.
4. `gnarl --check src` in CI exits 1 when a function is over a critical
   threshold, and names the `--explain` to run for the worst.

`--explain` also tallies what of a function runs at compile time:
`comptime` blocks, `inline` loops and prongs, reflection builtins,
comptime and anytype parameters, and whether it returns a type. What
the source cannot show (an inferred error set's members, how often a
generic is instantiated, what an anytype must provide) it names as
unknown, rather than leaving out.

`gnarl --files src` lists files rather than functions: the files each
imports (fan-out), the files read that import it (fan-in), and the
modules it imports (`std`, named modules), which gnarl does not follow;
the most coupled first. A file many import is risky to change; one that
imports many knows too much.

On code with debt already, `gnarl --update-baseline src` writes
`complexity.baseline` (commit it): the functions over a critical
threshold now, with their numbers. From then on `--check` holds to it
and fails only what is new or worse: a function not in it over a
critical limit, or one above its number there. A function is known by
its path and name, so a rename or a move is a new function: update the
baseline in the same change. `--baseline <file>` names another file.

Paths are optional: with none, gnarl reads the current directory. A
function given to `--explain` or `--function` as `path:line` needs no
path besides, and then only its file is read.

## What it counts

Cyclomatic complexity is 1, and 1 for each `if` (so each `else if`, and
an `if` written as a value), `while`, `for`, `and`, `or`, `orelse`,
`catch` with a handler, and switch prong but a plain `else` or a lone
`_`. An `inline else` counts once. Nothing for a `try`, which only
passes an error on; a payload capture (`|v|`), which names a value on a
branch already counted; an `else`; a labeled `break` or `continue`; or a
`catch unreachable`, `catch {}` or `orelse unreachable`, which have no
other path.

Cognitive complexity is how hard the function is to follow. A structure
costs once however many ways it branches, and more the deeper it sits:
an `if`, `while`, `for`, `switch`, or a `catch` or `orelse` whose handler
is a block or a `switch`, costs 1 and 1 more for each level it is in.
An `else if`, an `else` and a loop's `else` cost 1, but not the `else` of
an `if` whose branches are both expressions. Each run of `and` or of
`or` costs 1, as do a `catch` or `orelse` with a value or a jump for its
handler, a labeled block used as a value, a `return` inside a loop or a
labeled `switch`, a labeled `break` or `continue` that ends a loop or
block on its way, and an `errdefer`. Nothing for a `try`, a `defer`, a
capture or a guard clause's `return`. `--explain` shows each cost a
function was charged and why, and the table below is checked against
gnarl itself.

| Code | cyclomatic | cognitive |
| --- | ---: | ---: |
| `fn f(x: E) u8 { return switch (x) { .a => 1, .b => 2, .c => 3, else => 0 }; }` | 4 | 1 |
| `fn f(xs: []const u8) void { for (xs) \|x\| { if (x > 0) { if (x < 9) use(x); } } }` | 4 | 6 |
| `fn f(x: i8) i8 { if (x > 0) { return 1; } else if (x < 0) { return -1; } else { return 0; } }` | 3 | 3 |
| `fn f(c: bool) u8 { return if (c) 1 else 2; }` | 2 | 1 |
| `fn f(a: bool, b: bool, c: bool) bool { return a and b and c; }` | 3 | 1 |
| `fn f(xs: []const u8) ?u8 { for (xs) \|x\| { if (x == 0) return x; } return null; }` | 3 | 4 |
| `fn f() !void { errdefer undo(); try work(); }` | 1 | 1 |

Nesting depth is how many levels deep the code goes. An `if`, `while`,
`for` or `switch` opens a level for its branches, as do a labeled block,
a container declared in the function, and a `catch` or `orelse` whose
handler is a block with something in it. An `else if` stays on its
`if`'s level, and a block that is a branch's body is that branch's
level.

| Code | cyclomatic | nesting |
| --- | ---: | ---: |
| `fn f() !void { try a(); }` | 1 | 0 |
| `fn f(c: bool) void { if (c) a() else b(); }` | 2 | 1 |
| `fn f(x: u8) void { if (x == 0) a() else if (x == 1) b() else c(); }` | 3 | 1 |
| `fn f(c: bool, d: bool) void { if (c and d) a(); }` | 3 | 1 |
| `fn f(c: bool) void { if (c) { if (c) a(); } }` | 3 | 2 |
| `fn f(o: ?u8) void { if (o) \|v\| use(v); }` | 2 | 1 |
| `fn f(xs: []const u8) void { for (xs) \|x\| use(x); }` | 2 | 1 |
| `fn f(o: ?u8) u8 { return o orelse 0; }` | 2 | 0 |
| `fn f(o: ?u8) u8 { return o orelse unreachable; }` | 1 | 0 |
| `fn f() u8 { return parse() catch 0; }` | 2 | 0 |
| `fn f() void { work() catch {}; }` | 1 | 0 |
| `fn f(x: E) void { switch (x) { .a => {}, .b, .c => {}, else => {} } }` | 3 | 1 |
| `fn f(x: E) void { switch (x) { .a => {}, inline else => {} } }` | 3 | 1 |
| `fn f(c: bool) u8 { return blk: { if (c) break :blk 1; break :blk 2; }; }` | 2 | 2 |
| `fn f() void { const S = struct { fn g(d: bool) void { if (d) {} } }; _ = S; }` | 1 | 1 |

The last row: a function declared inside another is measured on its own
(here as `f.S.g`, cyclomatic 2), and adds nothing to the one around it
but the container's level.

Logical lines are the lines from the signature to the closing brace that
hold code: not a blank line, a comment-only line, or a line of nothing
but closing brackets and the `;` or `,` after them. A nested function's
lines are its own.

Parameters leave out what is context rather than input: a leading self
(a first parameter typed as the container, `@This()`, or a name the
container gives `@This()`), and each `Allocator` or `Io`. Weighted
parameters count a type parameter and an `anytype` twice: each is a
contract the signature does not spell out.

| Code | params | weighted |
| --- | ---: | ---: |
| `const S = struct { fn f(self: *S, gpa: Allocator, n: u8) void {} };` | 1 | 1 |
| `fn f(comptime T: type, x: anytype, n: usize) void {}` | 3 | 5 |
| `fn f(io: std.Io, w: *std.Io.Writer) void {}` | 1 | 1 |

A worked example:

```zig
const S = struct {
    fn pick(s: *S, gpa: Allocator, x: u8) !u8 {
        if (x > 3 and x < 9) {
            for (s.items) |item| {
                // the first big one
                if (item > x) return item;
            }
        }
        return try s.fallback(gpa);
    }
};
```

gnarl measures S.pick: cyclomatic 5, cognitive 8, lines 5, nesting 3, params 1, weighted 1.

## Names

A function is named after what it is declared in: a method of `const
Validator = struct {...}` is `Validator.record`; one in a container
declared in a function body is `f.Local.g`; the methods of the struct a
generic function returns are `List.append`; a test is `test "its name"`.
Tests are measured like functions, with `kind` `test`.

## Reading the output

`--format` takes `text` (the default, a table), `md`, `json`, `xml`,
`csv` or `tsv`; `--json` is `--format json`. In the table, a number over
its warning threshold is marked `!` and over its critical one `!!`.

The json document (xml holds the same fields) starts with `schema`,
`gnarl` (the version), `files`, `measured`, `not_listed` (how many left
out, and why), `check` (`asked`, `failed`, `critical`), `thresholds`,
`errors` and `notes` (everything said on stderr, with `path`, `line`,
`column`, `text` and `more`), then `functions`, one to a line, each with
`path`, `line`, `end_line`, `column`, `name`, `kind`, `class`, the six
metrics (`cyclomatic`, `cognitive`, `lines`, `nesting`, `params`,
`params_weighted`) and `trips` (`metric`, `level`, `limit`).

A `--diff` document has `ref`, `changes` (how many `worse`, `mixed`,
`added`, `same`, `better`, `removed`) and `functions`, each with `change`,
`before` and `after` (null for the side it does not have). For a pull
request comment, `gnarl --diff origin/main --format md`.

An `--explain` document has
`explanations` instead, each with `cyclomatic.branches`,
`cognitive.costs` (each with its `depth`), `nesting.chain`, the `lines`
breakdown and `params.each`. csv and tsv
carry the rows alone, errors on stderr only; their `over` column lists
each limit passed as `metric:level:limit`, separated by spaces.

The summary counts every function measured, whatever is listed: with
`--function` or `--top` the table has fewer rows than the summary
counts, and the footer says how many are left out.

## Thresholds and complexity.zon

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
    .hot = .{ "src/scan.zig", "src/parse/**" },
    .cold = .{ "build.zig", "test/**" },
    .thresholds = .{ .hot = .{ .cyclomatic = .{ .warning = 6, .critical = 10 } } },
}
```

`*` matches within a path segment, `**` across them, `?` one character.
A metric named under a class replaces both its limits there.
A test block is held to `tests` whatever its file's class: Zig keeps
tests beside the code, so no glob can tell them apart, and a long test
is usually a table of cases. `.thresholds.tests` changes its limits.
`.exclude = .{ "test/fixtures" }` leaves out what a glob matches, or
what is inside it, as what git ignores is: not read under a directory
named, read when named outright.

## Exit status

0 when every file was read (and, with `--check`, nothing fails it); 1
when `--check` found what does; 2 on a usage error, a configuration or
baseline that cannot be used or written, a path that cannot be read or holds
no .zig file, a file that does not parse, or a `--function` or
`--explain` that names no function (or, for `--explain`, more than
one). gnarl still reports what it could read.

## What catches agents out

- A function missing from the report is within its limits: the default
  lists only what is over one. Use `--function` or `--all`.
- A long generic type function (`fn List(T: type) type { return struct
  {...}; }`) is short to gnarl: its methods are their own rows.
- Extracting a helper can move the cost into its parameters: the context
  the code needed becomes the helper's arguments. Measure the helper too
  (`--function` takes several), and prefer passing a struct over six
  values. `--diff` shows such a function as mixed: read which numbers
  fell before calling the change a loss.
- A flat `switch` of many prongs scores high cyclomatic and 1 cognitive:
  it has many paths but reads as one decision. Cognitive complexity is
  the better guide to what is hard to read; what raises it is depth, so
  guard clauses and extracting an inner loop bring it down most.
- `try` adds nothing, so a function of many `try`s can score 1; the
  explanation lists them, adding 0, to show they were seen.
- Paths are as gnarl prints them, relative to the current directory:
  pass `--explain` and `--function` the same form.
- `--exclude <path>` skips a file or directory; hidden directories,
  `zig-out` and `zig-pkg` are always skipped. In a git work tree, what
  git ignores is skipped too, unless named outright; `--no-ignore` reads
  it. A file you expect and do not see may be ignored.
- `gnarl --help` prints every flag and `gnarl --version` the version (the
  json's `gnarl`); `gnarl skill --install <dir>` writes this file to
  `<dir>/gnarl/SKILL.md`.
