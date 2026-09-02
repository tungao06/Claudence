# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Claudence** — a macOS Menu Bar application that monitors Claude Code sessions. It shows every active session at once, across every project, with token consumption and remaining usage limits.

The differentiator is multi-session visibility: Claude Code's own status line sees only the session it runs inside. When a design tradeoff comes up, multi-session clarity wins.

Governing metaphor is a power meter, not an analytics dashboard. Visual priority is fixed and must not be reordered:

```
power meter -> active sessions -> analytics
```

## Documents

- `Claudence_CLAUDE.md` — full product and engineering specification. Authoritative on product decisions, data contracts, and the privacy allowlist. Read it before implementing anything.
- `PLAN.md` — milestone tracker. Update checkboxes as work lands.
- This file — operational summary.

## Repository state

Pre-implementation. No source code yet, no build system, no test runner. Commands below describe what M0 creates; until M0 lands they do not exist.

## Stack (decided)

Swift 6.3.3 + SwiftUI `MenuBarExtra`, targeting macOS 26. Built with **Swift Package Manager**, not Xcode — only Command Line Tools are installed on this machine, so `xcodebuild` is unavailable. The `.app` bundle is assembled by a script.

```
SwiftUI MenuBarExtra    menu bar and popover
FSEvents                watch ~/.claude/sessions
GRDB or SQLite.swift    persistence
Security.framework      Keychain read for the OAuth token
Swift Testing           parser and privacy tests
```

Distribution is single-machine personal use. No notarization, no Apple Developer account, no CI, no release pipeline.

### Consequences of having no Xcode

- `#Preview` does not compile. The macro's `PreviewsMacros` plugin ships inside Xcode, so SwiftUI previews use `PreviewProvider` structs with `.previewDisplayName` instead.
- No Instruments. Performance claims come from `ps` and timed tests, not from a profiler.
- Concurrent agents must build with their own `--scratch-path`; a shared `.build` directory serializes on a lock.

### Code signing matters from day one

Claude Code's credentials live in the macOS Keychain (`service = "Claude Code-credentials"`), not in `~/.claude/.credentials.json`, which does not exist on this machine. A binary signed ad-hoc gets a new identity on every build, so macOS re-prompts for Keychain access after every rebuild. M0 creates one self-signed code signing certificate and every build uses it, making "Always Allow" stick.

## Data sources

Four sources, all undocumented Claude Code internals, all behind adapters with version detection and a defined degraded state. Full detail with verified payloads is in `Claudence_CLAUDE.md` section 2.

| Source | Provides |
|---|---|
| `~/.claude/sessions/<pid>.json` | live sessions: pid, sessionId, cwd, status, startedAt, name |
| `~/.claude/projects/<slug>/<sessionId>.jsonl` | tokens (`message.usage`) and activity (`tool_use`) |
| `~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.jsonl` | subagent tokens and activity, plus `.meta.json` for type, task label, spawn depth |
| Keychain `Claude Code-credentials` | OAuth access and refresh token |
| `GET api.anthropic.com/api/oauth/usage` | 5h / 7d / model-scoped usage windows |

Two traps that cost real time if rediscovered:

- **`ps` is not session discovery.** Most processes named `claude` are `bg-pty-host`, `bg-spare`, `daemon run`, or `--chrome-native-host`. Naive counting overcounts roughly 4x. Discovery comes from the registry; `ps` only corroborates a PID already found there.
- **Transcripts reach 12 MB.** Never re-parse a whole file. Persist `(path, inode, byteOffset)` and resume; a changed inode means rotation, so reset to zero.
- **A cursor and its total must be durable together.** Persisting the offset without the accumulated total is worse than persisting neither: the reader resumes at byte N, the total restarts at zero, and the collapsed figure is then written back over the session row and rewrites the daily rollup downward. This shipped once and was found by an audit, not by a test.
- **The parent transcript contains none of its subagents' records.** Measured here: 47% of a session's true total lived in the fifth source. `isSidechain` is false on every parent record, so there is no signal in the parent that anything is missing.

Liveness needs `kill(pid, 0)` **and** a matching `procStart`. PID alone resurrects dead sessions under recycled PIDs.

