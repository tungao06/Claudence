# Claudence — Implementation Plan

Status tracker from empty repository to working application.

Spec: `Claudence_CLAUDE.md`. Operational summary: `CLAUDE.md`.

**Estimate:** 10 to 11 working days. Usable after M2, feature-complete against the concept after M4.

Update the checkboxes as work lands. A milestone is done only when every line of its Definition of Done passes.

---

## Decisions locked

| Area | Decision | Consequence |
|---|---|---|
| Stack | Swift 6.3.3 + SwiftUI `MenuBarExtra` | native menu bar, meets the CPU and memory budget |
| Build | Swift Package Manager, manual `.app` assembly | Xcode is not installed; only Command Line Tools |
| Usage source | Keychain OAuth token + `api.anthropic.com/api/oauth/usage` | pulls on demand, does not contend for the status line slot |
| Distribution | Notarized `.dmg`, self-distributed, friends first (decided 2026-09-03; was single-machine) | Apple Developer account; no App Store, no auto-update, no telemetry, no CI |
| Privacy depth | Metadata plus file path; command as SHA256 only | activity labels stay at tool-name granularity for Bash |

Verified environment: Swift 6.3.3, macOS 26.6.2, SDK 26.5, Claude Code 2.1.257.

---

## M0 — Skeleton that runs  `DONE`

**~4 hours**

- [x] `git init`, `.gitignore` for `.build/`, `*.app`, `.DS_Store`
- [x] `Package.swift` with an executable target
- [x] `Info.plist` with `LSUIElement = 1` so no Dock icon appears
- [x] `make app` script: `swift build -c release` then assemble the `.app` bundle
- [ ] Create one self-signed code signing identity and sign every build with it — `Scripts/make-signing-cert.sh` is written but not yet run; it needs the login keychain password, so the user runs it once. Builds are ad-hoc signed until then.
- [x] `MenuBarExtra` showing a static icon plus a working Quit

**Definition of done**

- Double-clicking the `.app` puts an icon in the menu bar
- Quit works and leaves no process behind
- Rebuilding and relaunching does **not** re-prompt for Keychain access — pending, blocked on the signing identity above

**Measured at M0, corrected after integration:** the 69 MB first reported was taken seconds after
launch and included bootstrap memory not yet released. The settled figure for the full application
with both adapters live is **29 to 32 MB**, comfortably inside the 60 MB budget. The earlier number
was wrong, not the budget.

**Idle CPU is NOT within budget.** Measured as a delta rather than the lifetime average `ps` reports:
16.84 s of CPU over 236 s of wall time is **7.14%**, against a 0.5% budget. This is a real defect,
not a budget that needs raising. Tracked as M-perf below.

**Why signing is here and not at M4:** an ad-hoc signature changes every build, so macOS treats each build as a new application and re-prompts for Keychain access. One stable certificate makes "Always Allow" persist.

---

## M1 — Session discovery  `DONE`

**~1 day.** This is the product's core value.

- [x] `SessionRegistryAdapter` reading `~/.claude/sessions/*.json`
- [x] Filter to `kind == "interactive"`
- [x] Liveness check: `kill(pid, 0)` **and** matching `procStart`
- [x] Reap stale files left by crashed sessions
- [x] FSEvents watcher on the directory, 250 ms debounce
- [x] Map to the `AISession` domain model
- [x] Popover lists sessions: name, working directory, status, duration
- [x] **Enumerate the real set of `status` values by observation** and record them in the spec

**Definition of done**

- Two concurrent Claude Code sessions render as two rows with correct working directories
- Closing one removes it within 1 second
- A stale registry file is never displayed
- No use of `ps` for enumeration

**Open question resolved here:** only `busy` has been observed. Section 6 of the spec stays blocked until the full set is known.

---

**Verified live.** `Claudence --diagnose` on this machine reported 3 registry records, 2 live
interactive sessions with correct working directories and PIDs, `kinds: bg=1 interactive=2`,
`status values: busy`, and 0 unparsed `procStart`. 37 tests pass.

## M2 — Token ingestion  `DONE`

**~1.5 days.** After this the application is genuinely useful.

- [x] Map `sessionId` to its transcript, confirming by reading `sessionId` inside the file rather than trusting the path slug
- [x] SQLite schema: sessions, usage samples, file offsets, daily rollups
- [x] Incremental tail storing `(path, inode, byteOffset)`; reset the offset when the inode changes
- [x] Parse `type == "assistant"` records into `TokenUsage`
- [x] Aggregate per session and per day
- [x] Token energy bar and breakdown in the popover

**Definition of done**

- Totals land within 2% of Claude Code's own accounting
- A 12 MB transcript re-scans in under 50 ms
- Killing the app mid-session and restarting resumes from the stored offset without double-counting

**Locked before any code:** `billableInput = freshInput + cacheCreation + cacheRead`, `total = billableInput + output`. Cache is always displayed separately.

---

**Verified live.** A cold read of a live session produced 280 records with 0 skipped in 32 ms.
The next run of the same session read only 3 new records, proving the offset resumed rather than
re-parsing. Measured on a 12 MB fixture: cold read 114 ms, idle re-scan 0.031 ms against a 50 ms
budget. Cross-checked against a real 42 MB transcript: token totals were byte-identical to an
independent reference implementation.

**Correction to the spec:** real transcripts reach 42 MB, not the 12 MB recorded in section 2.3.
The offset strategy holds, but any bounded-read assumption should use the larger figure.

## M3 — Activity detection  `DONE`

**~1 day**

- [x] Parse `content[]` `tool_use` entries into `{name, input.file_path}`
- [x] Hash `input.command` with SHA256; never retain the string
- [x] Map to human phrasing: `Edit` plus a path becomes "Editing Menu.tsx"
- [x] Bash renders as "Running a command" — no command echo
- [x] Privacy allowlist implemented as a filter in the parser

**Definition of done**

- A test fails if the parser emits `content[].text`, any tool result, file history content, or a raw command string
- Every active session shows a current activity or an honest blank

**This test is the privacy contract.** Without it section 3 of the spec is a promise rather than a property.

---

**Verified live.** Both live sessions reported an activity: "Running a subagent" and
"Running a command". 7 privacy tests pass; they walk the entire value graph with `Mirror` and
assert nine sentinel strings appear nowhere, and that no property in the graph is named `text`,
`thinking`, `toolUseResult`, `snapshot`, `attachment`, or `command`.

