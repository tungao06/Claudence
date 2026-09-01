# Claudence — Product and Engineering Specification

**AI Coding Agent Monitor for macOS**

> See your AI. Know your usage. Stay in control.

A macOS Menu Bar application that monitors AI coding agents, starting with Claude Code.

This document is the product and engineering contract. `CLAUDE.md` is the short operational summary for agents; `PLAN.md` tracks execution.

---

## 1. Product

### 1.1 What it answers

The user must answer all four of these within three seconds of opening the popover:

```
How much power do I have?
What is consuming it?
What is Claude doing?
Do I need to do anything?
```

### 1.2 Core differentiator

Claude Code's own status line already shows usage for **one** session — the one you are looking at. A status line cannot see the others.

Claudence shows **every session at once**, across every project, from the menu bar. Multi-session visibility is the reason this product exists. When a design decision trades away multi-session clarity for anything else, multi-session clarity wins.

### 1.3 Visual metaphor

A power meter, not an analytics dashboard.

> Sessions are machines. Tokens are energy. Usage limits are the battery.

Reference points: iStat Menus, Raycast, Activity Monitor, macOS battery UI. Not: enterprise admin dashboards.

### 1.4 Fixed visual priority

```
power meter  ->  active sessions  ->  analytics
```

Never reorder this. Analytics never appears above sessions; sessions never appear above the meter.

---

## 2. Data sources

Every number in the UI traces back to one of these four sources. Nothing else. Verified against Claude Code 2.1.257 on macOS 26.6.2.

All four are **undocumented internal interfaces**. Each gets an adapter with explicit schema detection and a defined degraded state. No parser reads them directly.

### 2.1 Session registry — live session discovery

```
~/.claude/sessions/<pid>.json
```

```json
{"pid":42541,
 "sessionId":"6ff2ff43-cf68-4328-8c8f-0ceb6c93f768",
 "cwd":"/Users/tungao/TungAo-Project/project/Claudence",
 "startedAt":1788290824722,
 "procStart":"Tue Sep  1 19:27:02 2026",
 "version":"2.1.257",
 "kind":"interactive",
 "entrypoint":"cli",
 "name":"claudence-06",
 "nameSource":"derived",
 "status":"busy",
 "updatedAt":1788291241627,
 "messagingSocketPath":"/tmp/cc-socks/42541.sock"}
```

Fields present in real files but omitted above: `peerProtocol`, `peerFeatures`, `pidDomain`, `nameSince`, `statusUpdatedAt`, `bridgeSessionId`. Model what is useful, ignore the rest.

Rules:

- Filter to `kind == "interactive"`. `kind: "bg"` is common and is a background job, not a user session; those records also carry a `jobId` field and use `nameSource: "auto"`.
- The directory contains `<pid>.<64-hex>.key` siblings. Filter on the `.json` suffix so they never reach the decoder or inflate the malformed count.
- Versions are not uniform across concurrent sessions: `2.1.252` and `2.1.257` were live at the same time. Schema detection is per record, never global.
- Liveness requires **both** `kill(pid, 0)` succeeding (treat `EPERM` as alive, `ESRCH` as dead) **and** the live process's start time matching `procStart`. PID alone is not sufficient: PIDs are reused after reboot and would resurrect a dead session under a stranger's process. Read the live start time from `sysctl` `KERN_PROC_PID` as `kp_proc.p_starttime`.

- **`procStart` is UTC**, in C-locale `ctime` layout: `EEE MMM d HH:mm:ss yyyy` with `en_US_POSIX`. Verified: pid 42541's file reads `Tue Sep  1 19:27:02 2026` while `ps -o lstart` on the same pid reads `Wed 2 Sep 02:27:02 2026` in Asia/Bangkok. A naive local-time parse rejects every session and produces a permanently empty application. Compare with about 2 seconds of tolerance, since `procStart` is second-resolution and `p_starttime` is microseconds. An unparseable value is treated as dead, which hides a live session rather than showing a stranger's process, and is counted so the failure is visible.

