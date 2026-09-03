import Foundation

/// The explanation attached to every metric, transcribed from the design.
///
/// The design writes an explanation for nearly every number it draws, and those
/// sentences are the product's only place where the derivation of a figure is
/// stated in plain words. They are transcribed here exactly as section 6 of
/// `Design/UI-CONTRACT.md` records them: no paraphrase, no shortening, no
/// tidying of punctuation. The typographic quote in `subagent's`, the em dashes,
/// and the en dash in `70-85%` are all deliberate and are preserved as written.
///
/// Two of the transcribed strings said something untrue about how this
/// application works, and for a while they sat in `disputed`, reachable from no
/// lookup, so the two metrics they describe carried no explanation at all. That
/// was the wrong resolution twice over: it left 2 of the design's 36 tooltips
/// unreachable, and it left the two figures whose provenance is *least* obvious
/// — an estimated context percentage and a subagent record count — as the only
/// two on screen with nothing explaining them.
///
/// They are now corrected and live. `disputed` keeps the design's original
/// wording verbatim beside the correction, so the change is auditable and
/// nobody re-transcribes the original believing it was simply missed. Each
/// correction changes exactly the clause that was false and leaves the rest of
/// the sentence alone; `disputed` says what changed and why.
enum TooltipText {

    /// A tooltip's two parts. The design draws the title in bold above the body.
    struct Entry: Equatable {
        let title: String
        let body: String
    }

    // MARK: - Lookups
    //
    // Keys are the design's own. `tip` is keyed by metric, `breakdown` by the
    // breakdown row's visible label, and `fact` by the session-fact name, so a
    // view can pass the label it already renders rather than inventing a key.

    static func tip(_ key: String) -> Entry? { tips[key] }

    static func breakdown(_ label: String) -> Entry? { breakTips[label] }

    static func fact(_ name: String) -> Entry? { metaTips[name] }

    // MARK: - TIPS (17 entries)
    //
    // Fourteen are the design's verbatim; `ctx`, `active` and `cost` are
    // corrected. See `disputed`.
    //
    // Three of the seventeen are not reachable from any view, and that is
    // deliberate rather than an oversight: `fresh`, `cw` and `out` describe the
    // four token-breakdown rows, and those rows are keyed by their visible label
    // into `breakTips` below, whose wording names the exact `message.usage`
    // field each figure comes from. The `breakTips` entry is the better answer
    // at the only place either could appear. They stay because this table is a
    // transcription of the design's own, and a reader comparing the two should
    // find it complete.

    static let tips: [String: Entry] = [
        "power": Entry(
            title: "Claude Power · 5h",
            body: "Share of the rolling 5-hour usage limit already consumed. Read from the usage API utilization field. At 100% Claude Code pauses until the window resets."
        ),
        "reset": Entry(
            title: "Reset timer",
            body: "Time left before this window starts counting from zero again. Derived from the resets_at timestamp returned by the API."
        ),
        "seven": Entry(
            title: "7 day window",
            body: "Weekly limit across all models, counted as a rolling 7-day window rather than a calendar week."
        ),
        "fable": Entry(
            title: "Weekly scoped limit",
            body: "A weekly cap tied to one specific model. It is tracked separately from the all-model weekly window, so it can run out while the others are healthy."
        ),
        "energy": Entry(
            title: "Token energy",
            body: "Every token this session has consumed: fresh input + cache write + cache read + output. This single total is what every bar in the app measures."
        ),
        "burn": Entry(
            title: "Burn rate",
            body: "Tokens consumed per minute, computed over a recent rolling window — not an average since the session started, so it reacts to what is happening now."
        ),
        "today": Entry(
            title: "Tokens today",
            body: "All tokens across every session today, measured from the transcript files. Measured, not estimated."
        ),
        "cost": Entry(
            title: "Estimated cost today",
            body: "Estimate from a per-model price table, over the sessions that did work today. It is an estimate, never the amount actually billed. A model missing from the table reads Cost unavailable. The Projects table below covers all time, not today, so the two totals are not meant to match."
        ),
        "active": Entry(
            title: "Active sessions",
            body: "Sessions doing work right now, out of the sessions with a live process. A session waiting on you is live but not active. Liveness is confirmed by pid plus process start time, never by counting processes named claude."
        ),
        "status": Entry(
            title: "Session status",
            body: "Reported by the session registry: Working (busy), Idle, or Completed once the registry file is gone and the process has exited."
        ),
        "activity": Entry(
            title: "Current activity",
            body: "Translated from the tool name and file path only — Editing, Reading, Searching, Running a command. Command strings and message text are never read."
        ),
        "fresh": Entry(
            title: "Fresh input",
            body: "Input tokens sent uncached. The most expensive part of the bill per token."
        ),
        "cw": Entry(
            title: "Cache write",
            body: "Tokens written into the prompt cache. Five-minute and one-hour cache writes are priced differently, so they are tracked separately."
        ),
        "cr": Entry(
            title: "Cache read",
            body: "Tokens served from the prompt cache, roughly ten times cheaper than fresh input. Shown apart from input so the display agrees with the bill."
        ),
        "out": Entry(
            title: "Output",
            body: "Tokens the model generated, including the thinking tokens shown in brackets."
        ),
        "chart": Entry(
            title: "Daily usage",
            body: "Tokens per day for the last 7 days, split into input and output. Measured by tailing each transcript from a stored byte offset instead of re-parsing it."
        ),
        "ctx": Entry(
            title: "Context window",
            body: "How much of the model's context window the newest request used. The used value is measured from that request; the limit is Claudence's own model table, not something the transcript states, so the reading is labelled Estimated. Under 70% Healthy, 70–85% Attention, 85–95% Warning, above 95% Critical. When that table has no limit for the model, the amount in use is still shown, with no bar and no percentage."
        ),
    ]