**Tool names corrected against 2.1.257:** the agent-spawn tool is now `Agent`, not `Task`, and
`TodoWrite` was replaced by `TaskCreate` / `TaskUpdate`. All are mapped, old names included, so a
transcript from an older build still reads.

## M4 — Usage limits  `CODE DONE, NOT VERIFIED LIVE`

**~1 day**

- [x] Read the OAuth token from Keychain (`service = "Claude Code-credentials"`), falling back to `~/.claude/.credentials.json`
- [x] Refresh via `POST platform.claude.com/v1/oauth/token` when expired
- [x] `GET api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`
- [x] Parse flat windows plus the `limits[]` scoped array, enumerating model scopes rather than hard-coding names
- [x] Domain allowlist enforced inside the request helper, blocking off-allowlist redirects
- [x] 60 s cache, backoff on 429, serve cached values while backing off

**Definition of done**

- 5h and 7d windows render with reset times
- Network down renders `Usage unavailable`, no crash, no hang
- Keychain access denied renders `Usage unavailable` and the rest of the app keeps working
- An expired token refreshes without user action
- The token appears in no log, no cache file, and no view

---

**36 tests pass**, including: a request to `evil.example.com`, `api.anthropic.com.evil.example`,
`api-anthropic.com` and `localhost:8080` reaches the transport exactly 0 times, so the
`Authorization` header is never even constructed for an off-allowlist host; a redirect to a
disallowed host is refused; and the credential type renders as `<redacted>` across nine different
description paths.

**Two things are NOT verified and must not be treated as working:**

1. **The live path has never run.** `Claudence --diagnose` hangs for 20 seconds on the Keychain
   read, because macOS puts an approval dialog on screen and `SecurityAgent` waits for a click.
   Confirmed by observing the process. This is exactly the failure the M0 signing identity
   prevents; approving once under an ad-hoc signature does not persist across a rebuild.

2. **The OAuth `client_id` is a guess.** `UsageClient.swift` carries
   `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, taken from published sources and never confirmed
   against the endpoint. It is used only on the refresh path, when the access token has expired.
   If it is wrong the failure is `Usage unavailable`, not a crash, but 5h and 7d would silently
   stop working once the token ages out. Confirm before trusting.

## M5 — Power meter UI  `BUILT, NOT SEEN`

**~2 days**

- [x] Power bar, energy ring, token bar, sparkline
- [x] Semantic color tokens; no hex in views
- [x] Menu bar rendering under 60 pt, session count opt-in
- [x] Honor Reduce Motion
- [x] Empty and degraded states for every panel

**Definition of done**

- Every state pairs a glyph with text; nothing depends on color alone
- Menu bar width stays under 60 pt in all states
- With Reduce Motion enabled, no animation runs

---

Nine components built and composed into the live popover. `Theme.swift` is the only file in the
target containing an `NSColor`, a component literal, or any `Color` constructor, verified by grep,
so the semantic-token rule is structural rather than a convention.

**Not visually verified.** There is no Xcode on this machine, so there are no canvas previews and
no screenshots; `#Preview` does not compile and `PreviewProvider` is used instead. Layout is
argued from code, not seen. A human should open the popover and check it before M5 is called done.

## M6 — Persistence and history

**~1.5 days**

- [ ] Daily rollups
- [ ] Grouping by project
- [ ] 7 and 30 day graphs
- [ ] Cost estimation from a per-model price table, always labeled "Estimated"
- [ ] A model missing from the price table renders `Cost unavailable`, not zero

---

## M7 — Notifications

**~1 day**

- [ ] `UNUserNotificationCenter` integration and permission request
- [ ] Usage at 90%
- [ ] Session completed
- [ ] Session failed
- [ ] Deduplicate by session and event type; rate limit per session

Permission-required notifications ship only if M1 proved that state derivable.

---

## M8 — Polish and accessibility

**~1.5 days**

- [ ] VoiceOver labels on every indicator
- [ ] Keyboard navigation
- [ ] Launch at login via `SMAppService`
- [ ] Settings, including the plain-language privacy disclosure
- [ ] Empty states: Claude Code absent, zero sessions, Keychain denied, network down
- [ ] Verify the performance budget: idle CPU under 0.5%, resident memory under 60 MB, cold start under 1 s

---

## M-perf — Idle CPU regression  `CAUSE FOUND, FIX IN PLACE, RE-MEASURING`

The application burned 7.14% CPU while idle, 14x the budget in spec section 13. Measured with two
`ps -o time=` samples 236 s apart on the signed release build, with two live Claude Code sessions
present. `ps -o %cpu` reports a lifetime average and hides this entirely.

- [x] Instrument how often `refreshSessions()` runs and what triggers it
- [x] Determine whether the cost is FSEvents churn, transcript reads, or SwiftUI re-rendering
- [x] Fix the cause
- [ ] Re-measure by CPU delta over 5+ minutes with live sessions present

**The cause was none of the filesystem candidates.** It was SwiftUI, and specifically one animation.

`MenuBarExtra(style: .window)` builds its popover content at launch and keeps it mounted in a
window that is merely ordered out when dismissed. `StatusIndicator` pulses a running session with
`.repeatForever(autoreverses: true)`, and a repeating animation on a mounted view drives a layout
and a display-list pass at the screen's refresh rate for the life of the process, visible or not.
Profiled on the release build with the popover never opened and zero filesystem events in the
window: **6.9% of a core**, essentially all of it under
`NSDisplayCycleFlush -> NSHostingView.layout -> ViewGraph.render`, ending in `-[CALayer setOpacity:]`.

**Three fixes were tried. Only the third works.**

1. *Unmount the popover subtree when not presented*, keyed on `NSWindow.isVisible`. Rejected: the
   signal turns true on its own during a frame update, the popover mounted itself, and the cost
   returned for the rest of the session.
2. *Keep the tree mounted, publish presentation through the environment, let animated components
   suppress themselves*, keyed on `isKeyWindow || occlusionState.contains(.visible)`. This is the
   version that was committed first, and measurement killed it: 3.0% over 31 s, then 6.2% over 92 s.
   The number climbing with the window length is the signature of the flag latching true and staying
   there. Occlusion reports a dismissed menu bar window as visible.
