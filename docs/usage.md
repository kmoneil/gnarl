---
title: Usage
nav_order: 3
---

# Usage
{: .no_toc }

1. TOC
{:toc}

## Commands

| Command | Does |
| --- | --- |
| `gnarl <path>...` | The report: each function over a limit, worst first, and a summary. `.` is the current directory; with no path, gnarl prints its usage and reads nothing. |
| `gnarl --explain <function>...` | Why a function scores what it does: each construct and its cost, the regions that carry it, and for a function over a limit, the ranges worth lifting out. |
| `gnarl --explain path:A-B` | What lines A to B cost, and about what moving them into a function of their own would leave: its numbers, its parameters, what it gives back, the jumps that leave the lines. |
| `gnarl --diff <ref>` | Each function the change from commit `<ref>` to the work tree touched, before and after: worse, mixed, added, the same, better, removed. With no path, the whole work tree. |
| `gnarl --check <path>...` | Exit 1 if a function is over a critical limit, or, held to a baseline, new or worse. Lists only what fails, so a pass prints nothing. |
| `gnarl --update-baseline <path>...` | Write `complexity.baseline`: each function now over a critical limit, with its numbers. |
| `gnarl --files <path>...` | Each file's fan-out, fan-in and the modules it imports, the most coupled first. |
| `gnarl skill` | Print the guide an AI agent needs; `--install <dir>` writes it to `<dir>/gnarl/SKILL.md`. |

## Naming a function

`--explain` and `--function` take a function as:

- `path:line`, as the report prints it, or any line inside the function;
- `path:A-B`, lines A to B, for `--explain`: the innermost function around
  them, and what those lines cost;
- its name, `Validator.record`, or the end of it, `record`, looked for in
  the paths given.

A `path:line` needs no path besides: gnarl reads only that file.

## Options

| Option | Does |
| --- | --- |
| `--exclude <path>` | Skip this file or directory, named as gnarl prints paths: relative to the current directory. May be given more than once. |
| `--no-ignore` | Read what git ignores too. By default, in a git work tree, what git ignores is not read. |
| `--config <file>` | Read the classes and thresholds from this file rather than `complexity.zon`. |
| `--baseline <file>` | The baseline `--check` holds to, or `--update-baseline` writes, rather than `complexity.baseline`. |
| `--all` | List every function, within its limits or not. |
| `--top <n>` | List at most the n worst. |
| `--function <function>` | List only this function, whatever its numbers. May be given more than once. |
| `--format <format>` | `text` (the default), `md`, `json`, `xml`, `csv` or `tsv`. |
| `--json` | The same as `--format json`. |

Hidden files and directories, `zig-out` and `zig-pkg` are skipped unless
named outright.

## Formats

`text` is a table for a terminal; `md` the same as Markdown, for a pull
request comment. `json` and `xml` carry every field and everything said
on stderr, with a `schema` number that goes up only when a field is
renamed, moved or taken away. `csv` and `tsv` are a header and a row per
function, or per explained item. [Output formats](output.md) lists every
field.

```sh
gnarl --diff origin/main --format md   # paste into a review
gnarl --json src | jq '.functions[0]'  # feed a dashboard
```

## Exit status

| Status | When |
| --- | --- |
| 0 | Every file was read, and with `--check`, nothing fails it. |
| 1 | `--check` found what does. |
| 2 | A usage error, a configuration or baseline that cannot be used or written, a path that could not be read or holds no `.zig` file, a file that does not parse, or an `--explain` that names no function or more than one. |

The files that could be read are reported either way.
