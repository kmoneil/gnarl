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
  - `improved`: how many baselined functions are under the baseline's
    numbers now (`--update-baseline` tightens it).
  - `gone`: how many baselined functions of a file read are no longer
    there: renamed, moved or deleted.
- `thresholds`: the limits in force, by class of code:
  - `hot`, `normal`, `cold`: each class's limits, by metric:
    - `cyclomatic`, `lines`, `nesting`, `params`, `params_weighted`:
      each metric's limits:
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
- `functions`: the functions listed, worst first:
  - `path`: the file, as gnarl names it.
  - `line`: the line of the function's name; for a test, of `test`.
  - `end_line`: the line of its closing brace.
  - `column`: the column of its name, from 1, in bytes.
  - `name`: its qualified name, as `Validator.record`.
  - `kind`: `fn` or `test`.
  - `class`: `hot`, `normal` or `cold`.
  - `cyclomatic`: its cyclomatic complexity.
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
`class`, the five metrics, and `over`: each limit passed as
`metric:level:limit`, separated by spaces.

## An explanation

- `schema`, `gnarl`, `errors`, `notes`: as in the report.
- `explanations`: one for each function `--explain` names, in the order
  named:
  - `path`, `line`, `column`, `name`, `kind`, `class`, `trips`: as in the
    report's `functions`.
  - `cyclomatic`: the count and what made it:
    - `value`: the count: 1, and the `adds` of each branch.
    - `branches`: each construct counted, and each that a reader may
      expect to count and does not:
      - `line`, `column`: where it is.
      - `construct`: as written: `if`, `else if`, `inline for`, `and`,
        `orelse`, `catch`, `try`, or `prong` and the prong's values.
      - `adds`: 1, or 0.
      - `why`: why it adds nothing, when it does not.
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
  - `params`: the counts and each parameter:
    - `value`, `weighted`: as the report's `params` and
      `params_weighted`.
    - `each`: each parameter:
      - `name`: its name.
      - `type`: its type as written, or `anytype`.
      - `weight`: what it adds to the weighted count; 0 when it is left
        out of both.
      - `why`: why it is left out, or weighs 2.

In csv and tsv, an explanation is a row per item, with the columns
`path`, `line`, `name` (the function's), `metric`, `item`, `at`
(`line:column`, when the item is a place), `value` and `why`. Each metric
has a `total` row; cyclomatic's other rows (`base`, 1, and the branches)
add up to it, nesting's deepest `level` is it, lines has a row for
`span` and each kind, and params a `weighted` row and a row per
parameter (`name: type`, with its weight).

csv quotes a field only when it holds a comma, a quote or a line break,
a quote inside doubled. tsv holds no tab or line break in a field: a
tab, newline, carriage return or backslash is written `\t`, `\n`, `\r`
or `\\`.