3. **Shipped: remove the repeat.** `Theme.Motion.pulse` is a single 0.55 s dip, and `StatusIndicator`
   fires it once per change of an `activityToken` (`session.lastActivityAt`). An idle popover costs
   nothing by construction rather than by a flag being correct, and the motion now says "something
   just happened", which is closer to what the spec asks motion to mean.

The environment key from attempt 2 is kept, unused by `StatusIndicator`, because it documents the
hazard for whatever animates next. It is not load-bearing.

Two supporting changes stand on their own regardless:

- `MonitorViewModel` splits `menuBarState` and `usageState` out of `snapshot`, so the label — the
  only thing on screen while the popover is closed — is not invalidated by session token churn.
- Assignments are guarded on inequality, because `@Observable` invalidates on assignment rather
  than on change.

**The monitoring engine was never the problem.** `Claudence --diagnose --counters 60` on this
machine: 0 FSEvents callbacks, 0 discoveries, 0 transcript reads, 0.00% CPU over a full minute.
Every candidate involving the filesystem was wrong, and the instrumentation is what proved it.

**Definition of done:** idle CPU under 0.5% measured by CPU delta over at least 5 minutes with live
sessions present.

---

## Phase 9 — Correct the numbers, then subtract, then extend

Rewritten 2026-09-03 after a six-way review: two independent code audits, and four user
perspectives that were run in isolation from each other and from the maintainer. The audits
produced eleven confirmed defects; the perspectives disagreed sharply about what the application
is for, and the disagreement was resolved by decision rather than by consensus.

**The finding that orders this phase.** The parsing and storage layers are sound. Every audit of
them came back clean: one definition of the token formula with nothing recomputing it,
`daily_rollups` reconciling exactly against `parent + subagent` for all sixteen sessions,
`subagent_totals` reconciling exactly against the session columns, a cost estimator that refuses
to borrow a price for an unknown model, a context meter that uses last-request usage rather than
the cumulative total, and a severity ramp that agrees with its thresholds at every boundary.
Every defect below lives in the layer above: the aggregates and the derived metrics.

### Measured baseline

A month of real usage on this machine, read from `~/.claude/projects` on 2026-09-03. These
figures decide several arguments below, so they are recorded rather than summarised.

```
22 active days, 219 transcripts, 242 MB, largest single file 19.9 MB

combined            5,297,171,104 tokens
  parent            3,373,150,914
  subagent          1,924,020,190      36.3% of the total

subagent share by project
  hr-leave-management        1.56 B    82.2%
  e-claim-api-nest           1.05 B    10.0%
  Claudence                   846 M    41.9%
  Engate-portal                88 M     0.0%

by model
  claude-sonnet-5            2.95 B
  claude-opus-5              2.25 B

2026-09-01 alone             1.51 B    28% of the month in one day
```

Three consequences. Subagent share is not a constant — it ranges from 0% to 82% by project, so
any figure that drops subagents is wrong by a factor that changes per row. Sonnet and Opus are
close to an even split, so a token count that does not separate them cannot be compared across
projects. And usage is extremely bursty, which is what makes a rate-limit projection worth
building.

---

## Stage 1 — Correctness  `RE-OPENED 2026-09-03 BY ITS OWN AUDIT`

Every item in this stage is closed, and four defects of one class were found by the work rather
than by the audits: 9.5b in the engine, 9.5c in the subagent tracker, 9.5d in the transcript
reader and 9.5e in the menu bar header. Three of the four wrote a wrong figure to disk. The
common shape is a store read whose failure is indistinguishable from an empty result, and the
common fix is that a read now reports its own outcome and a caller that did not get an answer
skips the pass rather than substituting a default.

Two operational notes from the run, recorded because they will recur.

The machine ran out of disk. Eight concurrent agents each building into their own
`--scratch-path`, as CLAUDE.md requires for concurrency, cost several gigabytes apiece on a disk
that was already 93% full, and at zero bytes free every tool that needs a temporary file fails,
including the ones that would delete the build directories. Recovery was possible only through a
tool that streams. Concurrency in this repository is bounded by disk, not by CPU: two agents at
a time, and clear the scratch paths between waves.

The executable target is not unit-testable. `ClaudenceCoreTests` does not depend on it, so every
change to a view was verified by reading its call sites. That is why three of the stage 1 items
found defects the audits had not, and it is the argument for leaning on `RenderShots` in stage 2.5
rather than adding a test target late.

### 9.15 What the stage's own audit found  `OPEN 2026-09-03`

The seventeen commits were audited as a whole before stage 2 started, against the promise that
every number the application prints is either derived or absent. The promise did not hold, and
two of the findings are the same class of defect the stage was written to remove, relocated one
layer up by the fixes themselves.

- [ ] **Blocker.** `MonitorEngine.swift:218`: when the subagent tracker withholds its answer it
      returns an empty array, and the engine sets `subagentUsage = .zero` and upserts. The
      collapse the tracker fix prevents is written by its caller instead. The tracker test asserts
      only that the tracker writes nothing; nothing drove the engine over the skip.
- [ ] **Blocker.** `SubagentTracker.swift:207`: a failed directory listing is not distinguished
      from a session with no subagents, so the same zero is written down, and `byParent` is
      clobbered with the empty set on that pass.
- [ ] **Major.** The displayed burn rate never recomputes while a session is quiet, because a
      quiet session produces no filesystem event: the registry file is not heartbeat-updated and
      the transcript stops growing. 9.4 corrected the model and not the surface. Measured during
      the audit: a registry file untouched for eight hours beside a live figure on screen.
- [ ] **Major.** `ClaudenceStore.swift:662`: `rollupBuckets` walks with an unbounded range, so
      every session's first sample counts in full and a session live at launch puts its whole
      pre-observation total on the launch day. The three callers of the walk disagree by exactly
      that quantity.
- [ ] **Major.** `upsert` subtracts a session's previous total from its start day, which the
      repair has just spread across several days, so the next write re-collapses it and a session
      that ends between repairs keeps the wrong day permanently. The repair also has no trigger
      for a session that predates today and then exits.
- [ ] **Major.** `MonitorViewModel.swift:41`: `storeHealth` is captured once at launch, so a store
      that degrades later never reaches the interface while every read silently skips.
