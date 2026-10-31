---
title: Walkthrough
nav_order: 2
---

# One function, start to finish
{: .no_toc }

Here is `tally`, gnarled the usual way: two near-copies of a loop under an
`if`, each with an insert-or-add tucked inside. The line numbers below are
the whole file's, which starts with its imports and an `Item` type, so
`tally` is on line 7.

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

## 1. Find it

```console
$ gnarl
cyclomatic  cognitive  lines  nesting  params  weighted  location     function
      11!        33!!   23        5!      4         4    tally.zig:7  tally

1 function in 1 file: 1 over a critical threshold (!!), 0 more over a warning one (!).
Thresholds for normal code (warning, critical): cyclomatic 10, 15; cognitive 15, 25; lines 50, 100; nesting 4; params 4.
```

Cognitive complexity 33 is over the critical limit for normal code, 25.

## 2. Ask why

`gnarl --explain tally` lists every construct and its cost, then the parts
of the function that carry it (abridged):

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

## 3. Ask what a cut would leave

```console
$ gnarl --explain tally.zig:24-34
lines 24-34: cyclomatic +4, cognitive +14 (9 of it for depth), 8 logical lines, the deepest level 5
moved into a function of its own, about: that function cyclomatic 5, cognitive 8, nesting 3, params 4; tally keeps cyclomatic 7, cognitive 19, lines 16
it would take item, wanted: []const u8, out: *std.StringHashMap(u32), total: u32; and give back total (assigned in the lines, read after them)
no return, break or continue leaves those lines
```

Before any code moves: the new function's numbers and the old one's, the
parameters it would take with their types where written, what it would
have to give back, and whether any jump would need reworking.

{: .note }
For a straight move of the lines, the estimate has matched the result in
every refactor of gnarl's own code.

## 4. Cut, and check

Merge the two loops behind a `matches`, lift the insert-or-add into an
`add`:

```zig
pub fn tally(items: []const Item, wanted: []const u8, strict: bool, out: *std.StringHashMap(u32)) !u32 {
    var total: u32 = 0;
    for (items) |item| {
        if (item.qty == 0) continue;
        for (item.tags) |tag| {
            if (!matches(tag, wanted, strict)) continue;
            try add(out, tag, item.qty);
            total += item.qty;
        }
    }
    return total;
}

fn matches(tag: []const u8, wanted: []const u8, strict: bool) bool {
    if (strict) return std.mem.eql(u8, tag, wanted);
    return std.mem.startsWith(u8, tag, wanted) or std.mem.endsWith(u8, tag, wanted);
}

fn add(out: *std.StringHashMap(u32), tag: []const u8, qty: u32) !void {
    const entry = try out.getOrPut(tag);
    entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + qty else qty;
}
```

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
