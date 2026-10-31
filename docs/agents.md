---
title: For AI agents
nav_order: 6
---

# Built for AI agents

An agent pays for every row it reads and acts on every number it is
given. gnarl is built for that as much as for people:

- **Economical by default.** The report lists only what is over a limit;
  `--top` and `--function` narrow it further, `--all` widens it.
- **Every number explained.** `--explain` lists each construct counted and
  where, so an agent can aim a refactor and check a count, rather than
  guess at a score.
- **The cut, planned before it is made.** For a function over a limit,
  `--explain` names the ranges worth lifting out; `--explain path:A-B`
  says what a function of those lines would score, the parameters it
  would take, what it would give back, and which jumps leave the lines.
- **One loop.** Explain, lift the first suggestion, `gnarl --diff HEAD`:
  each touched function before and after, a mixed change called mixed
  rather than worse, and a last line saying whether anything is over a
  critical limit now.
- **Nothing to scrape.** `--json` and `--format xml` carry every field and
  everything said on stderr, versioned by a `schema` number.
- **Every message says what to do next.** A failing `--check` names the
  function, the metric, the limit, and the `--explain` to run.

## The skill

The binary teaches its own use:

```sh
gnarl skill                       # print the guide
gnarl skill --install ~/.skills   # write it to ~/.skills/gnarl/SKILL.md
```

The guide covers the loop, the counting rules with measured examples, the
output, the thresholds, the exit statuses, and what catches agents out.
It is embedded in the binary and tested against it: every example in it
is measured as it says, and every metric, format and flag gnarl has is
named in it.

{: .tip }
An agent given only `gnarl skill` and a copy of a function at cognitive
48 brought it to 5, with two helpers, using the regions and range
estimates to choose the cuts before making them. Its estimates matched
the result exactly.