    // MARK: - BREAK_TIPS (4 entries, keyed by breakdown row label)

    static let breakTips: [String: Entry] = [
        "Fresh input": Entry(
            title: "Fresh input",
            body: "usage.input_tokens — prompt tokens sent uncached this session. Small in count, largest in price per token."
        ),
        "Cache write": Entry(
            title: "Cache write",
            body: "usage.cache_creation_input_tokens — tokens written into the prompt cache. Split by 5-minute and 1-hour TTL, which are priced differently."
        ),
        "Cache read": Entry(
            title: "Cache read",
            body: "usage.cache_read_input_tokens — tokens re-served from the cache at roughly a tenth the price of fresh input."
        ),
        "Output": Entry(
            title: "Output",
            body: "usage.output_tokens — everything the model generated, thinking tokens included."
        ),
    ]

    // MARK: - META_TIPS (4 entries, keyed by session-fact name)
    //
    // Eleven entries were pruned here (9.10): `PID`, `Kind`, `CC version`,
    // `Session id` and `Registry` were the session-diagnostic tiles 9.9
    // deleted from `SessionFactsView`, and `Parent`, `Agent type`,
    // `Spawned by`, `Tool calls`, `Share` and `Records` were facts from the
    // subagent detail sheet 9.9 deleted outright. `.fact(name)` is keyed on a
    // visible label a view still renders, and nothing renders any of those
    // eleven any more — `SessionFactsView` and `TranscriptFactsBar` are the
    // only two callers left, and between them they render exactly `Model`,
    // `Git branch`, `Started`, `Duration`, `Parsed` and `Service tier`.
    //
    // `Share`, title `Share of parent`, is the specific entry 9.10 went
    // looking for: it and the deleted sheet's own `Share` column header used
    // to sit side by side, which is what that item's `Share of the parent`
    // and `Share` pairing described. The sheet is gone, so the pairing no
    // longer renders anywhere, and the orphaned entry is what would have let
    // it come back by accident the next time someone wired a `.tooltip(fact:)`
    // up without checking whether the key was still live.
    //
    // `Git branch` is the design's verbatim wording. See `disputed` for the
    // one correction among the four that remain.

    static let metaTips: [String: Entry] = [
        "Model": Entry(
            title: "Model",
            body: "message.model from the most recent assistant record. Determines which price row the cost estimate uses."
        ),
        "Started": Entry(
            title: "Started at",
            body: "Process start time, recorded in UTC and shown in your local timezone."
        ),
        "Duration": Entry(
            title: "Duration",
            body: "Elapsed wall-clock time since the session started, not the time it spent working."
        ),
        "Git branch": Entry(
            title: "Git branch",
            body: "gitBranch from the transcript, so you can tell two sessions in the same project apart."
        ),
    ]

    // MARK: - Disputed
    //
    // The design's original wording for the four strings that were wrong about
    // this application, kept beside the correction now shipping in its place.
    // Nothing reads this table; it exists so the edit is auditable.

    /// What the design says, for the four strings this file corrects.
    ///
    /// - `Records`: says subagent records live "in the parent transcript". They
    ///   do not. `SubagentLocator` finds them in
    ///   `<sessionId>/subagents/agent-<id>.jsonl`, a separate file per subagent,
    ///   and the whole reason `SubagentTracker` exists is that the parent
    ///   transcript contains none of them. Shipping this sentence would tell the
    ///   user the opposite of the fact that drove the last correctness fix.
    /// - `ctx`: says the meter is "Shown only when the source gives both the
    ///   used value and the limit". No source gives the limit. `message.usage`
    ///   carries no context limit at all, so the denominator comes from this
    ///   application's own `ContextWindowTable`, which is why `PLAN-UI.md`
    ///   decision 1 requires the figure to be labelled Estimated. The sentence
    ///   claims a provenance the number does not have.
    /// - `active`: described every session with a live process, which is the
    ///   tile's denominator and not the number it prints. The tile reads
    ///   `1 / 2 live`, and the sentence explained only the 2. `MonitorSnapshot`
    ///   holds the one definition of the word: a session doing work now.
    /// - `cost`: named no range, and neither did the Projects table under it,
    ///   which covers all time. The two figures were drawn on one window with
    ///   nothing to say why they differ.
    static let disputed: [String: Entry] = [
        "Records": Entry(
            title: "Transcript records",
            body: "Assistant records attributed to this subagent in the parent transcript. Each one carries its own usage block."
        ),
        "active": Entry(
            title: "Active sessions",
            body: "Interactive sessions with a live process. Liveness is confirmed by pid plus process start time, never by counting processes named claude."
        ),
        "cost": Entry(
            title: "Estimated cost",
            body: "Estimate from a per-model price table. It is an estimate, never the amount actually billed. A model missing from the table reads Cost unavailable."
        ),
        "ctx": Entry(
            title: "Context window",
            body: "How much of the session context is in use. Shown only when the source gives both the used value and the limit. Under 70% Healthy, 70–85% Attention, 85–95% Warning, above 95% Critical."
        ),
    ]
}
