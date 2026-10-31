---
title: Home
nav_order: 1
permalink: /
---

# gnarl

**Find the gnarled code in your Zig. See exactly why it is gnarled. Cut it
with a plan, and keep it cut.**
{: .fs-6 .fw-300 }

gnarl measures every function in a Zig codebase (cyclomatic and cognitive
complexity, logical lines, nesting depth, parameters) and then does the
part other metrics tools leave to you: it explains each number construct
by construct, points at the lines worth lifting out, predicts what the
refactor will leave before you make it, and holds the line in CI so the
debt you have cannot grow.

[Get started](#get-started){: .btn .btn-primary .mr-2 }
[See it work](walkthrough.md){: .btn .mr-2 }
[GitHub](https://github.com/kmoneil/gnarl){: .btn }

- **Zig's rules, not C's.** A `try` is not a branch, `catch unreachable`
  has no other path, and a flat `switch` of forty prongs is one decision
  to a reader.
- **Every number explained.** Each construct counted, where it is, what
  it costs, and how much of that is depth.
- **Where to cut, and what the cut leaves.** The statements that carry
  the cost, the ranges worth lifting out, and for any range: the new
  function's numbers, its parameters, what it gives back, and the jumps
  that would need reworking.
- **A ratchet for CI.** Freeze the debt you have; fail only what is new
  or worse.
- **Syntax only, and fast.** The compiler's own parser, `std.zig.Ast`: no
  build, no configuration, all of Zig's standard library in a fifth of a
  second.

## A quick look

```console
$ gnarl .
cyclomatic  cognitive  lines  nesting  params  weighted  location     function
      11!        33!!   23        5!      4         4    tally.zig:7  tally

1 function in 1 file: 1 over a critical threshold (!!), 0 more over a warning one (!).
```

```console
$ gnarl --explain tally .
...
worth lifting out, best first; --explain path:A-B says more of each:
  24-34  a function of cyclomatic 5, cognitive 8, params 4; tally keeps cyclomatic 7, cognitive 19; gives back total
  15-19  a function of cyclomatic 2, cognitive 2, params 2; tally keeps cyclomatic 10, cognitive 27
```

`!` is over a warning limit, `!!` over a critical one. The
[walkthrough](walkthrough.md) takes this function from report to
refactor.

## Get started

```sh
brew install kmoneil/tap/gnarl   # macOS, Linux
```

Or take a binary for Linux, macOS or Windows from the
[latest release](https://github.com/kmoneil/gnarl/releases/latest), each
with its `SHA256SUMS` line and a build-provenance attestation, or build it
from source with Zig 0.17:

```sh
git clone https://github.com/kmoneil/gnarl
cd gnarl
zig build -Doptimize=ReleaseFast
cp zig-out/bin/gnarl ~/.local/bin/   # or anywhere on your PATH
```

Then, in any Zig project:

```sh
gnarl .                         # what is over a limit, worst first
gnarl --explain <function> .    # why, construct by construct, and where to cut
gnarl --diff HEAD               # after a change: what it did, function by function
gnarl --check .                 # in CI: exit 1 on what is new or worse
```

{: .tip }
Run `gnarl skill` to print the guide an AI agent needs to work with gnarl;
`gnarl skill --install <dir>` writes it where your agent reads skills.