- [ ] **Minor.** `dailyTotals` has no upper bound on `day`, so a rollup row dated in the future is
      summed into today, and `lastActivityAt` takes an unclamped transcript timestamp.
- [ ] **Minor.** `rollupBuckets` writes a `session_count` row for a zero-usage session, so a day
      whose only row is such a session returns a measured-looking zero to the chart and to
      `DayOverDayDelta`.
- [ ] **Minor.** `unansweredQueries` is one global counter bracketed by three concurrent callers,
      so an unrelated failing query can make an answered read look unanswered. Harmless once the
      blockers above are fixed, because a spurious skip is retried, but it is a false negative in
      a mechanism the whole stage now rests on.
- [ ] **Minor.** `MonitorEngine.swift:255` records a session as upserted whether or not the write
      succeeded, so a failed write is never retried.
- [ ] **Minor.** Nothing prunes `usage_samples` and the only index is `(session_id, sampled_at)`,
      while `usageSamples(in:)` filters on `sampled_at` alone. Measured cadence is 17 to 36 samples
      an hour per active session, so a month is tens of milliseconds per repair and a year is
      about half a second, above the idle budget at a 60 second throttle. The throttle is
      defensible now and not for a year of history; 9.12 imports that history.

Nothing in stage 2 or 3 starts until this stage is done. The application currently prints
several figures that are confidently wrong, and a monitoring tool that cannot be trusted is
worse than none.

### 9.1 The project breakdown contradicts itself inside one row  `DONE 2026-09-03`

**~0.5 day**

`AnalyticsService.swift:344` accumulates `usage += session.usage`, which is parent-only, while
the cost on the same `ProjectSummary` goes through `CostEstimator.swift:118`, which prices
`session.combinedUsage`. The tokens cell excludes subagents; the cost cell one column to its
right includes them.

Measured against the live database:

```
project        tokens rendered   subagents omitted      true total   understated by
claudence-99      149,792,426         334,207,592     484,000,018            3.2x
claudence-97      197,889,320          11,792,545     209,681,865            1.06x
```

The ordering and the relative bar are worse than the cell. `claudence-99` is genuinely the
busiest project and is drawn second, at 76% of the bar, behind a project two thirds its size;
every project without subagents is over-weighted against every project with them.

This is the one aggregate in the codebase that dissents. `daily_rollups`, the sessions table,
`recentShare` and the usage samples all use `combinedUsage`, and `ClaudenceStore.swift:491`
carries a comment warning that a repair using the parent-only figure "would quietly rewrite
history down by every session's subagent spend".

- [x] `usage += session.combinedUsage`
- [x] Test: a project whose sessions have subagents reports the combined figure, and sorts on it

### 9.1b Context usage shows "unavailable" while the number is in hand  `DONE 2026-09-03`

**~0.5 day**

The context well has two inputs: the last request's `billableInput`, which is the size of the
context that request carried, and the model's limit from `ContextWindowTable`. Today it draws a
meter only when both exist, and otherwise says `Context window unavailable` — even when the
first input is present and only the limit is missing. On this machine that is the maintainer's
own sessions: `claude-opus-5[1m]` is not in the table, so every one of them reads unavailable
while the request size sits in memory.

The maintainer's rule for it: if there is a ceiling, draw the bar against it; if there is not,
still say how much context is in use, with no bar and no percentage, and never a guessed limit.

- [x] A third state for `ContextWell`: amount known, limit unknown. Renders the figure
      (`261k in the last request`) and says the limit is not in the table, with no meter
- [x] `[1m]`-suffixed model ids resolve to a 1,000,000 limit. The suffix is the published name
      of the 1M-context variant, so this is a read of the model id rather than a guess
- [x] The reason text distinguishes "no request read yet" (nothing to show) from "limit unknown"
      (something to show), which are currently one sentence

Three things the item did not anticipate. The precedence was wrong as well as the state: the
reason checked table coverage before it checked whether a request had been read, so an unknown
model with nothing read blamed the model. The missing numerator now wins. Only the exact `[1m]`
marker is read, and it is honoured even when the base id is absent from the table, on the item's
own reasoning that the suffix is a read of the id rather than a guess. And `ModelPricing` was
deliberately left alone: the 1M-context variant bills at a different rate, so borrowing the base
model's prices would fabricate money. Cost for such a session stays unavailable, which is a gap
Stage 4 should close with the published 1M rates rather than by aliasing.

### 9.2 The hourly chart counts tokens twice after a cumulative regression  `DONE 2026-09-03`

**~0.5 day**

`usage_samples` is not monotonic. Thirteen downward steps exist in the current database.
`AnalyticsService.increase(from:to:)` clamps each field at `max(0, later - earlier)`, so the fall
contributes zero and the climb back to the previous level is then counted a second time.

```
session     drawn by the chart     actually spent      overcount
6ff2ff43           649,468,504        483,706,748     +165.8 M  (+34.3%)
21d26a51            20,761,085          9,221,707        2.25x
```

The comment at `AnalyticsService.swift:301` describes the failure as tokens being lost. It is the
opposite: they are drawn twice.

- [x] Carry a per-session high-water mark rather than comparing against the previous sample, so a
      reset contributes zero and the recovery is not re-counted
- [x] Test built from the real regression: session `6ff2ff43` falling 189,121,530 to 51,512,855

The daily chart is unaffected — it reads `daily_rollups`, not samples.

### 9.3 "Share of the 5h window" is neither  `DONE 2026-09-03`

**~0.5 day**

Two defects in one row of the session detail.

The label is the one the type forbids. `DerivedMetrics.swift:73` states that the figure "says
nothing about how much of the billing window is left", and that "the name of every member here
says *recent tokens* rather than *window* so the two cannot be confused at a call site". The
only call site, `SessionDetailView.swift:326`, says window.

The figure is also not what it claims. Numerator and denominator are each session's *lifetime*
`combinedUsage`, merely filtered to sessions active in the last five hours. Computed on the live
database for the window 20:25 to 01:25, session `6ff2ff43` renders 59% having spent about 1% of
the tokens actually spent in that window, while the session that spent 61% of them renders 25%.

- [x] The in-window figure is computed from `usage_samples` deltas and the label stays. The
      rename was the cheaper half and was rejected: stage 3 projects against the same in-window
      quantity, so the honest number was needed regardless.

