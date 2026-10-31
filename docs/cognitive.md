# Cognitive complexity

Cyclomatic complexity counts the paths through a function. Cognitive
complexity counts how hard the function is to follow. The two part ways
where it matters most: a flat `switch` of twenty prongs has twenty paths
but reads as one decision, while three loops and conditions inside one
another read far worse than three side by side. So cognitive complexity
charges once for a structure, however many ways it branches, and charges
more for a structure the deeper it sits.

This document is the rule book. It was written before the counter, so
that the counter is held to it rather than the other way round: each
example below is a test, and the counter must give the number shown.

## The rules in short

A function starts at 0.

| What | Costs |
| --- | --- |
| `if`, `while`, `for`, `switch`, and `catch` or `orelse` with a block | 1, and 1 more for each level it sits in |
| `else if`, `else`, a loop's `else` | 1 |
| an `if` with an `else` whose branches are both expressions | 1, and 1 more for each level; its `else` nothing |
| each run of `and` or of `or` | 1 |
| `catch` or `orelse` with a value or a jump | 1 |
| a labeled block used as a value | 1 |
| a `return` inside a loop or a labeled `switch` | 1 |
| a `break` or `continue` that jumps past a loop, a labeled `switch` or a labeled block | 1 |
| an `errdefer` | 1 |
| `try`, a capture, a plain block, `defer`, a `break` or `continue` past nothing, a call | 0 |

