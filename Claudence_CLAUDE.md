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

Every number in the UI traces back to one of these five sources. Nothing else. Verified against Claude Code 2.1.257 and 2.1.258 on macOS 26.6.2.

All five are **undocumented internal interfaces**. Each gets an adapter with explicit schema detection and a defined degraded state. No parser reads them directly.

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

Confirmation must be tolerant, not strict. Across 25 real transcripts, 24 carry their `sessionId` within the first 64 KB and one carries none at all in that window. Reject a file only when it names *other* sessions and never this one; treat "no session id found" as inconclusive and accept the name match. A strict implementation silently loses that session.

Record types observed on 2.1.257: `assistant`, `user`, `system`, `attachment`, `mode`, `permission-mode`, `last-prompt`, `ai-title`, `file-history-snapshot`, `file-history-delta`, `queue-operation`, `agent-name`, `atis-latch`, `bridge-session`, `cost-state`. The list grows between releases, which is why an unknown type is skipped rather than treated as malformed.

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

`message.usage` also carries `speed`, `inference_geo`, `iterations[]`, and `cache_creation { ephemeral_5m_input_tokens, ephemeral_1h_input_tokens }`. None are needed for the token total, but that last one splits cache writes by TTL, and one-hour writes are priced differently from five-minute ones. Cost estimation should use it rather than treating every cache write alike.

Assistant records also carry `requestId`, `slug`, `effort`, `entrypoint`, both `sessionId` and `session_id`, and occasionally `isApiErrorMessage`, `apiErrorStatus`, `isAbortedMidStream`. Error records are rare, roughly 3 in 2700, but they still carry a usage block and must be counted.

**These files reach 42 MB.** A 12 MB transcript is ordinary; 42 MB has been measured on this machine. Full re-parsing is forbidden. Persist `(path, inode, byteOffset)` and resume from the offset. A changed inode means rotation: reset the offset to zero.

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

Response shape, captured from a live `HTTP 200` on this account:

```
five_hour   { utilization: 100, resets_at: "2026-09-01T22:49:59.870286+00:00",
              limit_dollars: null, used_dollars: null, remaining_dollars: null }
seven_day   { utilization: 10,  resets_at: "2026-09-06T22:59:59.870313+00:00" }
seven_day_opus / _sonnet / _cowork / _oauth_apps / _omelette   -> null on this account
limits[]    { kind: "session" | "weekly_all" | "weekly_scoped",
              group, percent, severity, is_active, resets_at,
              scope: { model: { display_name, id } } | null }
spend       { percent, severity, limit, used, cap, ... }
extra_usage { utilization, monthly_limit, ... }
amber_ladder, cinder_cove, iguana_necktie, juniper_tide,
nimbus_quill, omelette_promotional, tangelo                    -> feature flags
```

Three corrections that only surfaced by running against the real endpoint:

1. **The percentage field is `utilization`, not `used_percentage`.** Parsing only `used_percentage` and `percent` silently drops both `five_hour` and `seven_day`, leaving a UI that shows a scoped model window and nothing else.

2. **`resets_at` is an ISO-8601 string with six fractional digits and an explicit offset**, not epoch seconds. Epoch seconds is the shape the status-line stdin payload uses; the two sources disagree, so accept both. A default `ISO8601DateFormatter` rejects the fractional seconds and yields no reset time.

3. **The flat section cannot be enumerated openly.** `spend`, `extra_usage` and `nimbus_quill` all carry a `percent` or a `utilization` and are not usage windows. Bound the enumeration to `five_hour`, `seven_day`, and the `seven_day_` prefix. Within that bound, still enumerate rather than hard-code, so a new model scope appears without a code change.

Token refresh: `POST https://platform.claude.com/v1/oauth/token` with `refreshToken`.

Hard constraints on this path:

- Domain allowlist enforced in the request helper itself: `api.anthropic.com`, `console.anthropic.com`, `platform.claude.com`. Redirects off the allowlist are blocked. The token must be structurally incapable of reaching a third party.
- Never log, cache to disk, or display the token.
- Cache responses for 60 s. Back off on 429 and keep serving the cached value.
- Any failure degrades to `Usage unavailable`. Never substitute a guess.

### 2.5 Subagent transcripts — the tokens the parent transcript does not contain

This source was found late, after the application had already shipped totals that were wrong.

A session's subagents do **not** appear in its own transcript. `isSidechain` is false on every parent record and no `agent-name` record is written. They live in a directory beside the parent file:

```
~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.jsonl
~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.meta.json
```

The `.jsonl` is an ordinary transcript with full `message.usage` and `tool_use` blocks, read with the same `(path, inode, byteOffset)` cursor discipline as the parent, under cursor keys namespaced `subagent:<parent>:<id>` so they cannot collide with a session id. The `.meta.json` carries `agentType`, `description`, `toolUseId` and `spawnDepth`; those four fields and no others are read, and section 3.1 records why.

Measured on this repository's own session while this section was written: parent 141.83M tokens, 20 subagents 128.56M, so **47% of the true total was invisible**. The figure has ranged from 41% to 48% across sessions. Subagents have no process of their own and their tokens are billed to the parent, so they roll up into the parent's total as `AISession.combinedUsage`, with the split kept separately so nothing double counts and the breakdown can be shown.

Two constraints this source imposes that the others do not:

- **A cursor and the total it corresponds to must be durable together.** The read cursors were persisted from the start; the accumulated totals were not. A session resumed after a relaunch therefore added its delta to zero and reported a fraction of what it had spent, and the collapsed figure was then written back over the session row, rewriting the daily rollup downward. Schema version 2 persists both halves.
- **An unreadable directory is not an empty one.** A locator that returns "no subagents" for a directory it could not read will have its callers conclude that every subagent vanished. The locator reports the two cases separately for that reason.

---

## 3. Privacy contract

Local-first. No backend, no telemetry, no sync.

The application makes two outbound requests, both on the usage path in 2.4: the usage `GET`, and a conditional token-refresh `POST` when the access token has expired. Nothing else leaves the machine. An earlier version of this section claimed a single request; it overlooked the refresh, and the Settings privacy panel must describe what the code does rather than what this document once said.

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

From `subagents/agent-<id>.meta.json`, which is the file Claude Code writes beside a subagent transcript, exactly the four fields `SubagentLocator.Meta` declares and no others:

```
agentType                           subagent type: general-purpose, Explore
description                         task label written when the subagent spawns
toolUseId                           the parent tool_use id that created it
spawnDepth                          nesting depth, 1 for a direct subagent
```

**Must never read, store, or display:**

```
content[].text                      prompt and response text
tool_result content                 command output, file contents
file-history-snapshot / -delta      file contents
attachment payloads
the raw command string
```

The subagent block was added on 2026-09-02, when subagent tracking landed and `description` began to reach both the session detail view, as `AISubagent.taskDescription`, and the database, as `subagent_totals.task_description`. Until then the code read a field this list did not name, which is the defect the amendment closes.

What it covers is the spawn metadata of a subagent and nothing about its work. It is not the subagent's prompt, not its messages, not its results. Those are in the sibling `agent-<id>.jsonl`, which is parsed under the rules above like any other transcript. If `meta.json` carries fields beyond the four named here, they are deliberately not decoded; widening `Meta` is an amendment to this section rather than a change to a decoder.

The reasoning has two halves and both belong on the record. The case for reading `description` is that Claude Code writes it at spawn time, so it is a label produced by the tool rather than content produced by a person or a model, and it is the only thing that distinguishes one subagent row from another: without it the list is eight identical rows named `agent-01` through `agent-08`, which is a display with no reason to exist. The case against is that it is free text of arbitrary content. Whoever spawns the subagent chooses the string, nothing constrains its length or its subject, and a task description containing a secret puts that secret into this application's SQLite file, where the rest of section 3 promises nothing of the kind will be. Both statements are true at once. The field is kept because the feature is worthless without it, not because the exposure is nil, and the next field proposed from this file is argued the same way rather than admitted on the grounds that the tool wrote it.

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
| WAITING | registry `status` (observed: `waiting`) | yes |
| PERMISSION | not yet derivable | no |
| ERROR | not yet derivable | no |

Observed so far: `busy` on interactive sessions, `idle` on background records, and `waiting` while a session is blocked on the user. `waiting` was listed as not derivable until a live capture on Claude Code 2.1.258, polling `~/.claude/sessions/<pid>.json` every two seconds, caught one session moving `busy -> waiting -> busy -> idle`. The status string is written by the source; nothing is being inferred. Two states remain underivable, PERMISSION and ERROR, and they stay out of the UI.

The adapter accumulates every distinct raw value it sees into `SessionRegistryAdapter.observedStatusValues`, so the full set grows as the application runs. `updatedAt` governs only the fallback for an unknown or missing status, never the mapping of a known one. `waiting` is mapped directly for the same reason `busy` is: `updatedAt` moves on a transition, so a session that has been waiting on the user for minutes carries a minutes-old timestamp, and routing it through the recency fallback displayed it as Idle.

The full set of registry `status` values must be enumerated by observation. Until a state is proven derivable it does not appear in the UI. Designing UI for states with no data source produces a display that silently lies.

Indicators always pair a glyph with text. Color is never the sole carrier of meaning.

```
* Working        o Idle          v Completed     ^ Needs you
! Permission     x Error
```

`Needs you` is the wording for WAITING. "Waiting" on its own does not say who is being waited on and reads as a synonym for Idle in the row directly above it. Its glyph is a raised hand, the one silhouette in the set that is not a circle, so the state survives being read at 10pt and without colour. Its colour is the accent, not a rung of the severity ramp: a session waiting on the user is not a fault.

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
Read + file_path            ->  Reading package.json
Edit / Write + path         ->  Editing Menu.tsx
Grep / Glob                 ->  Searching codebase
Bash                        ->  Running a command
WebFetch / WebSearch        ->  Searching the web
Agent                       ->  Running a subagent
TaskCreate / TaskUpdate     ->  Planning
unknown tool                ->  Running <tool name>
no assistant record recently->  Waiting
```

Bash cannot be described more precisely than its tool name allows, because the command string is off-limits per 3.1. Prefer a vaguer honest label over a precise leaky one.

An earlier version of this table carried `Bash + test-shaped intent -> Running tests`. It is removed: deciding that an intent is test-shaped requires reading the command, so the row contradicted section 3.1.

Tool names move between releases. On 2.1.257 the agent-spawn tool is `Agent`, not `Task`, and `TodoWrite` has been replaced by `TaskCreate` / `TaskUpdate`. Map the old names too, so a transcript written by an older build still reads. `Skill`, `ToolSearch`, `AskUserQuestion` and `ExitPlanMode` are also live; they fall through to the unknown-tool branch, which is the correct outcome.

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
Only the two usage hosts contacted, verifiable by inspection
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