The sample walk that 9.2 corrected is now one private routine shared by the hourly series and the
window share, so the high-water mark cannot be right in one and wrong in the other. A session with
nothing to difference inside the window is absent from the map and its row reads `Unavailable`; it
is on neither side of the division, so it does not sink the other sessions' shares. One refinement
inherited from the hourly path: a session born inside the window is derivable from a single sample,
because none of its running total predates the window.

### 9.4 Burn rate never decays  `DONE 2026-09-03`

**~0.5 day**

`MonitorSnapshot.swift:117` — `rate(now: Date = Date())` accepts `now` and never reads it.
Samples are evicted only inside `record(tokens:at:)`, which the engine calls only when the
combined total actually moved.

A session that spends 1.5 M tokens between 14:00 and 14:05 and then goes quiet still reports
300,000 per minute at 18:00, on the dashboard tile, in the sessions table and in the session row.

The documentation immediately above that struct claims the opposite behaviour: "an idle gap
drives the rate toward zero instead of preserving a stale average." The code does not do this.

- [x] Evict on read as well as on write, using the `now` the caller already passes
- [x] Test: a tracker with no new samples reports a falling rate and then zero

Eviction alone produces a stale figure followed by a cliff to zero rather than a decay, so the
elapsed span now runs from the oldest surviving sample to the read moment. The figure stays a
measurement: tokens observed over an interval that ends now.

Found while fixing it, and deferred to 9.11 because the projection is what makes it matter: the
decay is correct in the model and does not always reach the screen. `MonitorViewModel.refreshBurnRates()`
recomputes only when a snapshot is applied, and `publishIfChanged` suppresses publication while a
session is idle, which is exactly when the rate is falling. An idle app can display a frozen rate
until a filesystem event or the usage refresh wakes it. The fix must ride the existing usage
refresh rather than introduce a tick, because a tick collides with the no-polling and idle-CPU
rules.

### 9.5 A degraded store renders zero as a measurement  `DONE 2026-09-03`

**~0.5 day**

Two independent paths to the same failure, and together they break the project's first rule.

`AnalyticsService.todayTotal()` and `todayCost()` are the only analytics reads with no
`answered()` guard. Every sibling captures `store.health` before and after and returns nil.
`DashboardData.todayUsage` is optional precisely so a failed read can render `UnavailableView`,
but `DashboardAdapter.swift:67` can only ever pass a non-nil value. A failed read therefore
prints `Tokens today 0` and `$0.00 est.` as measurements.

Underneath that, `ClaudenceStore.note(failure:)` moves `_health` to `.degraded` once and takes
the `break` branch forever after, and `_health` is set to `.healthy` only during init. So health
never recovers, and once it is latched a newly failing query produces no transition,
`answered(before:after:)` returns true, and every other analytics read starts trusting its own
default as well.

- [x] Guard both reads, and let them return nil
- [x] Record every failure rather than only the first, and let health recover
- [x] Make `answered` depend on the outcome of the query rather than on a health transition
- [x] Test: a store failure after a prior failure renders `Usage unavailable`, never zero

The store now counts query outcomes: `unansweredQueries` rises when a statement throws and when
there is no database at all, and `answered(before:after:)` is equality over that count. It
survives a latched health value and it survives two reads failing inside one method, which a
transition misses even with the latch fixed. Health recovers to the value captured at init rather
than to `.healthy`, so a store that fell back to memory stays degraded however well it answers.

### 9.5b The same latch inside the engine  `FOUND 2026-09-03 while fixing 9.5`

Found by the 9.5 work rather than by the audits. `MonitorEngine.swift:305` repeats the health
transition check inline, so once health has latched, a failed `store.session(id:)` read reads as
"nothing stored": the session is marked seeded, the accumulator pins at zero against a cursor
already at byte N, and the undercount reaches `daily_rollups` on the next upsert. That is the
durable-corruption class CLAUDE.md records as having shipped once and been found by an audit
rather than a test, not a display defect, so it is fixed inside stage 1.

- [x] The engine reads the same query-outcome signal as the analytics layer
- [x] A read that did not answer never seeds a zero total over a stored one
- [x] Test: a failed read after a prior failure leaves the stored total and the rollup untouched

### 9.5c The same latch inside the subagent tracker  `DONE 2026-09-03`

`SubagentTracker.seedIfNeeded` marked a session seeded before it knew the read's outcome, and
`subagentTotals(forSession:)` returns an empty array for both "no subagents" and "the query
failed". Subagent tokens are 36.3% of this machine's month and 82% on one project, so the
undercount it wrote back is not a rounding error. Fixed the same way, with its own counter,
because a frozen session and a withheld subagent figure are different faults.

### 9.5d A failed cursor read re-scans the whole transcript  `DONE 2026-09-03`

The same ambiguity in the opposite direction, and the more expensive one.
`CursorStoring.cursor(forSession:)` returns nil for both "no cursor stored" and "the read threw"
(`ClaudenceStore.swift:654`), and both `TranscriptReader.readIncremental` overloads take nil as
"start at zero". A failed cursor read therefore re-parses up to 19.9 MB of records and adds the
whole file to an accumulator already seeded with the stored total, then writes the doubled figure
back to the session row, the subagent row and the rollup.

- [x] The reader distinguishes "no cursor" from "the cursor could not be read"
- [x] A cursor read that did not answer skips the session for the pass rather than starting at zero
- [x] Test: a failing cursor read against a stored total and a non-zero offset leaves both alone

### 9.5e The menu bar prints a failed aggregate as zero  `FOUND 2026-09-03`

`MonitorEngine.todayTotal` (`MonitorEngine.swift:395`) is `store.dailyTotals(days: 1).first?.usage
?? .zero` and caches the result for the TTL, so a failed aggregate publishes `Tokens today 0` in
the menu bar header as a measurement. Nothing durable is written, which is why it is not with the
others, but it breaks the first rule. It is fixed together with 9.6 because both change what
`todayUsage` means and both land in `MenuBarContent`.

- [x] `MonitorSnapshot.todayUsage` becomes optional and the header renders the unavailable state

### 9.6 `Today` reads zero after local midnight  `DONE 2026-09-03`

**~0.5 day**

