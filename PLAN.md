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

## M0 — Skeleton that runs

**~4 hours**

- [ ] `git init`, `.gitignore` for `.build/`, `*.app`, `.DS_Store`
- [ ] `Package.swift` with an executable target
- [ ] `Info.plist` with `LSUIElement = 1` so no Dock icon appears
- [ ] `make app` script: `swift build -c release` then assemble the `.app` bundle
- [ ] Create one self-signed code signing certificate and sign every build with it
- [ ] `MenuBarExtra` showing a static icon plus a working Quit

**Definition of done**

- Double-clicking the `.app` puts an icon in the menu bar
- Quit works and leaves no process behind
- Rebuilding and relaunching does **not** re-prompt for Keychain access

**Why signing is here and not at M4:** an ad-hoc signature changes every build, so macOS treats each build as a new application and re-prompts for Keychain access. One stable certificate makes "Always Allow" persist.

---

## M1 — Session discovery

**~1 day.** This is the product's core value.

- [ ] `SessionRegistryAdapter` reading `~/.claude/sessions/*.json`
- [ ] Filter to `kind == "interactive"`
- [ ] Liveness check: `kill(pid, 0)` **and** matching `procStart`
- [ ] Reap stale files left by crashed sessions
- [ ] FSEvents watcher on the directory, 250 ms debounce
- [ ] Map to the `AISession` domain model
- [ ] Popover lists sessions: name, working directory, status, duration
- [ ] **Enumerate the real set of `status` values by observation** and record them in the spec

**Definition of done**

- Two concurrent Claude Code sessions render as two rows with correct working directories
- Closing one removes it within 1 second
- A stale registry file is never displayed
- No use of `ps` for enumeration

**Open question resolved here:** only `busy` has been observed. Section 6 of the spec stays blocked until the full set is known.

---

## M2 — Token ingestion

**~1.5 days.** After this the application is genuinely useful.

- [ ] Map `sessionId` to its transcript, confirming by reading `sessionId` inside the file rather than trusting the path slug
- [ ] SQLite schema: sessions, usage samples, file offsets, daily rollups
- [ ] Incremental tail storing `(path, inode, byteOffset)`; reset the offset when the inode changes
- [ ] Parse `type == "assistant"` records into `TokenUsage`
- [ ] Aggregate per session and per day
- [ ] Token energy bar and breakdown in the popover

**Definition of done**

- Totals land within 2% of Claude Code's own accounting
- A 12 MB transcript re-scans in under 50 ms
- Killing the app mid-session and restarting resumes from the stored offset without double-counting

**Locked before any code:** `billableInput = freshInput + cacheCreation + cacheRead`, `total = billableInput + output`. Cache is always displayed separately.

---

## M3 — Activity detection

**~1 day**

- [ ] Parse `content[]` `tool_use` entries into `{name, input.file_path}`
- [ ] Hash `input.command` with SHA256; never retain the string
- [ ] Map to human phrasing: `Edit` plus a path becomes "Editing Menu.tsx"
- [ ] Bash renders as "Running a command" — no command echo
- [ ] Privacy allowlist implemented as a filter in the parser

**Definition of done**

- A test fails if the parser emits `content[].text`, any tool result, file history content, or a raw command string
- Every active session shows a current activity or an honest blank

**This test is the privacy contract.** Without it section 3 of the spec is a promise rather than a property.

---

## M4 — Usage limits

**~1 day**

- [ ] Read the OAuth token from Keychain (`service = "Claude Code-credentials"`), falling back to `~/.claude/.credentials.json`
- [ ] Refresh via `POST platform.claude.com/v1/oauth/token` when expired
- [ ] `GET api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`
- [ ] Parse flat windows plus the `limits[]` scoped array, enumerating model scopes rather than hard-coding names
- [ ] Domain allowlist enforced inside the request helper, blocking off-allowlist redirects
- [ ] 60 s cache, backoff on 429, serve cached values while backing off

**Definition of done**

- 5h and 7d windows render with reset times
- Network down renders `Usage unavailable`, no crash, no hang
- Keychain access denied renders `Usage unavailable` and the rest of the app keeps working
- An expired token refreshes without user action
- The token appears in no log, no cache file, and no view

---

## M5 — Power meter UI

**~2 days**

- [ ] Power bar, energy ring, token bar, sparkline
- [ ] Semantic color tokens; no hex in views
- [ ] Menu bar rendering under 60 pt, session count opt-in
- [ ] Honor Reduce Motion
- [ ] Empty and degraded states for every panel

**Definition of done**

- Every state pairs a glyph with text; nothing depends on color alone
- Menu bar width stays under 60 pt in all states
- With Reduce Motion enabled, no animation runs

---

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
