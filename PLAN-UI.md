# Claudence UI Plan — matching `Claudence UI.dc.html`

Source design: Claude Design project `fa303afb-16ba-467b-8def-38492f53a961`, file `Claudence UI.dc.html`.

This plan covers what the design asks for, what the machine can actually supply, and the order to build it in. `PLAN.md` tracks M0-M8; this is the follow-on.

---

## Two findings that change the shape of the work

### 1. The app under-reports tokens by 48%

Subagent transcripts are not in the parent transcript. `isSidechain` is false on every record, and there are no `agent-name` records. They live in a fifth data source nobody has read yet:

```
~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.jsonl
~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.meta.json
```

`meta.json` carries `agentType`, `description`, `toolUseId`, `spawnDepth`. The `.jsonl` is an ordinary transcript with full `message.usage` and `tool_use` blocks.

Measured on this repository's own session right now:

```
parent transcript   82.8M tokens
subagents           77.4M tokens
```

**48% of the true total is invisible to the current build.** This is a correctness defect in shipped code, not a missing feature. The design already states the rule — "tokens billed to the parent" — so subagent tokens roll up into the parent session total, with the split shown underneath.

### 2. The idle CPU number needs a warm baseline, and one earlier reading was mine to blame

| Build | Idle CPU | Window | Baseline taken |
|---|---|---|---|
| Original, repeating pulse | 7.14% | 236 s | warm |
| Environment-gated pulse | 3.0%, then 6.2% | 31 s, 92 s | warm, and climbing |
| Repeat removed | 0.064% | 78 s | warm |
| Dashboard + Settings scenes wired | 3.417% | 206 s | **cold, from launch** |
| Same build, re-measured | **0.500%** | 80 s | warm |

The 3.417% was a measurement error, not a regression. That baseline was taken one second after launch, so the window absorbed every one-time cost — SwiftUI scene setup, the store migration, the first cold transcript parse, the first Keychain read and usage fetch — and amortised it across 206 s. Re-measured warm, the same build sits at 0.500%.

Two things follow. First, the dashboard and settings scenes are not the problem. Second, the measurement procedure itself needs stating, because this is the second time a cold baseline has produced a false reading:

```
launch, then WAIT for the first usage fetch to complete
PID=$(pgrep -f "Claudence.app/Contents/MacOS/Claudence" | head -1)
date +%s; ps -o time= -p $PID     # baseline, warm
# ... 5+ minutes ...
date +%s; ps -o time= -p $PID     # idle % = delta cpu / delta wall
```

0.500% still sits exactly on the budget line rather than under it, so U8 re-measured over a longer window before the budget was called met.

**U8's result, and a third way to get this measurement wrong.** The final figure is 0.273% over 600 s, RSS 13.6 MB with a 36 MB peak. An intermediate reading of 1.04% was reported and then withdrawn: it was taken while five agents were writing transcripts and several builds were running, so FSEvents were firing continuously and the app was doing real work throughout. A `sample` of the same process showed the main thread parked in `mach_msg_trap`, and the engine's own counters showed 0.03% at 0.08 refreshes per second. Cold baselines and busy windows are two different ways to produce a number that is not idle CPU; the procedure above guards the first, and only judgement guards the second.

---

## What the design needs that does not exist yet

Grouped by the data work each one requires.

### A. New source: subagents

- Locate `<sessionId>/subagents/`, tail each `agent-*.jsonl` with the same `(path, inode, byteOffset)` cursor the parent uses
- Read `agent-<id>.meta.json` for `agentType`, `description`, `spawnDepth`
- New domain type `AISubagent`: parent session id, agent type, spawned-by tool, own `TokenUsage`, share of parent, record count, tool-call count, activity, status
- Roll subagent tokens into the parent's total; expose the split so no number double-counts
- Same privacy allowlist applies without exception

### B. Per-session detail the parser must start keeping

The parser currently keeps only the newest activity. The design needs five more things, all derivable from records it already reads:

- **Tool mix** — counts per tool name. Verified present: `Bash 143, Agent 10, Write 4, Edit 3, DesignSync 3`
- **Files touched** — recent distinct `input.file_path` values
- **Activity timeline** — last N activities with timestamps, not just the latest
- **Transcript diagnostics** — file size, records parsed, current tail offset
- **Service tier** — `usage.service_tier`