`daily_rollups.day` is keyed by `session.startedAt` rather than by when the tokens were spent
(`ClaudenceStore.swift:237` and `:518`). A session that starts at 21:25 and is still running at
00:52 puts everything it spends after midnight onto the previous day's row, and `todayTotal()`
asks `WHERE day >= '<today>'` and gets nothing.

Observed at 00:52 on 2026-09-03: all eight rollup rows dated 2026-09-02, while session `871278d1`
was alive with 172.7 M tokens attributed entirely to the previous day.

Two further defects are downstream of this one and are fixed with it:

- The stat tile renders `down 100% vs yesterday` as a measurement, because
  `DayOverDayDelta.fractionalChange` computes `(0 - 855,975,471) / 855,975,471`. The type's own
  documentation calls out this case as one that must stay distinguishable from a real reading.
- Today's cost never refreshes at all. `MenuBarContent.swift:68` keys its refresh on
  `todayUsage.total / 250_000`, and after midnight that value is stuck at zero.

- [x] Derive per-day totals from `usage_samples` deltas keyed by the day `sampled_at` falls in,
      with the start-date rollup as the fallback for sessions with no samples
- [x] Route the correction through `recomputeRollups()`, never incremental writes
- [x] Suppress the day-over-day caption when there is no comparison rather than printing -100%
- [x] Test: a session spanning midnight contributes to both days and the two-day sum is unchanged

The rollup total was rewritten downward once before by a cursor/total mismatch and was found by
an audit rather than a test. The sum-preservation test is not optional.

Three things the item did not anticipate. Nothing called `recomputeRollups()` at all, so the fix
needed a caller before it could be true at runtime; the engine runs it on the first pass, on a day
rollover and while a live session predates today, throttled to 60 seconds. The split cannot be
done incrementally, because subtracting the previous contribution would need the previous split
and the session row does not carry one, so between repairs an overnight session's growth is filed
on its start day again: provably right about the total, up to 60 seconds late about the day.
And `session_count` deliberately stays on the start day, because it counts sessions rather than
session-days.

Carry into 9.12: the repair reads every session and every sample inside one transaction. That is
cheap against a 484 KB database and unmeasured against the database the history import will
produce. Time it on the imported database before trusting the 60 second throttle.

### 9.7 Counting and labelling  `DONE 2026-09-03`

**~0.5 day**

Smaller, all of them cases where the screen states something untrue.

- **Three different "active sessions" counts render at once.** `MonitorViewModel.swift:253` uses
  `status == .running`; `MenuBarContent.swift:317` uses every session including idle ones, under
  a label reading ACTIVE SESSIONS; `StatTilesView.swift:158` does the same. With one busy and one
  idle session, VoiceOver says one, the popover pill says two, the tile says two.
- **The active tile can print a numerator larger than its denominator.** Numerator is every live
  registry session; denominator is `sessionsActiveToday()`, which filters stored rows on
  `last_activity_at`. An idle session carrying yesterday's timestamp is in the first and not the
  second, so the tile renders `2 / 1 today`. `AnalyticsService.swift:388` documents this exact
  arrangement as the thing being prevented.
- **Two definitions of "today" on one window.** `SessionHistoryView.swift:37` filters on
  `startedAt`; `sessionsActiveToday()` filters on last activity, deliberately. The history table
  reads "0 sessions" while the tile two cards above reads "/ 1 today".
- **Two cost figures over different ranges, neither labelled.** The tile is today; the projects
  table is called with `since: nil`, meaning all time. The tile reads $3.42 beside project costs
  summing to $5.43.
- **`TokenBreakdownCard` prints `(0%)` beside a non-zero count.** `Format.share` exists for
  exactly this and emits `<1%`; the session detail uses it, this card does not.

- [x] One definition of "active", used everywhere the word appears
- [x] One definition of "today", used everywhere the word appears
- [x] Label both cost ranges, or make them the same range
- [x] Route the card's percentage through `Format.share`

Active means doing work now (`status == .running`); live means the process exists, busy or
waiting. The tile reads `Active sessions 1 / 2 live`, the popover band reads `LIVE SESSIONS`, and
a numerator can no longer exceed its denominator because both come from one array. Today means
the day the work happened, `lastActivityAt >= startOfDay`, the same argument 9.6 settled in the
store.

Four things the item did not name, all found by the work. `todayCost()` carried a *third*
definition of today, an exact start-day match, so after 9.6 the cost tile could read `$0.00`
beside a non-zero Tokens today whenever the day's work came from an overnight session. The `(0%)`
reached VoiceOver as well as the tooltip. `Tooltip.breakdownEntry` is shared with the session
detail sheet, so that sheet had the same defect behind a correct visible column. And
`DashboardData.activeProjectCount` was a fourth use of the word over the live set.

Carry into 9.13: `AnalyticsService.projectBreakdown(since:)` still filters on `startedAt`. It is
called only with `nil` today, so no surface prints a wrong "today" off it, but the monthly table
passes a real range and would inherit the pre-9.6 keying the moment it does.

### 9.8 Settings that do not reach every surface  `DONE 2026-09-03`

**~0.5 day**

A control that lies is worse than an absent one, which puts this in stage 1 rather than later.

- [x] `showSubagents` is read at one site only. `ClaudenceApp.swift:315` passes `showsSubagents:
      true` as a literal, so the switch works in the popover and is ignored in the dashboard sheet.
- [x] `compactRows` is read at one site only; the dashboard's sessions card has no compact concept.
      Wire it, or rename the setting to say it is the menu bar only.
- [x] `liveIndicators` has two delivery paths that can diverge: the environment, read by eight
      components, and an explicit parameter passed into `SessionRow`, which already reads the
      environment. Merge onto the environment.

`compactRows` was wired rather than renamed: the setting's own words are "hide duration, rate and
sparkline", and all three exist on a dashboard row, so a dense form exists to switch to. The
divergence was worse than the item described. `SessionsTableView.statusPill` built a
`StatusIndicator` with no `isLive` argument at all, so the dashboard's status glyph kept pulsing
with the switch off; the parameter had to be deleted from `StatusIndicator` as well as from
`SessionRow`.

Recorded because it will keep costing: none of this is unit-testable. Every affected symbol lives
in the `Claudence` executable target, which the test target does not depend on, so the verification
was call-site reading. `RenderShots` is the only mechanical check the UI has, and stage 2.5 should
lean on it rather than adding a test target late.