## Privacy contract

Enforced by tests, not discipline. A test must fail if the parser emits anything outside the allowlist.

Readable: `message.usage.*`, `message.model`, `content[].name`, `content[].input.file_path`, and `content[].input.command` **as a SHA256 hash only**. Plus timestamps, sessionId, cwd, gitBranch, version.

Also readable, added 2026-09-02 when subagent tracking landed: the four fields `SubagentLocator.Meta` decodes from `~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.meta.json`, which are `agentType`, `description`, `toolUseId`, and `spawnDepth`. `description` reaches the interface as `AISubagent.taskDescription` and the disk as the `subagent_totals.task_description` column. Nothing else in that file is read: a field `Meta` does not declare is left on disk deliberately, and adding one is an amendment to this list, not a detail of the decoder. This covers the spawn metadata of a subagent and nothing about its work. It is not the subagent's prompt, not its messages, and not its results; those live in the sibling `agent-<id>.jsonl` and are parsed under exactly the rules above.

Both halves of the argument, because a reader deciding about the next `meta.json` field needs both. For: Claude Code writes `description` at spawn time, so it is a label produced by the tool rather than content produced by a person or a model, and without it the subagent list is eight indistinguishable rows named `agent-01` through `agent-08`, which is a display with no reason to exist. Against: it is free text of arbitrary content. Whoever spawns the subagent chooses the string, nothing constrains it to a short label, and anyone who writes a secret into a task description has written that secret into this application's SQLite file. The field is kept because the display is worthless without it, not because the risk is zero. A future field from that file gets the same two-sided reading rather than being waved through on the grounds that the tool wrote it.

Also readable, added 2026-09-02 when the plan badge landed: exactly two fields from `~/.claude.json`, `oauthAccount.organizationType` and `oauthAccount.organizationRateLimitTier`, decoded by `AccountPlanReader` and rendered as `Max 5x`, `Pro` and so on. This is a new file and by some distance the most sensitive one the application opens: `emailAddress`, `fullName`, `organizationName`, `accountUuid` and every project path the user has ever worked in sit two keys away. The decoder declares two fields and its enclosing type declares one key; a field it does not declare is left on disk deliberately, the same rule the subagent `meta.json` follows, and `PrivacyTests` fails if anything else reaches the value.

Both halves again. For: the two fields name a product tier, not a person. They are identical for every customer on that tier, they are the words on a pricing page, and without them every percentage in the product is a share of a quantity it never states, where 62% of a Max 20x window is four times the work of 62% of a Max 5x one. Against: a working JSON decoder now points at that file, and the next reader will find it one line's work to take more; the narrowness is the whole safeguard and it lives in a test, not in anyone's intention. The usage endpoint may well carry the tier too and would have avoided the new file, but the local read needs no request and survives a rate limit, so the outbound surface is unchanged at two requests.

Never read, store, or display: `content[].text`, tool results, file history snapshots and deltas, attachment payloads, or the raw command string. Command strings routinely carry API keys and connection strings, so activity labels stay at tool-name granularity ("Running a command") rather than echoing the command.

Two outbound requests exist, both on the usage path and nothing else: `GET api.anthropic.com/api/oauth/usage`, and a conditional `POST platform.claude.com/v1/oauth/token` when the access token has expired. Earlier wording here claimed exactly one; that was wrong, and the Settings privacy panel discloses both.

The request helper enforces a host allowlist (`api.anthropic.com`, `console.anthropic.com`, `platform.claude.com`) before the `Authorization` header is built, and refuses redirects off it, so the token cannot structurally reach a third party. `console.anthropic.com` is allowlisted but never used; narrowing the list to the two hosts actually reached would be a real reduction in blast radius and is worth doing when someone touches that file.

## Token formula

Single definition, used everywhere. Nothing computes its own.

```
billableInput = freshInput + cacheCreation + cacheRead
total         = billableInput + output
```

Bars use `total`. Breakdowns always show cache separately — cache reads cost roughly an order of magnitude less than fresh input, and collapsing them makes the display disagree with the bill.

## Hard rules