- **`updatedAt` tracks status transitions, not activity.** It is consistently identical to `statusUpdatedAt`. A session busy for minutes carries an `updatedAt` many minutes old; a gap of 910 s was observed on a session that was actively working. Never treat it as a heartbeat, and never age-gate a `busy` status against it. The stale-`busy` case that gating would catch is already handled by the liveness filter, which drops the record once the process is gone.
- Stale files persist when a session crashes. Reap them on every scan.
- Watch the directory with FSEvents. Debounce 250 ms. Do not poll.

### 2.2 Process list — fallback only

`ps` is **not** a discovery mechanism. On a normal machine most processes named `claude` are not sessions:

```
claude bg-pty-host ...        infrastructure
claude bg-spare ...           infrastructure
claude daemon run ...         infrastructure
claude --chrome-native-host   infrastructure
claude                        <- actual interactive session
```

Naive process counting overcounts by roughly 4x. Use `ps` only to corroborate liveness of a PID already found in the registry, never to enumerate.

### 2.3 Transcript — tokens and activity

```
~/.claude/projects/<slug>/<sessionId>.jsonl
```

`<slug>` is `cwd` with every `/` replaced by `-`. Treat this as a hint, not a guarantee: confirm by reading `sessionId` inside the file. Never rely on the path derivation alone.

Record types observed: `assistant`, `user`, `system`, `attachment`, `mode`, `permission-mode`, `last-prompt`, `ai-title`, `file-history-snapshot`, `file-history-delta`.

Only `assistant` records matter. Each carries `cwd`, `gitBranch`, `version`, `timestamp`, `sessionId`, and:

```json
"message": {
  "model": "claude-sonnet-5",
  "usage": {
    "input_tokens": 2,
    "cache_creation_input_tokens": 22018,
    "cache_read_input_tokens": 24858,
    "output_tokens": 147,
    "output_tokens_details": {"thinking_tokens": 16},
    "service_tier": "standard"
  },
  "content": [ ... ]
}
```

**These files reach 12 MB and beyond.** Full re-parsing is forbidden. Persist `(path, inode, byteOffset)` and resume from the offset. A changed inode means rotation: reset the offset to zero.

### 2.4 Usage limits — OAuth API

Credentials live in the macOS Keychain, not on disk:

```
service = "Claude Code-credentials"   class = genp
-> claudeAiOauth.{accessToken, refreshToken, rateLimitTier}
```

`~/.claude/.credentials.json` may not exist. Keychain is the primary source; the file is the fallback.

```
GET https://api.anthropic.com/api/oauth/usage
  Authorization: Bearer <accessToken>
  anthropic-beta: oauth-2025-04-20
  Accept: application/json
```

Response carries flat windows plus a scoped-limit array:

```
five_hour  { used_percentage, resets_at }
seven_day  { used_percentage, resets_at }
limits[]   { kind: "weekly_scoped", scope.model.{display_name,id}, percent, resets_at }
```

Enumerate the scoped entries rather than hard-coding model names, so a new model appears without a code change.

Token refresh: `POST https://platform.claude.com/v1/oauth/token` with `refreshToken`.

Hard constraints on this path:

- Domain allowlist enforced in the request helper itself: `api.anthropic.com`, `console.anthropic.com`, `platform.claude.com`. Redirects off the allowlist are blocked. The token must be structurally incapable of reaching a third party.
- Never log, cache to disk, or display the token.
- Cache responses for 60 s. Back off on 429 and keep serving the cached value.
- Any failure degrades to `Usage unavailable`. Never substitute a guess.

---

## 3. Privacy contract

Local-first. No backend, no telemetry, no sync. The only outbound request in the entire application is the usage API call in 2.4.

### 3.1 Field allowlist

This is enforced by tests, not by discipline. A test fails if the parser emits anything outside this list.

**May read:**

```
message.usage.*                     token counts
message.model                       model id
content[].name                      tool name: Edit, Bash, Read
content[].input.file_path           path only
content[].input.command             SHA256 hash only, never the string
timestamp, sessionId, cwd, gitBranch, version
```