---

## Stage 2 — Subtraction

Approved after all four user perspectives independently named the same things, without seeing
each other's answers.

### 9.9 Remove what does not earn its place

**~0.5 day, and it is a net deletion**

- [ ] **The subagent detail sheet, entirely.** Thirteen of roughly twenty slots are unavailable by
      construction rather than for want of data today, and the code says so in six separate
      comments. The four facts that do exist — parent, agent type, tokens, share of parent — move
      inline into the subagent row on the parent sheet. What is lost is the per-subagent cache
      split, which is real data honestly derived; it is not worth a navigation step.
- [ ] **Tool Mix and Files Touched.** No reader named a decision that changes on `Read 41, Edit 19`,
      and Files Touched shows three truncated chips of a session that touched sixty files.
- [ ] **The diagnostic facts**: PID, Kind, Registry, Session id, CC version, Transcript, Tail
      offset. These exist for whoever is debugging the reader, and `--diagnose --counters` already
      serves that reader from the terminal. This supersedes the previous plan's intention to spend
      a day plumbing `Kind`, `Registry`, `Transcript` and `Tail offset` into `AISession`: removing
      them costs nothing and removes four permanent `Unavailable` labels.
- [ ] **`Git branch`**, which is not a removal but a correction, and the reason the tile survives.
      `SessionFactsView` hardcodes it to nil with a reason that is false: `TranscriptReader.swift:216`
      collects the branch, `MonitorEngine.swift:182` assigns it, and `MenuBarContent.swift:340`
      already displays it.
- [ ] **Dead code.** `ClaudenceStore.projectTotals(since:)` (zero callers, and its SQL selects
      parent-only columns, so wiring it up would reproduce 9.1); `usageSamples(sessionID:since:)`
      (zero callers); six `RegistryRecord` fields decoded and never read; seven `CostEstimate`
      members including a `gapDescription` that composes a user-facing sentence nothing prints;
      `DerivedMetrics.percentChange` and `hasComparison`; nineteen `Theme` tokens including four
      `subagent*Column` widths left over from a table layout that no longer exists.
- [ ] **`AISubagent.spawnDepth`**, and its entry in the privacy allowlist. It is read from
      `meta.json`, carried through the tracker, written to SQLite and read back, and no view
      renders it. CLAUDE.md argues at length about which fields of that file may be read; one of
      the four is used for nothing, and permission to read it should not outlive the use.

### 9.10 De-duplicate what is displayed twice

**~0.5 day**

- [ ] `TOKENS TODAY` and the token breakdown card's `Total` are the same number on one window
- [ ] `ACTIVE SESSIONS 4` restates the row count of the card directly above it
- [ ] The power meter's attention banner restates the tube and caption forty pixels above it
- [ ] `Share of the parent` and `Share` appear in the same detail sheet
- [ ] Three independent computations of "this component as a share of the total" — `Tooltip.swift:395`,
      `SessionDetailView.swift:966`, `TokenBreakdownCard.swift:156`. One helper on `TokenUsage`.
- [ ] `SubagentListView.swift:131` computes a share by hand two lines above using
      `AISubagent.share(ofParentTotal:)`, which exists
- [ ] The usage chart occupies half the top row and renders `No usage history` in every captured
      screenshot, including populated ones. Give it a daily fallback when the hourly series is
      empty, or collapse the card.

---

## Stage 2.5 — Ready for other people's machines

Added 2026-09-03 after the requirements interview that turned this from a personal tool into a
product. The first users are friends on Pro and Team plans, running a notarized `.dmg`, for
free. Three items parked earlier in this phase come back here, because the argument against
each was "there is one user and it is the maintainer", and that is no longer true.

Ordered before the gauge and the ledger on purpose: the friends' feedback is the best evidence
available for what those two should be, and a build with wrong numbers on it is not a build to
collect feedback with. That is why Stage 1 precedes this.

### 9.10a First launch

**~1.5 days**

- [ ] An onboarding screen, before the Keychain prompt, stating what is read (`message.usage`,
      tool names, file paths, a hash of commands, the plan tier) and what is never read (message
      text, tool results, command strings). The Keychain request arrives with its reason already
      given; today it arrives cold, and a friend who clicks Deny sees an app that looks broken.
- [ ] Detect an absent Claude Code and say what to install, rather than showing an empty meter.
- [ ] Import the user's existing `~/.claude/projects` history immediately after consent
      (this pulls 9.12 forward into this stage), with a visible report of what was read and what
      could not be.
- [ ] Language choice on the first screen, defaulting to the system language.

### 9.10b Thai and English  `UN-PARKED`

**~3 days**

The plan as written under 9.5 in the previous revision stands: a `Phrase { en, th }` value type
in Core so an untranslated string is a compile error; Gregorian year forced twice; a lint test
against raw user-facing literals; render shots in both languages. The two measured traps — a
Thai locale supplying the Buddhist calendar, and the system monospaced font carrying no Thai
glyphs — are recorded under *Parked* below and apply unchanged.

### 9.10c A report the friend can send

**~1 day**

The two defects that were inside the error-monitoring request are already Stage 1 work (9.5).
What returns here is the part the sceptic rejected for a single user: a button that writes one
file — recent errors with the home directory and project paths abbreviated, the app version,
macOS version, database size and row counts, the engine's counters — for the friend to send by
hand. Nothing is sent automatically. The file is English regardless of the interface language,
because it is read by the maintainer against the source.

### 9.10d Clear stored data  `UN-PARKED, REDUCED`

**~0.5 day**

One button in the privacy settings: delete everything and `VACUUM`, behind a confirmation that
names the real row counts. Not the date-range delete; a friend who wants the app to forget wants
it to forget, and a friend who wants to keep some history is not the person pressing this. The
invariant recorded under *Parked* still binds: session rows and their cursors go together.

### 9.10e Ship

**~1 day**

- [ ] `Scripts/make-app.sh` signs with a Developer ID and notarizes with `notarytool` when
      `CODESIGN_IDENTITY` names one, and falls back to the self-signed certificate otherwise.
      The account does not exist yet; the script must not wait for it.
