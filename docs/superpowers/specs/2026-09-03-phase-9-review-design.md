# Phase 9 review: method, decisions, and what was decided against

Date: 2026-09-03. Status: awaiting the maintainer's review.

This document records how the Phase 9 plan in `PLAN.md` was arrived at. `PLAN.md` holds the
work itself — every item, its evidence, and its definition of done — and is the tracker. This
file exists so that the reasoning behind the plan survives the plan being edited.

## Method

Six reviews were run in parallel, each with no sight of the others.

Two were code audits with fixed mandates. One traced every number the interface displays back to
its formula and cross-checked each against the live SQLite database with SQL; it reported eleven
confirmed defects and a list of values checked and found correct. The other searched for code
that exists without earning its place: values computed and never read, settings with no consumer
on some surface, screens that are mostly empty by construction, and the same figure computed by
two routes.

Four were user perspectives, given the concept document, the plan, and rendered screenshots of
the real interface, and asked what the tool should do for them and what they would give up to get
it. Three were the same solo developer in three working modes: running many sessions at once and
afraid of the rate limit; accountable for what the tooling costs; working one project deeply and
wanting to understand their own patterns. The fourth was briefed to argue against additions.

Two of the strongest defects reported by the audits were re-verified by hand against the database
and the source before being accepted: the project breakdown's parent-only token count, and the
hourly chart's double counting after a cumulative regression.

## Baseline measured for the review

A month of usage on this machine, read directly from the transcripts: 5.30 billion tokens over
22 active days; 36.3% of it spent by subagents, ranging from 0% to 82.2% depending on project;
Sonnet and Opus close to an even split; and 28% of the month spent on a single day. These figures
are in `PLAN.md` under *Measured baseline* and are cited by several items.

## Where the reviews agreed

Without seeing each other, all four perspectives named the same things to remove: the subagent
detail sheet, the tool-mix and files-touched panels, the tiles that show the reader's plumbing
(PID, registry word, session id, byte offset, and so on), and the session-history table in its
current form. The maintainer approved all of them.

## Where they disagreed, and how it was resolved

The perspectives split three ways on what the application is: a fuel gauge whose one missing
feature is a projected time to empty; a monthly ledger whose one missing feature is a table by
project and model over an imported month of history; and an end-of-session receipt comparing a
session against the reader's own recent ones. Each was willing to discard what the others valued
most, including the power meter itself.

The maintainer chose the first two together and declined the third. The deciding fact was cost,
not merit: the gauge and the ledger use data that already exists in the store, while the receipt
needs tool counts, file paths and the activity trail to be persisted, none of which currently are.
The receipt is recorded in `PLAN.md` as worth reconsidering once the numbers can be trusted.

On the dollar figure, two perspectives wanted it removed as the wrong unit on a subscription and
one wanted it kept. The maintainer kept it, reframed: it is presented as an API equivalent beside
the plan's price, answering whether the subscription is earning its keep, rather than as an amount
owed.

## Where the dissenter contradicted the maintainer

The reviewer briefed to argue against additions rejected two items the maintainer had asked for
earlier in the same day: deleting stored data by date range, and a Thai/English bilingual mode.
The maintainer chose to park both rather than drop them, and the arguments against each are
recorded in `PLAN.md` so that resuming either means answering the argument rather than forgetting
it. The same reviewer also reduced the error-monitoring request to the two defects inside it,
which are now stage-1 correctness work.

## Order of work

Correctness first, then subtraction, then the gauge, then the ledger. No stage-2 or later work
starts while a number on screen is known to be wrong. The rationale is the one the dissenter gave
and nobody contested: a monitoring tool that cannot be trusted is worse than no tool.

## What this review did not do

It did not verify the running application by hand; every screenshot was rendered offscreen from
fixtures. It did not measure idle CPU. It did not test the popover's new anchoring or the new
session-needs-input notification against a live session. Those remain to be checked before the
uncommitted work from 2026-09-02 and 2026-09-03 is committed.