### C. Derived metrics

- Cache-served percentage: `cache_read / billableInput`
- Tokens per hour
- Share of the 5-hour window
- Day-over-day delta ("↑ 18% vs yesterday")
- Daily chart split into input and output rather than one total

### D. Context window — NOT derivable, needs a decision

`message.usage` carries no context limit. Verified keys: `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `output_tokens_details`, `cache_creation`, `server_tool_use`, `service_tier`, `speed`, `inference_geo`, `iterations`.

The used side is computable; the limit is not. Spec section 9.1 forbids asserting a limit the source did not provide, so the design's "61% used · Healthy" meter cannot be honestly filled from the transcript alone. Options are in the decision list below.

### E. Interface

- Session detail overlay, and a subagent drill-down inside it
- Session facts panel: PID, kind, started, duration, git branch, Claude Code version, session id, raw registry status
- Quick actions: Open Terminal, Open Project, Copy Path, and Stop Session behind a confirmation naming the session
- A tooltip system: every metric explains itself on hover, text taken from the design's own `TIPS`, `BREAK_TIPS` and `META_TIPS` tables, which are already written and accurate
- Compact rows that hide duration, rate and sparkline until opened

### F. Settings additions

- Theme: Auto / Light / Dark
- Menu bar: Icon / Icon + % / Count · %
- Usage refresh interval: 30 s / 60 s / 5 m. This is legitimate and does not contradict the event-driven rule: the usage API is the one thing genuinely polled, while sessions stay event-driven
- Show subagents, Compact rows, Live indicators
- Per-event notification switches, with "Permission required" shown disabled and labelled "Unavailable — this state is not derivable yet". The design and the code already agree on this

### G. Visual identity

The design replaces the current monochrome-with-blue theme:

```
background   #F4F1EA   warm cream
accent       #C2664A / #D2775A   terracotta
type         Plus Jakarta Sans + IBM Plex Mono
```

`Theme.swift` is the only file in the target that carries a colour value, verified by grep, so this is a single-file change plus a font decision. System fonts stay the fallback, since bundling fonts is a separate question.

---

## Build order

Correctness first, then the data the interface needs, then the interface.

| Step | Work | Why this position |
|---|---|---|
| **U0** `DONE` | Idle CPU back under budget: 0.491% over 171 s warm. The cost was `PresentationReader`, left in place as documentation after the animation it gated was removed. It observed key and occlusion notifications and pushed a state change through the view tree for a flag nothing read. Deleted. | Every later measurement is meaningless until this is clean |
| **U1** `DONE` | `SubagentLocator` + `SubagentTracker`, rolled into `AISession.combinedUsage`. Verified live: 10 subagents, 77.43M tokens, 41% of the session's true total. | The numbers on screen were 41% low until this landed |
| **U2** `DONE` | Tool mix, files touched, activity timeline, records parsed, service tier. Verified live: `Bash 180  Agent 10  Write 7  DesignSync 3  Edit 3`. Privacy tests still pass unchanged. | Everything in the detail view depends on these |
| **U3** `DONE` | Derived metrics: cache-served, per-hour, day-over-day, input/output split. Two shipped differently from the plan and both are recorded below: the window share, and the context window. | Cheap once U2 exists |
| **U4** `DONE` | Theme on the design's palette and type scale. Dark mode and the Attention/Warning/Critical ramp had to be invented, because the design contains neither. `Theme.swift` is still the only file in the target with a colour value. | Single file; do it before building views on the old tokens |
| **U5** `DONE` | Session detail overlay, subagent drill-down, facts panel, activity timeline, 36 verbatim tooltips, compact rows. | The bulk of the interface work |
| **U6** `DONE` | Appearance, menu bar style, usage refresh interval, show subagents, compact rows, live indicators, per-event notification switches. | Independent of U5 |
| **U7** `DONE` | Open Terminal, Open Project, Copy Path, and Stop Session behind a confirmation naming project and pid. `SIGTERM` only, and liveness re-checked uncached against `procStart` before the signal. | Small, and the destructive one needs care |
| **U8** `DONE` | Idle CPU 0.273% over a 600 s warm window, RSS 13.6 MB with a 36 MB peak, against budgets of 0.5% and 60 MB. Spec section 2 now carries the subagents source as 2.5. | Nothing is done until the budget is met again |

### U1b, which was not in the plan

Two defects found while integrating U1, both of which made shipped numbers wrong:

- **`SubagentTracker` was injected into `MonitorEngine` and never called.** `subagentsBySession` was declared, `subagents(forSession:)` read it, and nothing wrote it. The subagent work reached `--diagnose`, which does its own read, and never reached the application. Every total in the interface was low by the subagent share, which is 41 to 47% on this repository.
- **Read cursors were durable and the totals they correspond to were not.** `MonitorEngine.accumulated` and `SubagentTracker.accumulated` were both in-memory only, seeded empty on launch, while `read_cursors` resumed from SQLite. A session resumed after a relaunch counted only what was appended since, `upsert` wrote that collapsed figure to the session row, and `applyRollup` rewrote the day's rollup downward to match.

Schema version 2 followed: a `subagent_totals` table, and `subagent_*` columns on `sessions` so the daily rollups stop under-reporting by the subagent share. The rollup arithmetic moved to `combinedUsage` on both sides of its subtract-then-add pair.

---

## Decisions taken

1. **Context window** — ship a model context-limit table beside the existing price table, with the same `provenance` and staleness fields. The meter is labelled Estimated. A model absent from the table renders `Context window unavailable`, never a guessed denominator. This keeps spec section 9.1 intact: the limit is disclosed as our table's claim, not as something the transcript said.

2. **Fonts** — system faces (SF Pro, SF Mono), not the design's Plus Jakarta Sans and IBM Plex Mono. No bundling, no licence files, and native feel is a spec requirement. The design will not match exactly on type; the palette and layout will.

3. **Order** — U0 through U8 in sequence. Correctness before appearance.

## Rules that still hold

Nothing in this plan overrides these.

- Never fabricate a number. A metric that cannot be derived renders unavailable.
- Never ship UI for a state with no data source. `PERMISSION` and `ERROR` remain unshipped. `WAITING` no longer does: Claude Code was observed writing the status string itself on 2.1.258 (`busy -> waiting -> busy -> idle`, two-second polling), so it is mapped directly and renders as "Needs you". Before that it fell through the recency fallback and a waiting session was displayed as Idle after sixty seconds.
- The privacy allowlist covers subagent transcripts identically: tool names and file paths only, never command text, prompt text, or results. It was amended on 2026-09-02 to name the four `meta.json` fields the subagent locator decodes, which the code was already reading before the contract permitted them; the argument against keeping `description` is recorded alongside the argument for.
- No repeating animation anywhere in a mounted-but-invisible view.
- Idle CPU under 0.5%, memory under 60 MB, measured as a CPU delta over at least five minutes.

---

## What shipped differently from the plan, and why

### Share of the 5-hour window is a share of what Claudence measured

The plan asked for "share of the 5-hour window". That is not derivable. The usage API reports a percentage consumed and never a capacity, so a session's tokens cannot be divided by the window's size, and computing the size as `measuredTokens / percentUsed` would invent a denominator out of our own incomplete measurement.

What ships is the sum of tokens across sessions active in the last five hours, and each session's share of that local sum. The API name and the doc comment both say so, so nobody can mistake it for a share of the billing window.

### The context window needed a new field before it could be honest

`message.usage` carries no context limit, which the plan already knew. It also turned out that nothing in the pipeline kept the numerator: a context window bounds one request's input, and `AISession.usage` is a running total whose `cache_read` alone reaches tens of millions on a long session. Dividing the cumulative figure by a limit yields percentages in the thousands.

`TranscriptDelta.lastRequestUsage` and `AISession.lastRequestUsage` now carry the newest single record's usage block, kept beside the running sum. The meter is labelled Estimated, because the limit is our table's claim rather than something the transcript said, and a model absent from the table renders unavailable rather than borrowing a neighbour's limit.

### Two things in the design are not reproduced

- **Nine repeating animations**, listed in `Design/UI-CONTRACT.md` section 4.1. One of them, `arcHeadBreathe`, is bound to the menu bar label itself, which is mounted for the life of the process. This is the exact shape of the defect that measured 6.9% of a core against a 0.5% budget.
- **The privacy paragraph**, which reads "One request ever leaves this app". Two do: the usage GET, and a conditional token refresh when the access token has expired. The settings pane discloses both.