**Must never read, store, or display:**

```
content[].text                      prompt and response text
tool_result content                 command output, file contents
file-history-snapshot / -delta      file contents
attachment payloads
the raw command string
```

### 3.2 Consequence

Section 1.1's "what is Claude doing" is answered from tool name plus file path only. `Editing Menu.tsx` is derivable. Showing the raw command `npm run test -- --coverage` is **not** permitted — command strings routinely carry API keys, connection strings, and tokens. The earlier version of this spec asked for raw commands as secondary detail; that requirement is withdrawn.

### 3.3 Settings disclosure

Settings must contain a plain-language panel listing exactly which files are read and which single network request is made.

---

## 4. Architecture

```
Claude Code
     |
     v
Source Adapters        sessions/*.json | *.jsonl | Keychain+API
     |                 schema detection, version fallback
     v
Provider              ClaudeCodeProvider  (Codex, GeminiCLI later)
     |
     v
Normalized Domain Model
     |
     v
Store                 SQLite: sessions, usage samples, offsets, rollups
     |
     v
View Model
     |
     +-- Menu Bar   +-- Popover   +-- Dashboard   +-- Notifications
```

The UI layer never touches a file path, a process, or the network. If a view needs a new fact, it is added to the domain model first.

### 4.1 Provider abstraction

Present from day one. Only `ClaudeCodeProvider` ships in MVP; the seam exists so `CodexProvider` and `GeminiCLIProvider` cost a file rather than a refactor.

```swift
enum AIProviderType { case claudeCode, codex, geminiCLI }

enum SessionStatus {
  case running, idle, waiting, permission, error, completed
}

struct TokenUsage {
  var freshInput: Int          // input_tokens
  var cacheCreation: Int       // cache_creation_input_tokens
  var cacheRead: Int           // cache_read_input_tokens
  var output: Int              // output_tokens
  var thinking: Int            // output_tokens_details.thinking_tokens

  var billableInput: Int { freshInput + cacheCreation + cacheRead }
  var total: Int { billableInput + output }
}

struct AISession {
  let id: String               // sessionId
  let provider: AIProviderType
  let pid: Int32
  let procStart: String        // paired with pid for liveness
  let projectName: String      // registry `name`
  let workingDirectory: String
  var status: SessionStatus
  var currentActivity: Activity?
  let startedAt: Date
  var lastActivityAt: Date
  var usage: TokenUsage
  var model: String?
}

struct Activity {
  let verb: String             // Editing, Running, Reading, Searching
  let subject: String?         // file name, never a command string
}

struct UsageWindow {
  let name: String             // five_hour, seven_day, seven_day_opus
  let usedPercent: Double?
  let resetsAt: Date?
}
```

`total` is the single definition of "tokens" across the whole app. Nothing computes its own.

---

## 5. Token model

### 5.1 Formula

```
billableInput = freshInput + cacheCreation + cacheRead
total         = billableInput + output
```

### 5.2 Display

The energy bar uses `total`. The breakdown always shows cache separately, because cache reads cost roughly an order of magnitude less than fresh input and collapsing them into one number makes the display disagree with the bill.

```
Token Energy
##############....  42.8k

Fresh input      2.1k
Cache write     22.0k
Cache read      24.9k
Output           8.2k
                -----
Total           57.2k
```

### 5.3 Formatting

```
1,200      -> 1.2k
12,400     -> 12.4k
128,000    -> 128k
1,240,000  -> 1.24M
```

### 5.4 Burn rate

```
Token Rate
.:il|I|li:.
12.4k/min
```

Sparkline is subtle and secondary. Rate is computed over a rolling window, not since session start.

---

## 6. Session status

The six states from the original spec are kept only where the data supports them.

| State | Source | MVP |
|---|---|---|
| RUNNING | registry `status` (observed: `busy`) | yes |
| IDLE | registry `status` (observed: `idle`) | yes |
| COMPLETED | registry file removed, process gone | yes |
| WAITING | not yet derivable | no |
| PERMISSION | not yet derivable | no |
| ERROR | not yet derivable | no |