- [ ] The version is visible in Settings and in the report file. There is no update check.
- [ ] An `Entitlement` type with one implementation that answers "everything on" and makes no
      request. It exists so a paid tier can be gated later without a refactor, and so the privacy
      contract can name the third outbound request before anyone writes it.
- [ ] Remove `AIProviderType`. Claude Code is the only provider, permanently, and a seam with one
      implementation and no planned second is a claim the code makes that the product does not.
- [ ] The Pro plan's windows are five to twenty times smaller than the maintainer's. Verify the
      thresholds, the menu bar reading and the notifications against a Pro account before the
      first friend does.

---

## Stage 3 — The gauge

The application's stated priority is `power meter -> active sessions -> analytics`, and the
cheapest unbuilt thing is at the top of it.

### 9.11 Time to empty

**~1 day**

The question the meter cannot currently answer: at 11:04, with the 7-day window at 66% and four
hours of Opus work planned, does the work fit. The meter shows a photograph where a trajectory is
needed.

Nothing new has to be read. `UsageWindow` already carries `usedPercent` and `resetsAt`, and
`BurnRateTracker` already produces tokens per minute. The remaining work is division, plus the
honesty around it.

- [ ] Projected exhaustion time per window, shown beside the reset time in the same tile, because
      the gap between those two is the entire decision
- [ ] Which window binds first. 21% on 5h and 66% on 7d are given equal visual weight today, and
      the 7-day one is the one that ends the day
- [ ] The session responsible for the largest share of the current burn, named
- [ ] `Rate unavailable` until there are enough samples. A projection from one sample is a
      fabricated number, and this is the feature most able to produce one

Depends on 9.4: a burn rate that never decays produces a projection that never moves.

---

## Stage 4 — The ledger

Every month-shaped question the application invites is currently unanswerable while 242 MB of the
answer sits on disk and the database holds one day.

### 9.12 Import the history already on disk

**~1.5 days**

- [ ] A one-time import with a chosen start date, and a way to clear a range and re-run it
- [ ] A path that does not require liveness. Historical sessions have dead PIDs, and discovery is
      gated on `kill(pid, 0)` plus a matching `procStart`
- [ ] Report what the import found and what it could not read. An import that silently drops a
      project is worse than none, because the totals afterwards are trusted
- [ ] The largest transcript on disk is 19.9 MB against a 12 MB performance fixture. Re-measure
      the 50 ms re-scan budget against the real file, not the fixture

### 9.13 The monthly table

**~1 day**

One table, twelve rows, readable in ten seconds: project, sessions, tokens, Opus share against
Sonnet share, and the API-equivalent figure. Sorted by tokens.

- [ ] `daily_rollups` has no model column. Splitting by model needs a schema change
- [ ] State in the table's own footnote whether subagent tokens are inside the figure. After 9.1
      they are, and a reader cannot tell by looking
- [ ] `Est. cost: unavailable` on a row whose tokens are known reads as zero. Say that the tokens
      are known and the price is not, in the cell

### 9.14 Reframe the money

**~0.5 day**

The dollar figure stays, and stops being presented as an amount owed. On a subscription it is not
one. It is the only unit that compares 632k of Sonnet against 632k of Opus, which is a real job,
and the question it actually answers is whether the subscription is earning its price.

- [ ] Label it as an API equivalent rather than a cost
- [ ] Show the plan's price beside it, so the comparison is on screen rather than in the reader's
      head

---

## Parked, with the argument recorded (two of three un-parked in Stage 2.5 the same day)

Both of these were previously agreed and are being deferred rather than dropped. The case against
them was made by a reviewer briefed to argue against additions, and it is recorded here so that
picking them up later means answering it rather than forgetting it.

**Deleting stored data by date range.** The database is 484 KB after a full day. `rm` on the file
already works and is what would actually be done. The argument against: building a retention
interface for half a megabyte is the tool growing for its own sake. What survives regardless, and
must be written down before anyone implements deletion later: a `sessions` row and its
`read_cursors` row are deleted in the same transaction or not at all, because a cursor without
its total resumes at byte N with the total restarted at zero and writes the collapsed figure back
over the session and the rollup.

**Thai and English.** Three days, 220 strings, 26 files, a new type in Core, a lint test, a
Buddhist-calendar trap and sixteen monospaced styles whose font carries no Thai glyphs — for one
reader who spends the day reading Claude Code's own English output, after which every new string
costs twice, permanently. The measured comparison that decided it: three days is six times the
cost of fixing the numbers that are currently wrong on the dashboard.

**Most of the error-monitoring feature.** The two defects buried inside it are mandatory and are
now 9.5. The health snapshot, row counts, engine counters, idle CPU sampling and export file are
an incident-response process for an application with no incidents and one user who can already
read the SQLite file directly.

---

## What was rejected, and why it is worth recording

One reviewer argued the analytics half is a solution looking for a problem, and asked instead for
an end-of-session receipt comparing a session against the reader's own last twenty: subagent
share against the median, repeat-read factor, output per hour falling across a long session. The
argument is good and the measured data supports it — subagent share really does range from 0% to
82% by project, and nobody could know that without being told.

It is not being built, for a reason that is about cost rather than merit. `toolCounts`,
`filePaths` and `activityTrail` are not persisted at all: they live in memory, and the trail is
capped at 24 entries. Every other request in this phase uses data that already exists; this one
needs a new table, a new write path and a retention policy before the first number appears. It is
the right thing to reconsider once stages 1 to 4 are done and the numbers can be trusted.

---

## Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Claude Code changes the `sessions/*.json` schema | discovery breaks | adapter with version detection, golden fixture per version, `ps` fallback |
| Slug derivation fails on unusual paths | transcript not found | confirm `sessionId` from inside the file, never trust the path alone |
| Registry `status` has undiscovered values | UI shows a wrong state | enumerate in M1; unproven states stay out of the UI |
| Usage API or beta header changes | 5h and 7d disappear | degrade to `Usage unavailable`; never substitute a guess |
| Transcripts grow past 12 MB | CPU budget blown | offset-based tailing is mandatory; full re-parse is forbidden |
| Keychain re-prompts on every build | unusable dev loop | stable self-signed certificate from M0 |

---

## Deferred

Not before MVP works: AI-generated summaries, cloud sync, team dashboard, remote monitoring, multi-device sync, sending commands to Claude.

`Stop Session` ships only with a confirmation dialog naming the session, or not at all.
