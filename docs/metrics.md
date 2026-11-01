---
title: Metrics
nav_order: 4
---

# What gnarl measures
{: .no_toc }

1. TOC
{:toc}

Each function and test block, from the compiler's own parser alone. Every number here can be taken apart with `gnarl --explain`.

| Metric | What it counts |
| --- | --- |
| cyclomatic | the paths through the function |
| cognitive | how hard it is to follow: each structure once, more the deeper it sits |
| lines | logical lines: no blanks, comment-only lines or lone closing brackets |
| nesting | how many levels deep the code goes |
| params | parameters, a leading `self`, `Allocator` and `Io` left out |
| weighted | the same, a type parameter and an `anytype` counted twice |

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
| `fn F(comptime T: type) type { return struct { const n = if (@sizeOf(T) > 8) 2 else 1; x: T }; }` | 1 | 0 |

The last two rows: a function declared inside another is measured on its
own (here as `f.S.g`, cyclomatic 2), and adds nothing to the one around
it but the container's level. A container a function returns, as a
generic type such as `F` does, is the type it makes, not code it runs:
like a container at the top of a file, it is in no function's numbers.
It opens no level, nothing in it counts, and its methods are measured on
their own. What the function does before it returns, such as checking
its parameters, counts as any code.

Logical lines are the lines from the signature to the closing brace that
hold code: not a blank line, a comment-only line, or a line of nothing
but closing brackets and the `;` or `,` after them. A nested function's
lines are its own, and the fields and declarations of a type a function
returns are no function's.

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


The cognitive rules in full, each with a worked example the tests are
held to, are on [Cognitive complexity](cognitive.md).

## What runs at compile time

`--explain` tallies what of a function runs at compile time: each
`comptime` block or expression, `inline` loop or prong, reflection builtin
(`@typeInfo`, `@Type`, `@hasDecl`, `@hasField`, `@FieldType`), comptime
and `anytype` parameter, and whether it returns a type. What the source
alone cannot show it names as unknown rather than leaving out: the
members of an inferred error set, how many times a generic function is
instantiated and with what, and what each `anytype` must provide.

## Fan-out and fan-in

`gnarl --files` lists files rather than functions: the files each imports
(fan-out), the files read that import it (fan-in), and the modules it
imports (`std`, build options, named modules), which gnarl names but does
not follow. A file many import is risky to change; one that imports many
knows too much.

```console
$ gnarl --files --top 3 .
fan-out  fan-in  modules  file
     27       0        4  src/main.zig
     16       2        1  src/explain.zig
      1      15        1  src/functions.zig
```
