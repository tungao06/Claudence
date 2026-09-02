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

0.500% still sits exactly on the budget line rather than under it, so U8 re-measures over a longer window before the budget is called met.

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
| **U3** | Derived metrics: cache-served, per-hour, window share, day-over-day, input/output split | Cheap once U2 exists |
| **U4** | Theme change to the design's palette and type scale | Single file; do it before building views on the old tokens |
| **U5** | Session detail overlay, subagent drill-down, facts panel, tooltips | The bulk of the interface work |
| **U6** | Settings additions | Independent of U5 |
| **U7** | Quick actions, Stop Session behind confirmation | Small, and the destructive one needs care |
| **U8** | Re-measure idle CPU and memory against budget; update `Claudence_CLAUDE.md` section 2 with the subagents source | Nothing is done until the budget is met again |

---

## Decisions taken

1. **Context window** — ship a model context-limit table beside the existing price table, with the same `provenance` and staleness fields. The meter is labelled Estimated. A model absent from the table renders `Context window unavailable`, never a guessed denominator. This keeps spec section 9.1 intact: the limit is disclosed as our table's claim, not as something the transcript said.

2. **Fonts** — system faces (SF Pro, SF Mono), not the design's Plus Jakarta Sans and IBM Plex Mono. No bundling, no licence files, and native feel is a spec requirement. The design will not match exactly on type; the palette and layout will.

3. **Order** — U0 through U8 in sequence. Correctness before appearance.

## Rules that still hold

Nothing in this plan overrides these.

- Never fabricate a number. A metric that cannot be derived renders unavailable.
- Never ship UI for a state with no data source. `WAITING`, `PERMISSION` and `ERROR` remain unshipped.
- The privacy allowlist covers subagent transcripts identically: tool names and file paths only, never command text, prompt text, or results.
- No repeating animation anywhere in a mounted-but-invisible view.
- Idle CPU under 0.5%, memory under 60 MB, measured as a CPU delta over at least five minutes.
