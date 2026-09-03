import Foundation
import ClaudenceCore

/// The explanation attached to every metric, transcribed from the design.
///
/// The design writes an explanation for nearly every number it draws, and those
/// sentences are the product's only place where the derivation of a figure is
/// stated in plain words. They are transcribed here exactly as section 6 of
/// `Design/UI-CONTRACT.md` records them: no paraphrase, no shortening, no
/// tidying of punctuation. The typographic quote in `subagent's`, the em dashes,
/// and the en dash in `70-85%` are all deliberate and are preserved as written
/// in the English half of every entry; the Thai half says the same thing in a
/// Thai developer's own words rather than glossing the English sentence by
/// sentence.
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

    /// A tooltip's two parts, each in both languages. The design draws the
    /// title in bold above the body.
    struct Entry: Equatable {
        let title: Phrase
        let body: Phrase
    }

    // MARK: - Lookups
    //
    // Keys are the design's own, in English, and stay that way regardless of
    // display language: `tip` is keyed by metric, `breakdown` by the breakdown
    // row's visible English label, and `fact` by the session-fact's visible
    // English name, so a view can pass the label it already has -- or, once it
    // carries a `Phrase`, that phrase's `.en` -- rather than inventing a
    // separate key that would also need to survive a language switch.

    static func tip(_ key: String) -> Entry? { tips[key] }

    static func breakdown(_ label: String) -> Entry? { breakTips[label] }

    static func fact(_ name: String) -> Entry? { metaTips[name] }

    // MARK: - TIPS (17 entries)
    //
    // Fourteen are the design's verbatim English; `ctx`, `active` and `cost`
    // are corrected. See `disputed`.
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
            title: Phrase(en: "Claude Power \u{00B7} 5h", th: "Claude Power \u{00B7} 5 ชม."),
            body: Phrase(
                en: "Share of the rolling 5-hour usage limit already consumed. Read from the usage API utilization field. At 100% Claude Code pauses until the window resets.",
                th: "สัดส่วนของโควต้าการใช้งานแบบ rolling 5 ชั่วโมงที่ใช้ไปแล้ว อ่านค่าจากฟิลด์ utilization ของ usage API เมื่อถึง 100% Claude Code จะหยุดทำงานจนกว่าหน้าต่างจะรีเซ็ต"
            )
        ),
        "reset": Entry(
            title: Phrase(en: "Reset timer", th: "ตัวจับเวลารีเซ็ต"),
            body: Phrase(
                en: "Time left before this window starts counting from zero again. Derived from the resets_at timestamp returned by the API.",
                th: "เวลาที่เหลือก่อนหน้าต่างนี้จะเริ่มนับใหม่จากศูนย์ คำนวณจาก timestamp resets_at ที่ API ส่งกลับมา"
            )
        ),
        "seven": Entry(
            title: Phrase(en: "7 day window", th: "หน้าต่าง 7 วัน"),
            body: Phrase(
                en: "Weekly limit across all models, counted as a rolling 7-day window rather than a calendar week.",
                th: "โควต้ารายสัปดาห์ครอบคลุมทุกโมเดล นับแบบ rolling 7 วัน ไม่ใช่สัปดาห์ปฏิทิน"
            )
        ),
        "fable": Entry(
            title: Phrase(en: "Weekly scoped limit", th: "โควต้ารายสัปดาห์เฉพาะโมเดล"),
            body: Phrase(
                en: "A weekly cap tied to one specific model. It is tracked separately from the all-model weekly window, so it can run out while the others are healthy.",
                th: "เพดานรายสัปดาห์ที่ผูกกับโมเดลใดโมเดลหนึ่งโดยเฉพาะ ติดตามแยกจากหน้าต่างรายสัปดาห์รวมทุกโมเดล จึงอาจหมดได้แม้โควต้าอื่นยังปกติ"
            )
        ),
        "energy": Entry(
            title: Phrase(en: "Token energy", th: "พลังงาน token"),
            body: Phrase(
                en: "Every token this session has consumed: fresh input + cache write + cache read + output. This single total is what every bar in the app measures.",
                th: "token ทั้งหมดที่ session นี้ใช้ไป: fresh input + cache write + cache read + output ตัวเลขรวมนี้คือค่าที่ทุกแท่งวัดในแอปใช้เป็นฐาน"
            )
        ),
        "burn": Entry(
            title: Phrase(en: "Burn rate", th: "Burn rate"),
            body: Phrase(
                en: "Tokens consumed per minute, computed over a recent rolling window — not an average since the session started, so it reacts to what is happening now.",
                th: "จำนวน token ที่ใช้ต่อนาที คำนวณจากหน้าต่าง rolling ล่าสุด ไม่ใช่ค่าเฉลี่ยตั้งแต่เริ่ม session จึงสะท้อนสิ่งที่กำลังเกิดขึ้นตอนนี้"
            )
        ),
        "today": Entry(
            title: Phrase(en: "Tokens today", th: "Token วันนี้"),
            body: Phrase(
                en: "All tokens across every session today, measured from the transcript files. Measured, not estimated.",
                th: "token ทั้งหมดจากทุก session ในวันนี้ วัดจากไฟล์ transcript โดยตรง เป็นค่าที่วัดจริง ไม่ใช่ค่าประมาณ"
            )
        ),
        "cost": Entry(
            title: Phrase(en: "API equivalent today", th: "มูลค่าเทียบเท่า API วันนี้"),
            body: Phrase(
                en: "What today's tokens would have cost on the API, from a per-model price table, over the sessions that did work today. On a subscription this is not an amount owed and does not appear on any bill. It is here because it is the only unit that compares 632k of Sonnet against 632k of Opus, and because it answers whether the subscription is earning its price. A model missing from the table reads API equivalent unavailable. The Projects table below covers all time, not today, so the two totals are not meant to match.",
                th: "มูลค่าที่ token ของวันนี้จะมีราคาเท่าไรถ้าใช้ผ่าน API คำนวณจากตารางราคาต่อโมเดล เฉพาะ session ที่ทำงานในวันนี้ หากใช้แบบ subscription ตัวเลขนี้ไม่ใช่ยอดที่ต้องจ่ายจริงและไม่ปรากฏในบิลใดๆ ตัวเลขนี้มีไว้เพราะเป็นหน่วยเดียวที่เทียบ 632k ของ Sonnet กับ 632k ของ Opus ได้ และช่วยตอบว่า subscription คุ้มราคาหรือไม่ โมเดลที่ไม่มีในตารางจะแสดงว่าไม่มีข้อมูลมูลค่าเทียบเท่า API ตาราง Projects ด้านล่างนับรวมทุกช่วงเวลา ไม่ใช่แค่วันนี้ ตัวเลขทั้งสองจึงไม่จำเป็นต้องตรงกัน"
            )
        ),
        "active": Entry(
            title: Phrase(en: "Active sessions", th: "Session ที่กำลังทำงาน"),
            body: Phrase(
                en: "Sessions doing work right now, out of the sessions with a live process. A session waiting on you is live but not active. Liveness is confirmed by pid plus process start time, never by counting processes named claude.",
                th: "session ที่กำลังทำงานอยู่จริงตอนนี้ จากจำนวน session ทั้งหมดที่มี process ทำงานอยู่ (live) session ที่รอคุณตอบอยู่ถือว่า live แต่ไม่ active ตรวจสอบสถานะ live ด้วย PID บวกเวลาที่ process เริ่มทำงาน ไม่เคยนับจากจำนวน process ที่ชื่อ claude"
            )
        ),
        "status": Entry(
            title: Phrase(en: "Session status", th: "สถานะ session"),
            body: Phrase(
                en: "Reported by the session registry: Working (busy), Idle, or Completed once the registry file is gone and the process has exited.",
                th: "รายงานจาก session registry: Working (กำลังทำงาน), Idle (ว่าง), หรือ Completed เมื่อไฟล์ registry หายไปและ process ออกแล้ว"
            )
        ),
        "activity": Entry(
            title: Phrase(en: "Current activity", th: "กิจกรรมปัจจุบัน"),
            body: Phrase(
                en: "Translated from the tool name and file path only — Editing, Reading, Searching, Running a command. Command strings and message text are never read.",
                th: "แปลมาจากชื่อ tool และ path ของไฟล์เท่านั้น เช่น Editing, Reading, Searching, Running a command ไม่มีการอ่านคำสั่งจริงหรือข้อความใน message เลย"
            )
        ),
        "fresh": Entry(
            title: Phrase.untranslated("Fresh input"),
            body: Phrase(
                en: "Input tokens sent uncached. The most expensive part of the bill per token.",
                th: "token อินพุตที่ส่งแบบไม่ผ่าน cache เป็นส่วนที่แพงที่สุดต่อ token ในบิล"
            )
        ),
        "cw": Entry(
            title: Phrase.untranslated("Cache write"),
            body: Phrase(
                en: "Tokens written into the prompt cache. Five-minute and one-hour cache writes are priced differently, so they are tracked separately.",
                th: "token ที่เขียนเข้า prompt cache การเขียนแบบ 5 นาทีและ 1 ชั่วโมงมีราคาต่างกัน จึงติดตามแยกกัน"
            )
        ),
        "cr": Entry(
            title: Phrase.untranslated("Cache read"),
            body: Phrase(
                en: "Tokens served from the prompt cache, roughly ten times cheaper than fresh input. Shown apart from input so the display agrees with the bill.",
                th: "token ที่ดึงมาจาก prompt cache ราคาถูกกว่า fresh input ประมาณสิบเท่า แยกแสดงจาก input เพื่อให้ตัวเลขตรงกับบิลจริง"
            )
        ),
        "out": Entry(
            title: Phrase.untranslated("Output"),
            body: Phrase(
                en: "Tokens the model generated, including the thinking tokens shown in brackets.",
                th: "token ที่โมเดลสร้างขึ้น รวมถึง thinking token ที่แสดงในวงเล็บ"
            )
        ),
        "chart": Entry(
            title: Phrase(en: "Daily usage", th: "การใช้งานรายวัน"),
            body: Phrase(
                en: "Tokens per day for the last 7 days, split into input and output. Measured by tailing each transcript from a stored byte offset instead of re-parsing it.",
                th: "token ต่อวันย้อนหลัง 7 วัน แยกเป็น input และ output วัดโดยการ tail transcript แต่ละไฟล์จาก byte offset ที่บันทึกไว้ แทนที่จะ parse ใหม่ทั้งไฟล์"
            )
        ),
        "ctx": Entry(
            title: Phrase.untranslated("Context window"),
            body: Phrase(
                en: "How much of the model's context window the newest request used. The used value is measured from that request; the limit is Claudence's own model table, not something the transcript states, so the reading is labelled Estimated. Under 70% Healthy, 70–85% Attention, 85–95% Warning, above 95% Critical. When that table has no limit for the model, the amount in use is still shown, with no bar and no percentage.",
                th: "context window ของโมเดลถูกใช้ไปเท่าไรจาก request ล่าสุด ค่าที่ใช้วัดจาก request นั้นโดยตรง ส่วนขีดจำกัดมาจากตารางโมเดลของ Claudence เอง ไม่ใช่ค่าที่ transcript ระบุไว้ จึงติดป้ายว่า Estimated ต่ำกว่า 70% คือ Healthy, 70–85% คือ Attention, 85–95% คือ Warning, สูงกว่า 95% คือ Critical หากตารางไม่มีขีดจำกัดของโมเดลนั้น จะยังแสดงจำนวนที่ใช้อยู่ แต่ไม่มีแท่งและไม่มีเปอร์เซ็นต์"
            )
        ),
    ]

    // MARK: - BREAK_TIPS (4 entries, keyed by breakdown row label)

    static let breakTips: [String: Entry] = [
        "Fresh input": Entry(
            title: Phrase.untranslated("Fresh input"),
            body: Phrase(
                en: "usage.input_tokens — prompt tokens sent uncached this session. Small in count, largest in price per token.",
                th: "usage.input_tokens — token ของ prompt ที่ส่งแบบไม่ผ่าน cache ใน session นี้ จำนวนน้อยแต่ราคาต่อ token แพงที่สุด"
            )
        ),
        "Cache write": Entry(
            title: Phrase.untranslated("Cache write"),
            body: Phrase(
                en: "usage.cache_creation_input_tokens — tokens written into the prompt cache. Split by 5-minute and 1-hour TTL, which are priced differently.",
                th: "usage.cache_creation_input_tokens — token ที่เขียนเข้า prompt cache แยกตาม TTL 5 นาทีและ 1 ชั่วโมง ซึ่งมีราคาต่างกัน"
            )
        ),
        "Cache read": Entry(
            title: Phrase.untranslated("Cache read"),
            body: Phrase(
                en: "usage.cache_read_input_tokens — tokens re-served from the cache at roughly a tenth the price of fresh input.",
                th: "usage.cache_read_input_tokens — token ที่ดึงกลับมาจาก cache ในราคาประมาณหนึ่งในสิบของ fresh input"
            )
        ),
        "Output": Entry(
            title: Phrase.untranslated("Output"),
            body: Phrase(
                en: "usage.output_tokens — everything the model generated, thinking tokens included.",
                th: "usage.output_tokens — ทุกอย่างที่โมเดลสร้างขึ้น รวม thinking token ด้วย"
            )
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
            title: Phrase(en: "Model", th: "โมเดล"),
            body: Phrase(
                en: "message.model from the most recent assistant record. Determines which price row the cost estimate uses.",
                th: "message.model จาก assistant record ล่าสุด ใช้กำหนดว่าจะคำนวณราคาประมาณการจากแถวราคาใด"
            )
        ),
        "Started": Entry(
            title: Phrase(en: "Started at", th: "เริ่มเมื่อ"),
            body: Phrase(
                en: "Process start time, recorded in UTC and shown in your local timezone.",
                th: "เวลาที่ process เริ่มทำงาน บันทึกเป็น UTC และแสดงตาม timezone ของเครื่องคุณ"
            )
        ),
        "Duration": Entry(
            title: Phrase(en: "Duration", th: "ระยะเวลา"),
            body: Phrase(
                en: "Elapsed wall-clock time since the session started, not the time it spent working.",
                th: "เวลาที่ผ่านไปตามนาฬิกาจริงตั้งแต่ session เริ่ม ไม่ใช่เวลาที่ใช้ทำงานจริง"
            )
        ),
        "Git branch": Entry(
            title: Phrase.untranslated("Git branch"),
            body: Phrase(
                en: "gitBranch from the transcript, so you can tell two sessions in the same project apart.",
                th: "gitBranch จาก transcript ช่วยแยกความแตกต่างระหว่าง session สองตัวในโปรเจกต์เดียวกัน"
            )
        ),
    ]

    // MARK: - Disputed
    //
    // The design's original wording for the four strings that were wrong about
    // this application, kept beside the correction now shipping in its place.
    // Nothing reads this table; it exists so the edit is auditable. Kept in
    // English only, deliberately: it is never reachable from any lookup and
    // never reaches a screen, so translating it would be work spent on a
    // sentence no user, Thai or English, will ever see.

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
    static let disputed: [String: (title: String, body: String)] = [
        "Records": (
            title: "Transcript records",
            body: "Assistant records attributed to this subagent in the parent transcript. Each one carries its own usage block."
        ),
        "active": (
            title: "Active sessions",
            body: "Interactive sessions with a live process. Liveness is confirmed by pid plus process start time, never by counting processes named claude."
        ),
        "cost": (
            title: "API equivalent",
            body: "What these tokens would have cost on the API, from a per-model price table. On a subscription it is not an amount owed. A model missing from the table reads API equivalent unavailable."
        ),
        "ctx": (
            title: "Context window",
            body: "How much of the session context is in use. Shown only when the source gives both the used value and the limit. Under 70% Healthy, 70–85% Attention, 85–95% Warning, above 95% Critical."
        ),
    ]
}