Observed so far: `busy` on interactive sessions, `idle` on background records. The adapter accumulates every distinct raw value it sees into `SessionRegistryAdapter.observedStatusValues`, so the full set grows as the application runs. `updatedAt` governs only the fallback for an unknown or missing status, never the mapping of a known one.

The full set of registry `status` values must be enumerated by observation. Until a state is proven derivable it does not appear in the UI. Designing UI for states with no data source produces a display that silently lies.

Indicators always pair a glyph with text. Color is never the sole carrier of meaning.

```
* Working        o Idle          v Completed
! Permission     x Error         ~ Waiting
```

Animate active states only.

---

## 7. Interface

### 7.1 Menu bar

Compact is a hard requirement. The menu bar is shared and narrow on a single display.

```
Default        (*) 42%
Multi-session  (*) 2 . 42%     (opt-in)
Idle           (*) Claude
Critical       (*) 98%
Permission     (*) !
```

Width must not exceed 60 pt. Session count is opt-in, not default.

### 7.2 Popover

```
+---------------------------------------+
|  CLAUDENCE                        (*)  |
|                                       |
|          Claude Power                 |
|                                       |
|       #################......         |
|                 72%                   |
|           Reset in 2h 14m             |
|                                       |
|  -----------------------------------  |
|                                       |
|  ACTIVE SESSIONS                  2   |
|                                       |
|  * claudence-06                       |
|    ~/project/Claudence                |
|    Editing SessionStore.swift         |
|    ###########...  42.8k              |
|                                       |
|  * hr-leave-management-14             |
|    ~/project/hr-leave-management      |
|    Running tests                      |
|    ######.......  18.2k               |
|                                       |
|  -----------------------------------  |
|                                       |
|  Today   438k tokens   $3.42 est.     |
|                                       |
|              Open Dashboard ->        |
+---------------------------------------+
```

Per session, in priority order: status, project, current activity, token energy, duration, burn rate. Fields below activity are progressively disclosed, not all shown at rest.

### 7.3 Dashboard

Same fixed order as 1.4: global usage, then sessions, then session detail, then history and analytics.

Windows are switchable (`5h | 7d`) plus any model-scoped weekly caps the API returns.

---

## 8. Activity translation

Raw tool calls become human phrasing. Derived from tool name plus `file_path` only.

```
Read + package.json         ->  Reading package.json
Edit + src/Menu.tsx         ->  Editing Menu.tsx
Bash                        ->  Running a command
Bash + test-shaped intent   ->  Running tests
Grep / Glob                 ->  Searching codebase
no assistant record recently->  Waiting
```

Bash cannot be described more precisely than its tool name allows, because the command string is off-limits per 3.1. Prefer a vaguer honest label over a precise leaky one.

---

## 9. Context, cost, prediction

### 9.1 Context usage

Show only if the source provides both used and limit. Thresholds are named constants, not literals in views.

```
< 70%    Healthy
70-85%   Attention
85-95%   Warning
> 95%    Critical
```

Never assert a context limit the source did not provide.

### 9.2 Cost

Estimated only, and always labeled. Requires a per-model price table; a model absent from the table yields `Cost unavailable`, not zero and not an average.

### 9.3 Prediction

V3. Always labeled an estimate, never a guarantee.

### 9.4 The rule behind all three

Never fabricate. When a metric cannot be derived, the UI says so:

```
Usage unavailable
```

An honest gap outranks a plausible invention.

---

## 10. Notifications

Four events only:

```
Permission required     session name + what is blocked
Usage at 90%            approximate remaining
Session completed       name, tokens, duration
Session failed          name, exit condition
```

Deduplicate by session and event type. Rate limit per session. A monitoring tool that spams is uninstalled.

`Permission required` ships only once section 6 proves that state is derivable.

---

## 11. Quick actions

```
Open Terminal
Open Project
Copy Path
View Activity
```

`Stop Session` terminates someone's live work and is destructive. It ships only with an explicit confirmation dialog naming the session, or it does not ship. `Send Message` is out of scope until Claude Code exposes a supported mechanism.

