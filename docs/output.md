---
title: Output formats
nav_order: 8
---
# gnarl's output

gnarl writes a report (the default) or explanations (`--explain`) in the
format `--format` names: `text`, the default, a table for a terminal;
`md`, the same as Markdown; `json` or `xml`, every field and everything
said on stderr; `csv` or `tsv`, a header row, then a row per function or
per explained item.

The json and xml documents carry a `schema` number. It goes up when a
field is renamed, moved or taken away; a field added leaves it as it is.
A program should read the fields it knows and leave the rest.

The json documents are compact, with the functions or explanations last
and one to a line, so a reader can stop early or take a line at a time.
The xml documents hold the same fields as attributes, with the same
names, and elements for what is a list or an object in json.

## The report

- `schema`: the shape's version, 1.
- `gnarl`: gnarl's version.
- `files`: how many files were measured.
- `measured`: how many functions were measured, listed or not.
- `not_listed`: how many functions the report leaves out, by why:
  - `within_limits`: within every limit, with no `--all`.
  - `past_top`: past `--top`.
  - `not_selected`: not picked by `--function`.
  - `not_failing`: under `--check`, over a limit but not failing it: the
    baseline holds it, or it is over a warning limit only.
- `check`: what `--check` found:
  - `asked`: whether `--check` was given.
  - `failed`: whether it fails the run, exit status 1.
  - `critical`: how many functions are over a critical threshold, asked
    or not.
  - `baseline`: the baseline file it was held to; null for none.
  - `failures`: what fails it, worst first, each metric of a function
    over what it may be (its critical limit, or its baseline's number if
    higher):
    - `path`, `line`, `name`: the function, as in `functions`.
    - `metric`, `value`: the metric and its number.
    - `limit`: its critical limit.
    - `baselined`: the baseline's number for it; null when the baseline
      does not hold the function.
  - `improved`: how many baselined functions, still over a critical
    limit, are under the baseline's numbers now (`--update-baseline`
    tightens it).
  - `unneeded`: how many baselined functions are within every critical
    limit now, their entries holding nothing back (`--update-baseline`
    drops them).
  - `gone`: how many baselined functions of a file read are no longer
    there: renamed, moved or deleted.
- `thresholds`: the limits in force, by class of code:
  - `hot`, `normal`, `cold`, `tests`: each class's limits, by metric:
    - `cyclomatic`, `cognitive`, `lines`, `nesting`, `params`,
      `params_weighted`: each metric's limits:
      - `warning`: over this is a warning; null for none.
      - `critical`: over this is critical; null for none.
- `errors`: what went wrong, each making the exit status 2, as stderr
  said it:
  - `path`: the file or argument it is about; empty for neither.
  - `line`, `column`: where in the file, from 1; null when it is not
    about a place in one.
  - `text`: what is wrong.
  - `more`: further lines, such as the functions a name fits.
- `notes`: what is worth knowing and is not wrong, with the same fields
  as `errors`.
- `functions`: the functions listed, worst first; under `--check`, those
  that fail it, unless `--all` or `--function` says otherwise:
  - `path`: the file, as gnarl names it.
  - `line`: the line of the function's name; for a test, of `test`.
  - `end_line`: the line of its closing brace.
  - `column`: the column of its name, from 1, in bytes.
  - `name`: its qualified name, as `Validator.record`.
  - `kind`: `fn` or `test`.
  - `class`: `hot`, `normal` or `cold`, by its file; `tests` for a test
    block, whatever its file.
  - `cyclomatic`: its cyclomatic complexity.
  - `cognitive`: its cognitive complexity, by the rules in
    docs/cognitive.md.
  - `lines`: its logical lines.
  - `nesting`: its nesting depth.
  - `params`: its parameters, a leading self and each Allocator or Io
    left out.
  - `params_weighted`: the same, a type parameter and an anytype counted
    twice.
  - `trips`: the limits it is over, each metric once at its worst:
    - `metric`: the metric.
    - `level`: `warning` or `critical`.
    - `limit`: the limit it is over.

In csv and tsv, the report is the `functions` alone, a row each, with
the columns `path`, `line`, `end_line`, `column`, `name`, `kind`,
`class`, the six metrics, and `over`: each limit passed as
`metric:level:limit`, separated by spaces.

## An explanation

