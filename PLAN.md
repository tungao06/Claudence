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

**Two fixes were considered; the safer one shipped.**

Unmounting the popover subtree when it is not presented is the more general fix, since nothing off
screen can then animate whichever component grows an animation next. It was built and then rejected:
the AppKit signals available for "is this popover presented" flip on spuriously. `onAppear` fires at
launch and cannot tell "presented" from "built". `NSWindow.isVisible` turns true on its own during a
frame update, which made the popover mount itself and burn 7% again for the rest of the session.
A false negative on that signal means an empty popover, which is a worse defect than the one being
fixed.

What shipped instead publishes presentation into the environment as `popoverIsPresented` and lets
components suppress their own motion. The default is `false`, so anything that cannot prove it is
visible stays still. A wrong answer now costs a missing pulse rather than an empty popover, and the
supporting fixes stand on their own:

- `MonitorViewModel` splits `menuBarState` and `usageState` out of `snapshot`, so the label — the
  only thing on screen while the popover is closed — is not invalidated by session token churn.
- Assignments are guarded on inequality, because `@Observable` invalidates on assignment rather
  than on change.

**Definition of done:** idle CPU under 0.5% measured by CPU delta over at least 5 minutes with live
sessions present.

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
