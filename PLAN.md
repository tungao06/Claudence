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
| Distribution | Personal, single machine | no notarization, no Apple Developer account, no CI |
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

## Stage 1 — Correctness

Nothing in stage 2 or 3 starts until this stage is done. The application currently prints
several figures that are confidently wrong, and a monitoring tool that cannot be trusted is
worse than none.

### 9.1 The project breakdown contradicts itself inside one row  `CONFIRMED`

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

- [ ] `usage += session.combinedUsage`
- [ ] Test: a project whose sessions have subagents reports the combined figure, and sorts on it

### 9.2 The hourly chart counts tokens twice after a cumulative regression  `CONFIRMED`

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

- [ ] Carry a per-session high-water mark rather than comparing against the previous sample, so a
      reset contributes zero and the recovery is not re-counted
- [ ] Test built from the real regression: session `6ff2ff43` falling 189,121,530 to 51,512,855

The daily chart is unaffected — it reads `daily_rollups`, not samples.

### 9.3 "Share of the 5h window" is neither  `CONFIRMED`

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

- [ ] Either compute a true in-window figure from `usage_samples` deltas, or rename the row to
      what it measures. Not both readings under one label.

### 9.4 Burn rate never decays  `CONFIRMED`

**~0.5 day**

`MonitorSnapshot.swift:117` — `rate(now: Date = Date())` accepts `now` and never reads it.
Samples are evicted only inside `record(tokens:at:)`, which the engine calls only when the
combined total actually moved.

A session that spends 1.5 M tokens between 14:00 and 14:05 and then goes quiet still reports
300,000 per minute at 18:00, on the dashboard tile, in the sessions table and in the session row.

The documentation immediately above that struct claims the opposite behaviour: "an idle gap
drives the rate toward zero instead of preserving a stale average." The code does not do this.

- [ ] Evict on read as well as on write, using the `now` the caller already passes
- [ ] Test: a tracker with no new samples reports a falling rate and then zero

### 9.5 A degraded store renders zero as a measurement  `CONFIRMED`

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

- [ ] Guard both reads, and let them return nil
- [ ] Record every failure rather than only the first, and let health recover
- [ ] Make `answered` depend on the outcome of the query rather than on a health transition
- [ ] Test: a store failure after a prior failure renders `Usage unavailable`, never zero

### 9.6 `Today` reads zero after local midnight  `CONFIRMED`

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

- [ ] Derive per-day totals from `usage_samples` deltas keyed by the day `sampled_at` falls in,
      with the start-date rollup as the fallback for sessions with no samples
- [ ] Route the correction through `recomputeRollups()`, never incremental writes
- [ ] Suppress the day-over-day caption when there is no comparison rather than printing -100%
- [ ] Test: a session spanning midnight contributes to both days and the two-day sum is unchanged

The rollup total was rewritten downward once before by a cursor/total mismatch and was found by
an audit rather than a test. The sum-preservation test is not optional.

### 9.7 Counting and labelling  `CONFIRMED`

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

- [ ] One definition of "active", used everywhere the word appears
- [ ] One definition of "today", used everywhere the word appears
- [ ] Label both cost ranges, or make them the same range
- [ ] Route the card's percentage through `Format.share`

### 9.8 Settings that do not reach every surface  `CONFIRMED`

**~0.5 day**

A control that lies is worse than an absent one, which puts this in stage 1 rather than later.

- [ ] `showSubagents` is read at one site only. `ClaudenceApp.swift:315` passes `showsSubagents:
      true` as a literal, so the switch works in the popover and is ignored in the dashboard sheet.
- [ ] `compactRows` is read at one site only; the dashboard's sessions card has no compact concept.
      Wire it, or rename the setting to say it is the menu bar only.
- [ ] `liveIndicators` has two delivery paths that can diverge: the environment, read by eight
      components, and an explicit parameter passed into `SessionRow`, which already reads the
      environment. Merge onto the environment.

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

## Parked, with the argument recorded

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
