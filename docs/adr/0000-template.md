# ADR NNNN: <short, decision-focused title, e.g. "Use X instead of Y for Z">

## Status

Proposed <!-- Proposed | Accepted | Rejected | Superseded by ADR NNNN -->

## Context

What problem or requirement forced a decision? Describe the situation as it
was found — existing code/config referenced by file and line where relevant,
what constraint made the default/obvious approach not work, and what was
actually tried before landing here (if anything). State problems concretely
enough that someone with no memory of the discussion can see why a decision
was necessary at all.

## Decision

The choice that was made, stated directly and concretely (a config shape, a
component, a mechanism) — not a restatement of the context.

## Consequences

**Positive:**

- What this decision buys, specifically — not "simpler" in the abstract, but
  what risk/complexity/work it actually removes.

**Negative / accepted tradeoffs:**

- What this decision gives up or still leaves unresolved. Every real tradeoff
  belongs here, even ones that make the decision look less clean — a decision
  record that only lists upsides isn't trustworthy for someone deciding
  whether to revisit it later.

## Alternatives considered

- **<Alternative>**: why it was rejected — tie the reason back to the Context,
  not a generic downside.
- **<Alternative>**: same. Include options that were seriously considered and
  ruled out, not just the one that won; if an alternative was only rejected
  for now (not ruled out permanently), say so and note what would revive it.