- `schema`, `gnarl`, `errors`, `notes`: as in the report.
- `explanations`: one for each function `--explain` names, in the order
  named:
  - `path`, `line`, `end_line`, `column`, `name`, `kind`, `class`,
    `trips`: as in the report's `functions`.
  - `cyclomatic`: the count and what made it:
    - `value`: the count: 1, and the `adds` of each branch.
    - `branches`: each construct counted, and each that a reader may
      expect to count and does not:
      - `line`, `column`: where it is.
      - `construct`: as written: `if`, `else if`, `inline for`, `and`,
        `orelse`, `catch`, `try`, or `prong` and the prong's values.
      - `adds`: 1, or 0.
      - `why`: why it adds nothing, when it does not.
  - `cognitive`: the count and what made it:
    - `value`: the count: the `adds` of each cost.
    - `costs`: each construct charged, and each that a reader may
      expect to cost and does not, in source order:
      - `line`, `column`: where it is.
      - `construct`: as written: `if`, `else if`, `else`, `inline for`,
        `switch`, `catch`, `and`, `blk:`, `return`, `continue :outer`,
        `errdefer`.
      - `adds`: what it costs, 0 or more.
      - `depth`: how much of `adds` is for the levels it sits in.
      - `why`: why it costs what it does, when its kind and depth do
        not say.
  - `nesting`: the depth and the deepest chain:
    - `value`: the depth.
    - `chain`: the constructs that reach it, outermost first:
      - `line`, `column`, `construct`: as for a branch.
      - `level`: the level it opens, from 1.
  - `lines`: how the lines from the signature to the closing brace
    divide, each in one kind:
    - `value`: the logical lines, the ones that hold code.
    - `span`: all of them.
    - `blank`, `comment`, `closer`: blank, comment-only, and those
      holding only closing brackets and the `;` or `,` after them.
    - `nested`: those of a function declared inside this one.
    - `returned`: those of the type it returns (`return struct {...};`),
      its methods aside: its fields and declarations, which are the
      type's, not code the function runs.
  - `params`: the counts and each parameter:
    - `value`, `weighted`: as the report's `params` and
      `params_weighted`.
    - `each`: each parameter:
      - `name`: its name.
      - `type`: its type as written, or `anytype`.
      - `weight`: what it adds to the weighted count; 0 when it is left
        out of both.
      - `why`: why it is left out, or weighs 2.
  - `comptime_tally`: what of the function runs at compile time, as far
    as its source shows:
    - `items`: each `comptime` block or expression, `inline` loop or
      prong, reflection builtin (`@typeInfo`, `@Type`, `@hasDecl`,
      `@hasField`, `@FieldType`), and comptime or anytype parameter:
      - `line`, `column`, `construct`: as for a branch.
    - `returns_type`: whether it returns a type, whose methods are then
      measured on their own.
    - `unknown`: what the source cannot show, each said in a sentence:
      the members of an inferred error set, how many times a generic
      function is instantiated, what an anytype must provide.
  - `suggestions`: for a function over a limit, at most three ranges
    worth lifting into functions of their own, none overlapping another,
    best first (the one that leaves the larger of the two functions least
    complex, a range a jump leaves after every other), each with the
    fields of `range`; empty for a function within its limits.
  - `regions`: where the numbers come from: the signature, then each
    statement of the body, each construct, logical line and level in the
    region that holds it, so the regions add up to the totals
    (cyclomatic's base 1 aside). A region that holds three quarters or
    more of the cost (cognitive, or cyclomatic when there is none) is
    opened in its place, and so on down: its head (what of it no part
    holds: its keyword, its condition, an `else`), then its parts, a
    switch's prongs, an `if`'s branches, a loop body's statements, a
    level deeper:
    - `first_line`, `last_line`: the lines it spans.
    - `statements`: how many of the body's statements it is; 0 for the
      signature.
    - `cyclomatic`, `cognitive`, `lines`: what it adds to each.
    - `nesting`: the deepest level a construct in it opens; 0 for none.
    - `text`: its first line, as written.
    - `level`: 0 for the signature and the body's statements, 1 for the
      parts of one opened, and so on.
  - `range`: for a function named as `path:A-B`, what lines A to B cost;
    null otherwise:
    - `first_line`, `last_line`: A and B.
    - `cyclomatic`, `cognitive`, `lines`, `nesting`: as for a region.
    - `depth`: how much of `cognitive` is for the depth its structures
      sit at.
    - `leaving`: each `return`, `break` or `continue` in the lines that
      lands outside them (a `return` always does), which moved out with
      them would need reworking:
      - `line`, `column`, `construct`: as for a branch.
    - `needs`: what the lines read that the function declares outside
      them (its parameters, locals and captures), which a function of
      their own would take:
      - `name`: the name.
      - `type`: its type where its declaration writes one; empty if not.
    - `gives`: what the lines assign or declare that is read after them,
      which it would give back:
      - `name`, `type`: as for `needs`.
      - `why`: `assigned in the lines` or `declared in the lines`.
    - `extracted`: the lines moved into a function of their own, about,
      the jumps that leave them aside:
      - `helper`: that function's `cyclomatic`, `cognitive` and
        `nesting`, its structures as much shallower as the lines'
        outermost sat deep, and `params`, how many of `needs` are not an
        Allocator or Io.
      - `rest`: this function's `cyclomatic`, `cognitive` and `lines`
        after, the call a line of its own.

## Files

`--files` lists files rather than functions: what each imports, and
what imports it. An `@import` of a string ending in `.zig` or `.zon` is
a file, relative to the importing one; anything else is a module (`std`,
`builtin`, a build option, a named module), which the source alone
cannot place, and which gnarl lists rather than follows.

- `schema`, `gnarl`, `errors`, `notes`: as in the report.
- `files`: each file read, the most coupled first (the most imports in
  and out, then out, then by path):
  - `path`: as gnarl prints paths.
  - `fan_out`: how many files it imports.
  - `fan_in`: how many of the files read import it.
  - `imports`: the files it imports, each once.
  - `imported_by`: the files read that import it.
  - `modules`: the modules it imports, each once.

In csv and tsv, the columns are `path`, `fan_out`, `fan_in`, and the
lists `imports`, `imported_by` and `modules`, each separated by spaces.

## A diff

- `schema`, `gnarl`, `thresholds`, `errors`, `notes`: as in the report.
- `ref`: the commit the work tree was compared with.
- `files`: how many files the change touched.
- `critical`: how many of the functions touched are over a critical
  limit now; the text says so after the counts, so no `--check` is
  needed to learn it.
- `changes`: how many functions each change came to:
  - `worse`: a number went up, none down.
  - `mixed`: some numbers went up and some down.
  - `added`: new since the commit.
  - `same`: the text changed, the numbers did not.
  - `better`: a number went down, none up.
  - `removed`: gone since the commit.
- `functions`: each function the change touched, worse first, then
  mixed, added, the same, better and removed:
  - `path`, `name`, `kind`, `class`, `trips`: as in the report's
    `functions`; `trips` are those of its numbers after the change.
  - `line`: where it is now; for a removed function, where it was.
  - `change`: one of `changes`' names.
  - `before`, `after`: its numbers at the commit and now, each with
    the report's six metrics; null for an added function's `before`
    and a removed one's `after`.

A function is touched when its own source changed: a function declared
inside it is not its own. In csv and tsv, the columns are `path`,
`line`, `name`, `kind`, `class`, `change`, each metric `_before` and
`_after` (empty for the side a function does not have), and `over`.

## The csv and tsv explanation rows

In csv and tsv, an explanation is a row per item, with the columns
`path`, `line`, `name` (the function's), `metric`, `item`, `at`
(`line:column`, when the item is a place), `value` and `why`. Each metric
has a `total` row but `comptime`, whose rows are each construct counted
(value 1), `returns a type` when it does, and each `unknown` (value 0,
said in `why`); cyclomatic's other rows (`base`, 1, and the branches)
add up to it, as cognitive's (the costs) do, their `why` saying how much
of each is for its depth; nesting's deepest `level` is it, lines has a
row for `span` and each kind, and params a `weighted` row and a row per
parameter (`name: type`, with its weight). Each region has a row per
metric under `region`, `at` its lines (`12-30`) and `why` its first
line; a range has its rows under `range`, the estimate's named
`helper.cyclomatic`, `rest.lines` and so on.

csv quotes a field only when it holds a comma, a quote or a line break,
a quote inside doubled. tsv holds no tab or line break in a field: a
tab, newline, carriage return or backslash is written `\t`, `\n`, `\r`
or `\\`.