- **Never fabricate a number.** A metric that cannot be derived renders `Usage unavailable`. Cost and prediction always carry an "Estimated" label.
- **Never ship UI for a state with no data source.** Section 6 of the spec tracks which of the six session states are actually derivable; `WAITING`, `PERMISSION`, and `ERROR` are not yet, so they stay out until proven.
- **Absent Claude Code, zero sessions, denied Keychain access, and no network are ordinary states** with defined UI, not errors.
- **UI never touches a file path, a process, or the network.** New facts enter through the domain model first.
- Event-driven only: FSEvents with 250 ms debounce, offset-based tailing. No polling, no main-thread I/O.
- **No repeating animation anywhere in the popover, conditional or not.** `MenuBarExtra(style: .window)` builds its content at launch and keeps it mounted after dismissal, so a `.repeatForever` drives a layout and display-list pass at the screen refresh rate for the life of the process. One such animation measured 6.9% of a core with the popover never opened, against a 0.5% budget. Gating the repeat on a "is the popover presented" signal was tried twice and failed twice — both `NSWindow.isVisible` and `isKeyWindow || occlusionState.contains(.visible)` turn true on their own during a frame update, and the cost comes straight back. Animate once per observed change instead, so an idle view costs nothing by construction rather than by a flag being right.
- **Measure idle CPU as a delta**, never with `ps -o %cpu`, which reports a lifetime average and hid this defect completely:
  ```
  PID=$(pgrep -f "Claudence.app/Contents/MacOS/Claudence" | head -1)
  date +%s; ps -o time= -p $PID    # wait 5+ minutes, then repeat
  # idle % = (cpu2 - cpu1) / (wall2 - wall1) * 100
  ```
  A warm baseline is necessary and not sufficient. The window also has to be idle: a measurement taken while agents are writing transcripts and builds are running reports the cost of real work, and reads as a regression. Cross-check a suspicious figure with `sample <pid>` and with `--diagnose --counters`, which reports the engine's own cost separately.
- Performance budget: idle CPU under 0.5%, resident memory under 60 MB, cold start under 1 s, 12 MB transcript re-scan under 50 ms.
- Semantic color tokens (`healthy`, `attention`, `warning`, `critical`) only; no hex in views. Never color alone — every indicator pairs a glyph with text.
- **A SwiftUI `Shape` renders as nothing inside a `MenuBarExtra` label.** Measured on macOS 26.6.2: a label reduced to `HStack { Circle().fill(.red).frame(width: 8, height: 8); Text("X") }` put `X` on the menu bar and no dot. `Text` and `Image` survive; vector drawing does not. This was total, silent, and in the `.minimal` style, where the ring is the whole label, it took the status item with it: the app ran, the popover was mounted, `NSStatusItem` existed, and the menu bar had nothing on it. An accessory app with no Dock icon and no Force Quit entry that cannot be clicked also cannot be quit. Draw the mark into an `NSImage` (`MenuBarMark`) and hand that to `Image(nsImage:)`.
- **The menu bar's appearance is not the app's.** It follows the wallpaper behind it, not `NSApp.appearance`, and nothing exposes it to the label. A colour resolved from the app's own appearance can therefore land dark ink on a dark strip. The neutral mark is a template image so AppKit tints it; only a *measured* mark keeps its own colour, and it earns that by being one of two redundant cues with a reading printed beside it. The measured mark walks `Theme.severityRamp(percent:)`, a continuous interpolation of the same four tokens that lands on each token exactly at the threshold that names it, so the ramp and `Constants.UsageThreshold.severity(forPercent:)` cannot disagree at a boundary.
- **Apply a preference from the application, not from a view.** `MenuBarExtra` does not build its content until the popover is first opened, so an `onChange` living there is not listening yet. The appearance setting was applied from that observer and did nothing until the popover had been opened once, which reads as a broken setting rather than a late one. `AppearanceController` observes with `withObservationTracking` from launch instead, which is event-driven and costs an idle app nothing.

## Build order

Milestones M0 through M8, tracked in `PLAN.md`. The system is genuinely usable after M2 (sessions plus tokens) and matches the spec's concept after M4 (usage limits).

Do not reverse-engineer further Claude Code internals before the UI architecture and adapter seams exist.