These open a level for what is inside them: the branches of an `if`
(each `else if` and `else` on the `if`'s own level), a loop's body and
`else`, a `switch`'s prongs, a `catch` or `orelse` handler that is a
block, and a labeled block used as a value. Nothing else does.

A function declared inside another, in a container in its body, is
measured on its own, starting at 0; it adds nothing to the one around it.

## Straight-line code

Calls, `try`, `defer` and declarations cost nothing: they do not branch,
and a reader takes them in order.

```zig
fn load(gpa: Allocator, path: []const u8) !Config {
    const text = try readAll(gpa, path);
    defer gpa.free(text);
    return try parse(gpa, text);
}
```

Cognitive 0.

## if, and depth

An `if` costs 1, and 1 more for each level it is inside: an `if` in the
function's body costs 1, one inside a loop costs 2, one inside that 3.

```zig
fn count(rows: []const Row, limit: u32) usize {
    var n: usize = 0;
    for (rows) |row| { // 1: a loop in the body
        if (row.size > limit) { // 2: an if one level in
            if (row.valid) n += 1; // 3: an if two levels in
        }
    }
    return n;
}
```

Cognitive 6.

## else if and else

An `else if` and an `else` cost 1 each, and never more for their depth:
a chain is one decision with several outcomes, read at one level.

```zig
fn sign(x: i32) i8 {
    if (x > 0) { // 1
        return 1;
    } else if (x < 0) { // 1
        return -1;
    } else { // 1
        return 0;
    }
}
```

Cognitive 3.

The same chain one level in costs its `if` 2, its `else if` and `else` 1
each:

```zig
fn tallySigns(xs: []const i32, out: *Signs) void {
    for (xs) |x| { // 1
        if (x > 0) { // 2
            out.pos += 1;
        } else if (x < 0) { // 1
            out.neg += 1;
        } else { // 1
            out.zero += 1;
        }
    }
}
```

Cognitive 5.

## An if as a value

An `if` with an `else` whose branches are both expressions, not blocks,
reads as one choice of two values: it costs 1 and 1 more for each level,
and its `else` costs nothing.

```zig
fn pick(c: bool, a: u8, b: u8) u8 {
    return if (c) a else b; // 1
}
```

Cognitive 1.

## Loops

A `while` or a `for`, `inline` or not, costs 1 and 1 more for each
level. A loop's `else` costs 1. A capture costs nothing: it names what
the loop already decided.

```zig
fn sumUntil(it: *Iter, stop: u32) u32 {
    var total: u32 = 0;
    while (it.next()) |v| { // 1
        if (v == stop) break; // 2
        total += v;
    } else { // 1
        total += 1;
    }
    return total;
}
```

Cognitive 4.

## switch

A `switch` costs 1 and 1 more for each level, however many prongs it
has. Its prongs are one level in. This is where cognitive complexity
parts most from cyclomatic: the switch below has cyclomatic complexity 7.

```zig
fn name(op: Op) []const u8 {
    return switch (op) { // 1
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .mod => "mod",
        .neg => "neg",
    };
}
```

Cognitive 1.

What a prong does is counted one level in:

```zig
fn apply(op: Op, a: i32, b: i32) !i32 {
    switch (op) { // 1
        .add => return a + b,
        .div => {
            if (b == 0) return error.DivideByZero; // 2
            return @divTrunc(a, b);
        },
        else => return error.Unsupported,
    }
}
```

Cognitive 3.

## and, or

Each run of `and`, or of `or`, costs 1, at any depth: `a and b and c`
reads as one condition, and a reader pays again only where the operator
changes. Parentheses do not end a run.

```zig
fn ready(a: bool, b: bool, c: bool, d: bool) bool {
    return a and b and c or d; // 1 for the and run, 1 for the or
}
```

Cognitive 2.

## orelse and catch

An `orelse` or a `catch` is a branch, as an `if` is. With a block for its
handler it costs as an `if` does, 1 and 1 more for each level, and opens
a level for the block. With a value or a jump for its handler (`orelse
0`, `orelse continue`, `catch |err| return err`, `catch @panic("no")`)
it reads as one line, and costs 1 at any depth. With no real handler,
`catch unreachable`, `catch {}` or `orelse unreachable`, it costs
nothing, as in the cyclomatic count.

```zig
fn lookup(map: *const Map, keys: []const []const u8) u32 {
    var total: u32 = 0;
    for (keys) |key| { // 1
        const v = map.get(key) orelse continue; // 1: a jump for its handler
        total += v;
    }
    return total;
}
```

Cognitive 2.

```zig
fn save(w: *Writer, rows: []const Row) void {
    for (rows) |row| { // 1
        w.print("{s}\n", .{row.name}) catch |err| { // 2: a block, one level in
            log(err);
            return; // 1: a return inside a loop
        };
    }
}
```

Cognitive 4.

A `catch` whose handler is a `switch` on the error is one structure: the
`catch` costs as above and its `switch` adds nothing of its own. Its
prongs are one level in.

```zig
fn open(path: []const u8) !File {
    return openFile(path) catch |err| switch (err) { // 1
        error.FileNotFound => try create(path),
        error.AccessDenied => error.NotYours,
        else => err,
    };
}
```

Cognitive 1.

## Jumps

A jump costs 1, at any depth, when it ends more than the construct it
names, the function for a `return`: a reader must hold where it lands
and what it cut short on the way.

- A `return` inside a loop or a labeled `switch` costs 1, since it ends
  the loop or the state machine as well as the function. Outside them it
  costs nothing: a guard clause, `if (bad) return error.Bad;`, costs its
  `if` and no more.
- A labeled `break` or `continue` costs 1 when a loop, a labeled
  `switch` or a labeled block stands between it and the construct its
  label names, since it ends that too. With nothing of the kind
  between, the label changes nothing: a `continue` to the loop or
  labeled `switch` it sits in, and a `break` that gives the block it
  sits in its value, cost nothing.
- An unlabeled `break` or `continue` costs nothing: it ends only the
  step a reader is already in.
- A labeled block used as a value costs 1 for itself, however many
  `break`s give it its value, and opens a level.

```zig
fn firstShared(xs: []const u8, ys: []const u8) ?u8 {
    outer: for (xs) |x| { // 1
        for (ys) |y| { // 2
            if (x == y) return x; // 3, and 1: a return inside a loop
            if (y > x) continue :outer; // 3, and 1: a continue past the inner loop
        }
    }
    return null;
}
```

Cognitive 11.

```zig
fn width(kind: Kind, bits: u16) u16 {
    const w = blk: { // 1: a labeled block used as a value
        if (kind == .tight) break :blk bits; // 2: an if one level in
        break :blk (bits + 7) / 8 * 8;
    };
    return w;
}
```

Cognitive 3.

A `break` that gives a block its value from inside a loop in that block
ends the loop too, and costs 1:

```zig
fn firstOdd(xs: []const u32) u32 {
    return blk: { // 1: a labeled block used as a value
        for (xs) |x| { // 2
            if (x % 2 == 1) break :blk x; // 3, and 1: a break past the loop
        }
        break :blk 0; // 0: nothing between it and its block
    };
}
```

Cognitive 7.

A labeled `switch` whose prongs `continue` to it is a state machine: a
loop and a `switch` in one structure, and it costs as one. The `switch`
costs 1 and 1 more for each level, and a `continue` to it straight from
a prong costs nothing, as an unlabeled `continue` in a loop does. One
sent from inside a loop in a prong ends that loop too, and costs 1. A
`return` from a prong ends the machine, and costs 1 as one from a loop
does; a `switch` is labeled to be continued to, so any labeled `switch`
counts.

```zig
fn run(start: State) void {
    sw: switch (start) { // 1
        .a => continue :sw .b,
        .b => continue :sw .done,
        .done => {},
    }
}
```

Cognitive 1.

```zig
fn drain(it: *Iter) void {
    sw: switch (it.state()) { // 1
        .pending => {
            while (it.next()) |v| { // 2
                if (v == 0) continue :sw .done; // 3, and 1: a continue past the loop
                feed(v);
            }
            continue :sw .flush; // 0: nothing between it and the switch
        },
        .flush => flush(it),
        .done => {},
    }
}
```

Cognitive 7.

```zig
fn lex(src: []const u8) ?usize {
    var i: usize = 0;
    sw: switch (State.start) { // 1
        .start => {
            if (i == src.len) return null; // 2, and 1: a return from the machine
            i += 1;
            continue :sw .word;
        },
        .word => return i, // 1: a return from the machine
    }
}
```

Cognitive 5.

## defer and errdefer

A `defer` always runs, so it costs nothing. An `errdefer` runs only on
the error path, a branch a reader must keep in mind for the rest of the
scope: it costs 1. Neither opens a level.

```zig
fn build(gpa: Allocator) !*Thing {
    const t = try gpa.create(Thing);
    errdefer gpa.destroy(t); // 1
    defer log("built");
    t.* = try .init(gpa);
    return t;
}
```

Cognitive 1.

## Functions inside functions

A function declared in a container inside another is measured on its
own, from depth 0, and adds nothing to the one around it; the container
costs nothing either. Zig has no closures, so such a function shares no
flow with the one it sits in.

```zig
fn sortRows(rows: []Row) void {
    std.mem.sort(Row, rows, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            if (a.size != b.size) return a.size < b.size; // 1, to lessThan
            return a.line < b.line;
        }
    }.lessThan);
}
```

Cognitive 0 for `sortRows`; `sortRows.lessThan` has its own 1.

## Not counted

- Recursion. A call to the function's own name could be seen, but not a
  call through a pointer, an interface or `@This()`, so counting some
  and not others would mislead.
- `comptime` itself. An `if`, `inline for` or `switch` evaluated at
  compile time costs as any other: it is still a decision a reader
  follows. The comptime tally counts them apart.

## A worked example

Every rule above, in one function, the cost of each line beside it.

```zig
fn tally(lines: []const []const u8, names: *const Names) !Counts {
    var counts: Counts = .{};
    for (lines, 0..) |line, i| { // 1: a loop in the body
        if (line.len == 0) continue; // 2: an if one level in
        const name = names.get(line) orelse { // 2: orelse with a block, one level in
            counts.unknown += 1;
            continue;
        };
        switch (name.kind) { // 2: a switch one level in
            .plain => counts.plain += 1,
            .quoted => {
                if (name.closed and i > 0) { // 3: an if two levels in; 1: an and
                    counts.quoted += 1;
                } else { // 1: an else
                    return error.Unclosed; // 1: a return inside a loop
                }
            },
        }
    }
    return counts;
}
```

Cognitive 13. Its cyclomatic complexity is 8 and its nesting depth 3.

## Thresholds

The defaults, warning then critical: hot code over 10 and over 15,
normal code over 15 and over 25, cold code only over 35. `--explain`
lists each cost and why: the construct, its line, and how much of its
cost is its depth.