---

## 12. Design system

```
Minimal, monochrome-first, soft contrast,
rounded, compact, technical, calm, premium
```

Avoid: large gradients, neon, excessive cards, 3D, heavy shadows, oversized type, clutter.

One accent color. All state color flows through semantic tokens (`healthy`, `attention`, `warning`, `critical`) — never a hard-coded hex in a view.

### 12.1 Animation

Animation communicates state change, nothing else. An energy bar easing to a new value, an active indicator pulsing gently, a ring animating on change. No particles, no bouncing, no constant motion. Honor Reduce Motion.

### 12.2 Accessibility

VoiceOver labels on every indicator, keyboard navigation, high contrast, Dynamic Type where applicable, and never color alone.

---

## 13. Performance budget

Always-running background utility. These are limits, not aspirations.

```
Idle CPU            < 0.5%
Memory              < 60 MB resident
Cold start          < 1 s
Transcript re-scan  < 50 ms for a 12 MB file
UI                  no main-thread file or network work, ever
```

Event-driven throughout. FSEvents with debounce, not polling. Offset-based tailing, not re-parsing.

---

## 14. Engineering rules

1. Detect paths dynamically. Hard-code nothing outside `~/.claude`.
2. Never assume a Claude Code version. Detect schema, adapt, or degrade.
3. Wrap every external data source in an adapter. Parsers never touch the filesystem directly.
4. Malformed or unknown records are skipped silently, never fatal.
5. Never fabricate a number. Distinguish measured from estimated in the UI itself.
6. Absent Claude Code, zero sessions, and denied permissions are ordinary states with defined UI.
7. Never block the main thread.
8. Parsers, token math, and the privacy allowlist require unit tests. Session discovery requires integration tests against golden fixtures.
9. Keep one golden JSONL and one golden registry fixture per supported Claude Code version.
10. Mock values live in a single fixture file, never inline in views.

---

## 15. Scope

### MVP

```
[ ] Menu bar app, launch at login
[ ] Session discovery via registry
[ ] Project, working directory, duration
[ ] Session status (running / idle / completed)
[ ] Current activity
[ ] Token usage and breakdown
[ ] 5h / 7d usage windows
[ ] Power meter, token bars
[ ] Compact popover, session detail
[ ] SQLite persistence
[ ] Notifications (3 derivable events)
[ ] Settings with privacy disclosure
```

### V2

```
[ ] Context usage
[ ] Burn rate and sparkline
[ ] Cost estimation
[ ] Session timeline, daily and weekly graphs
[ ] Project analytics
[ ] Search, CSV/JSON export
```

### V3

```
[ ] Codex and Gemini CLI providers
[ ] Usage prediction
[ ] Anomaly detection
[ ] Optional sync
```

### Explicitly not before MVP works

```
AI-generated summaries, cloud sync, team dashboard,
remote monitoring, multi-device sync, sending commands to Claude
```

---

## 16. Definition of done — MVP

**Function**

```
Two concurrent sessions appear as two rows with correct cwd
Closing one removes it within 1 s
Token totals within 2% of Claude Code's own accounting
5h / 7d windows render, or say unavailable
```

**Reliability**

```
Claude Code absent          -> idle state, no crash
Zero sessions               -> idle state
Malformed transcript line   -> skipped, session still tracked
Network down                -> Usage unavailable
Keychain access denied      -> Usage unavailable, app still works
Stale registry file         -> reaped, not shown
```

**Privacy**

```
Test suite fails if any disallowed field escapes the parser
Only one outbound host contacted, verifiable by inspection
```

**Experience**

```
State understood in under 3 seconds
Menu bar under 60 pt
Idle CPU under 0.5%
Native macOS feel
```

---

## 17. Naming

**Claudence** = Claude + Presence. Claude is always present in the workflow; this makes that presence visible.

Positioning line: *AI Coding Agent Monitor for macOS*.

The product should never feel like it is watching the developer. It is a power meter for an AI workflow.
