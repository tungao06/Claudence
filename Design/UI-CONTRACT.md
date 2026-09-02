# Claudence UI Contract

Extracted from `Design/Claudence-UI.dc.html` (a Claude Design canvas mockup, 1319 lines).
This document is the implementation surface. Implementers should not need to open the HTML.

The mockup contains two artboards plus two overlays:

| Region | Lines | Contents |
|---|---|---|
| `section#turn2` | 45–110 | Logo study "2b" — ring mark at 104 / 40 / 22 / 18 px, plus designer commentary |
| `section#1a` | 112–719 | The product: menu bar label, popover (420 px), settings pane (420 px), dashboard (1120 px) |
| tooltip overlay | 722–727 | Floating tooltip, rendered when `tip` is set |
| detail overlay | 729–937 | Modal session / subagent detail sheet (760 px) |

Everything is styled with **inline styles**. There are no CSS custom properties and no
design-token layer to lift; the values below were tallied out of the markup.

---

## 1. Palette

### 1.1 Light mode only — there is no dark mode in this design

**The design defines exactly one theme: a warm cream light theme.** Every value below is a
light-mode value. There is no `prefers-color-scheme` block, no `[data-theme]` attribute, and
no dark artboard anywhere in the file. The only dark surfaces are two *element-level* chrome
pieces that are dark in both hypothetical themes: the simulated macOS menu bar strip
(`#2A2622`) and the tooltip bubble (`#2E2924`).

The Settings pane does offer an **Appearance** segmented control with a `Dark` option
(section 7), but no dark rendering exists to copy. **The implementer must invent the entire
dark palette.** Treat that as design work, not transcription — derive it from the semantic
roles below rather than by mechanically inverting hexes, because the warm cream ground
(`#F4F1EA` / `#FFFDF9`) is doing identity work that a naive inversion destroys.

### 1.2 Neutrals — ground, surface, border

| Hex | Role | Applied to |
|---|---|---|
| `#F4F1EA` | canvas ground | `body` background (the desktop behind the panels) |
| `#FFFDF9` | surface primary | popover body, settings card, dashboard shell, detail sheet, toggle knob, active segment pill, logo card |
| `#FFFFFF` | surface raised | session rows in the popover, dashboard sub-cards (power meter, chart, sessions table, token breakdown) |
| `#FCFBF8` | surface recessed | session-facts tiles, subagent rows, the completed/dimmed dashboard session row |
| `#FBF8F2` | surface footer | popover footer strip (`Settings · Privacy` / `Quit Claudence`) |
| `#FAF7F1` | surface inset | logo preview well, detail-sheet energy panel, context-window inset, files-touched chips, transcript facts bar |
| `#F5F0E7` | surface control | segmented-control trough, count pills, secondary buttons, refresh button, `2 subagents` chip |
| `#F5EFE6` | tube track | dashboard power-meter tube background |
| `#F1EAE0` | hairline (light) | chart gridlines (upper 3) |
| `#F3EDE3` | hairline (rows) | `border-bottom` on activity rows and cost rows in the detail sheet |
| `#EFE8DC` | border / divider (default) | card borders, section dividers, bar tracks, control borders — the workhorse |
| `#EDE6DA` | border (card) | popover session row border, dashboard sub-card borders |
| `#E9E1D4` | border (shell) | outer border of popover, settings card, dashboard, detail sheet, close button |
| `#EBE2D4` | border (tube) | power-meter tube border |
| `#E6DED2` | toggle off | toggle track when the switch is Off (and the disabled toggle) |
| `#E0D8CB` | border (badge) | `1a` artboard badge outline |
| `#D6CCBF` | dotted underline | tooltip affordance under `7 day`, `Fable`, `Token usage · last 7 days` |
| `#C9B7A8` | dotted underline (warm) | tooltip affordance under `Claude Power · 5h window`, `Resets in` |
| `#E5DACB` | border hover | session-facts tile hover border |

### 1.3 Text

| Hex | Role | Applied to |
|---|---|---|
| `#3A322C` | text primary | body ink, headings, numerals, active segment label, emphasised filename `<b>` |
| `#4C443E` | text primary (soft) | activity event text in the detail sheet |
| `#6B615A` | text secondary | activity lines, privacy paragraphs, cost-row labels, files-touched chips |
| `#8A7F76` | text tertiary | section eyebrows (`ACTIVE SESSIONS`, `MOTION`, …), inactive segment labels, unit suffixes, icon glyphs |
| `#A79C91` | text quaternary / meta | paths, timestamps, help text, `%` suffix, axis labels, "measured from transcripts" — most frequent color in the file (65 uses) |
| `#B5AAA0` | text quinary | the tagline "Claude + Presence — …" |
| `#C6BBAF` | text disabled / chevron | `›` chevrons, `·` separators, `v0.1.0` |
| `#F4EFE7` | text on dark | menu bar label text on `#2A2622` |
| `#F6F1E9` | text on dark | tooltip title |
| `rgba(246,241,233,.72)` | text on dark (body) | tooltip body |
| `rgba(244,239,231,.45)` | text on dark (meta) | `menu bar · ≤ 60pt` annotation |

### 1.4 Accent

| Hex | Role | Applied to |
|---|---|---|
| `#D2775A` | accent (primary) | brand ring arc, Working dot, 5h fill end-stop, toggle-on track, `2b` badge fill |
| `#C2664A` | accent (link / deep) | `Dashboard →`, `‹ parent` back link, anchors, bottom stop of the 5h tube gradient |
| `#A24F37` | accent (link hover) | `a:hover`, back-link hover |
| `#F0B694` | accent (light stop) | top of 5h gradients |
| `#EBB48F` | accent on dark | menu bar ring arc (lighter, for contrast on `#2A2622`) |
| `#E0A487` | accent (sparkline) | coral sparkline stroke |
| `#B0674C` | accent ink | `● Working` pill text (coral session), `Stop Session…` label, `SELECTED · LIVE` |
| `#A0715C` | accent ink (muted) | `TOKENS TODAY` tile label and subtext, `Open Terminal` label |
| `#8B5F49` | accent ink (deep) | designer note text, tile-label hover |

### 1.5 Session identity colors

Sessions are color-coded per session, not per severity. Three identities appear:

| Identity | Dot / fill | Light stop | Track | Status tint | Status ink | Sparkline |
|---|---|---|---|---|---|---|
| Coral (session 1) | `#D2775A` | `#F0B694` | `#F1E3D8` | `#FAEBE2` | `#B0674C` | `#E0A487` |
| Lavender (session 2) | `#8B7BD8` | `#C6BCEC` | `#ECE8F8` | `#EEEAFA` | `#6A5CB0` | `#A99BE0` |
| Mint (completed) | `#5FA37E` | `#A8D8C0` | `#EFE8DC` | `#E3F0E7` | `#4E8A6B` | — |

Row backgrounds / borders in the dashboard sessions table use the same identity:
coral row `#FDF7F3` on `#F3E3D9` (hover border `#E3C6B4`);
lavender row `#FBFAFE` on `#E7E2F7` (hover border `#C9BEE9`);
completed row `#FCFBF8` on `#EFE8DC` at `opacity: .78` (hover `opacity: 1`, border `#D7E3DA`).
The completed row's energy bar is a flat `#C6D9CC` with no gradient and no glow.

### 1.6 Token-category colors (breakdown, chart, tool mix)

Fixed across every breakdown in the file:

| Category | Hex |
|---|---|
| Fresh input | `#E9A183` |
| Cache write | `#F0C4AC` |
| Cache read | `#A99BE0` |
| Output | `#A8D8C0` |

Chart columns use `#F0C4AC` (input body) over `#A99BE0` (output cap), except the "Today"
column which is emphasised as `#E9A183` over `#8B7BD8` with a ring
`box-shadow: 0 0 0 2px #FFFDF9, 0 0 0 3px #E9A183`. The chart legend swatches are
`#E9A183` = `input`, `#A99BE0` = `output`.

Tool-mix bars reuse the same four: Read `#E9A183`, Edit `#F0C4AC`, Bash `#A99BE0`,
Grep/Glob/Agent `#A8D8C0`.

### 1.7 Severity levels

The design shows **only the Healthy state rendered**. The other three levels exist as
*label text* inside tooltip copy and sample data strings, never as a painted swatch.

| Level | Rendered? | Colors in the design |
|---|---|---|
| Healthy | Yes | ink `#7E9E86` (popover pill) / `#4E8A6B` (dashboard banner), tint `#E3F0E7`, secondary text `#5D7F6B`, border `#D4E7DA` |
| Attention | No | never painted. Appears only as the string `72% used · Attention` in sample data and in the `ctx` tooltip |
| Warning | No | never painted. Appears only as `88% used · Warning` in sample data and in the `ctx` tooltip |
| Critical | No | never painted. Named only inside the `ctx` tooltip text |

The nearest thing to a warning/critical ramp the design offers is the amber cost tile
(`#F8F1DC` on `#EEE4C9`, ink `#957C3C`) and the coral family. **Attention, Warning and
Critical tokens must be invented**, consistent with the amber and coral families above.

Threshold rule, stated in the `ctx` tooltip: under 70% Healthy, 70–85% Attention,
85–95% Warning, above 95% Critical.

### 1.8 Auxiliary / ring-mark colors

`#F1ECFB` (lavender ring halo), `#F4E5DA` (ring track), `#F0DCCF` (ring track, 22 px variant),
`#2A2622` (menu bar strip), `#2E2924` (tooltip), `#F8E3D6` (accent button hover),
`#EBD4C6` (destructive button border), `#F7EFE9` (power hero gradient end),
`#FBEDE4` / `#F3DFD2` (warm tile background / border).

### 1.9 Shadows

| Use | Value |
|---|---|
| Popover / settings card | `0 18px 44px -18px rgba(58,50,44,.28)` |
| Dashboard shell | `0 24px 60px -26px rgba(58,50,44,.3)` |
| Detail sheet | `0 40px 90px -30px rgba(46,41,36,.5)` |
| Tooltip | `0 14px 34px -12px rgba(30,26,22,.55)` |
| Toggle knob | `0 1px 3px rgba(58,50,44,.28)` |
| Active segment pill | `0 1px 3px rgba(58,50,44,.14)` (`0 1px 3px rgba(58,50,44,.1)` on the dashboard window switch) |
| Popover row hover | `0 6px 18px -10px rgba(58,50,44,.22)` |
| Dashboard row hover | `0 8px 20px -12px rgba(58,50,44,.28)` |
| Subagent row hover | `0 8px 20px -14px rgba(58,50,44,.3)` |
| Bar track inner (hero) | `inset 0 1px 2px rgba(58,50,44,.06)` |
| Tube track inner | `inset 0 2px 4px rgba(58,50,44,.05)` |
| Detail backdrop | `rgba(46,41,36,.36)` fill |

---

## 2. Type scale

### 2.1 Faces and their roles — and the substitution

The design loads two Google fonts:

```
Plus Jakarta Sans   weights 400, 500, 600, 700
IBM Plex Mono       weights 400, 500, 600
```

Declared stacks in the markup: `'Plus Jakarta Sans', Helvetica, sans-serif` and
`'IBM Plex Mono', monospace`.

**Role split, which is what matters for substitution:**

| Design face | Role it plays | Swift substitution |
|---|---|---|
| Plus Jakarta Sans | All prose: labels, session names, section eyebrows, help text, button labels, tooltip text, privacy copy, status pill text | **SF Pro** (`.system`) |
| IBM Plex Mono | Every numeral and every machine-derived identifier: token counts, percentages, burn rates, durations, reset timers, filesystem paths, PIDs, session ids, git branches, model names, version strings, byte offsets, chart axis dates, artboard badges, tool names in Tool Mix | **SF Mono** (`.monospaced`) |

The rule the design follows without exception: **if a value came from the machine, it is
mono; if it is language written by the designer, it is sans.** Keep that rule when
substituting. Note the two mixed cases: `44.1k/min` and `2 / 4 today` set the number mono at
26 px and the suffix at 14 px in `#8A7F76` — the suffix is inside the mono span, so it stays
mono in the design.

Weights used across the whole file are only **500, 600, 700** (plus default 400 for
paragraph text). 600 is the default for anything emphasised; 700 marks headings, section
eyebrows and session names.

### 2.2 Size table

| Size | Weight | Face | Applied to |
|---|---|---|---|
| 40px | 600 | mono | Popover power hero percentage (`24`) |
| 34px | 600 | mono | Detail sheet `Token energy` total |
| 26px | 600 | mono | Dashboard stat-tile values (`10.68M`, `44.1k`, `2`, `$3.42`) |
| 20px | 600 | mono | Power-meter tube percentages (`24%`, `13%`, `1%`) |
| 20px | 700 | sans | `Claudence` wordmark on the logo card (`letter-spacing: -.02em`) |
| 19px | 700 | sans | Detail sheet session name (`letter-spacing: -.01em`) |
| 18px | 400 | mono | The `%` suffix beside the hero number, color `#A79C91` |
| 16px | 700 | sans | Dashboard header `Claudence` (`letter-spacing: -.01em`) |
| 16px | 600 | mono | Token breakdown `Total` value |
| 15px | 400 | sans | Artboard captions ("Claudence — menu bar popover + dashboard") |
| 15px | 600 | mono | Reset timer `4h 35m`; secondary window percentages (`13%`, `1%`); dashboard row totals; detail-sheet burn rate |
| 14px | 700 | sans | Session name in popover rows and dashboard rows; `Claudence Settings` title |
| 14px | 600 | mono | Popover footer `Today` value `10.7M` |
| 14px | 400 | mono | Stat-tile unit suffixes (`/min`, ` / 4 today`) in `#8A7F76` |
| 13px | 700 | sans | Dashboard sub-card titles (`Power meter`, `Token usage · last 7 days`, `Active sessions`, `Token breakdown`) |
| 13px | 600 | sans | Settings row labels (`Live indicators`, `What to show`, `Launch at login`, `Appearance`, `Show subagents`, `Compact rows`, `Usage refresh`, and the three notification labels); popover secondary window labels (`7 day`, `Fable`); subagent name |
| 13px | 600 | mono | Popover row token total; cost & efficiency values; subagent total |
| 13px | 400 | sans | Detail-sheet activity line; `›` chevron in popover rows |
| 12.5px | 500 | mono | Session-facts values |
| 12.5px | 400 | sans | Detail-sheet activity event text; designer note |
| 12px | 700 | sans | `CLAUDENCE` popover eyebrow (`letter-spacing: .14em`); detail-sheet section eyebrows (`letter-spacing: .1em`); `Total` label; tooltip title (`letter-spacing: .01em`) |
| 12px | 600 | sans | `Claude Power · 5h window` label (`letter-spacing: .04em`); segmented-control labels; window-switch labels; tube captions (`5 hour`, `7 day`, `Fable`); action-button labels; `Dashboard →`; healthy pill; `Read the full disclosure` |
| 12px | 600 | mono | Menu bar reading `2 · 24%`; active-session count pill |
| 12px | 500 | mono | Transcript / Parsed / Tail offset / Service tier values |
| 12px | 400 | sans | Activity lines in popover rows; breakdown labels; privacy paragraphs; cost-row labels; tooltip body (`line-height: 1.55`); `Today` label |
| 12px | 400 | mono | Breakdown values; detail-sheet path |
| 11.5px | 400 | sans | Subagent activity text |
| 11.5px | 400 | mono | Tool-mix name and count |
| 11px | 700 | sans | Section eyebrows: `ACTIVE SESSIONS`, `MOTION`, `MENU BAR`, `SESSIONS`, `NOTIFICATIONS`, `PRIVACY` (`letter-spacing: .14em`); `SELECTED · LIVE` (`.1em`) |
| 11px | 600 | sans | Status pills (`● Working`); stat-tile labels (`letter-spacing: .04em`); `Context window` label |
| 11px | 400 | sans | Help text under settings rows; card sub-captions; `tokens · $3.42 est.`; footer links; disclosure line |
| 11px | 400 | mono | Paths; `4d 20h` reset hints; `token energy` label; burn rates in the dashboard; `12.4k/min`; artboard badges (`letter-spacing: .12em`); files-touched chips; activity timestamps |
| 10.5px | 400 | sans | Session-facts keys (`letter-spacing: .04em`); transcript-bar labels |
| 10px | 700 | sans | `SUBAGENT` badge (`letter-spacing: .12em`) |
| 10px | 600 | sans | Dashboard status pills; `2 subagents` chip |
| 10px | 400 | mono | `30s ago`; durations (`42m`, `2h 08m`); `weekly scoped`; chart axis dates; `v0.1.0`; subagent type chip; `{share} of parent` |

Letter-spacing values in use: `.14em`, `.12em`, `.1em`, `.04em`, `.01em`, `-.01em`, `-.02em`.
Line-heights: `1` for large numerals, `1.5` for help text, `1.55` for tooltip body,
`1.6` for privacy paragraphs.

---

## 3. Spacing, radii, layout metrics

### 3.1 Container widths

| Container | Width |
|---|---|
| Popover | **420 px** (`box-sizing: border-box`) |
| Menu bar strip mock | 420 px wide, **34 px tall** |
| Settings pane | 420 px (same shell as the popover) |
| Dashboard | **1120 px** (`min-width: 1120px`) |
| Detail overlay sheet | **760 px**, `max-height: 88vh`, scrolls internally |
| Tooltip | `width: max-content`, `max-width: 320px` |
| Logo card | 372 px |

### 3.2 Radii

| Radius | Applied to |
|---|---|
| `999px` | every bar, tube fill, pill, dot, toggle track and knob (69 uses) |
| `28px` | power-meter tube and its fill |
| `22px` | detail sheet |
| `20px` | dashboard shell, logo card |
| `18px` | popover shell, settings card |
| `16px` | dashboard sub-cards, detail-sheet energy panel, logo preview well |
| `14px` | popover power hero, stat tiles, popover header note |
| `13px` | popover session row, dashboard session row |
| `12px` | tooltip, subagent row, context-window inset, transcript facts bar |
| `11px` | session-facts tile, action buttons, healthy banner, context inset (dashboard) |
| `10px` | menu bar strip, segmented-control trough, close button, refresh button, secondary buttons, window-switch |
| `10px 10px 4px 4px` | chart columns |
| `9px` | breakdown row hover target |
| `8px` | segment pill, refresh chip, files-touched chip |
| `6px` | artboard badges |
| `3px` | legend swatches (9×9) |

### 3.3 Popover internal metrics (top to bottom)

```
header                 padding 16px 20px 12px
power hero             margin 0 14px 14px; padding 18px 18px 16px; radius 14
  hero bar             height 14px, radius 999
secondary windows      padding 2px 20px 16px; gap 12px between windows, 6px within
  window bar           height 8px, radius 999
divider                height 1px, margin 0 20px
sessions header        padding 14px 20px 10px
session list           padding 0 14px 6px; gap 8px
  session row          padding 12px 14px; radius 13; gap 9px
  row energy bar       height 8px, radius 999
  row sparkline        svg 90×16, viewBox 0 0 90 16, stroke-width 1.6
divider                height 1px, margin 8px 20px 0
today strip            padding 13px 20px
footer strip           padding 10px 20px 14px, border-top 1px
```

### 3.4 Dashboard metrics

```
shell header           padding 22px 28px, border-bottom 1px
body                   padding 22px 28px 28px; gap 18px
stat tiles             grid repeat(4, 1fr), gap 14px; tile padding 15px 17px, gap 7px
row 2                  grid 372px 1fr, gap 18px
  power meter card     padding 20px, gap 18px
    tube               56 × 186 px, radius 28
    tube column gap    11px (value → tube → caption gap 3px)
    healthy banner     padding 10px 12px, radius 11
  chart card           padding 20px 22px, gap 16px
    plot area          height 218px
    columns            grid repeat(7, 1fr), gap 18px, radius 10 10 4 4
    gridlines          4 × 1px (3 × #F1EAE0, baseline #EDE6DA)
    axis row           grid repeat(7, 1fr), gap 18px
row 3                  grid 1fr 340px, gap 18px
  sessions table       padding 20px 22px, gap 14px; rows gap 10px
    row grid           1fr 132px 96px 84px, gap 16px; padding 14px 16px
    row energy bar     height 8px
    row sparkline      svg 84×18, viewBox 0 0 84 18, stroke-width 1.6
  token breakdown      padding 20px, gap 16px
    stacked bar        height 12px, gap 2px between segments
    legend swatch      9 × 9 px, radius 3
    context bar        height 8px
```

### 3.5 Detail sheet metrics

```
backdrop               padding 40px, centered
sheet header           padding 24px 26px 18px, border-bottom 1px, gap 20px
  status dot           9 × 9 px
  close button         30 × 30 px, radius 10, 1px border
body                   padding 20px 26px 26px, gap 18px
energy panel           padding 18px 20px, radius 16, gap 13
  energy bar           height 12px
  sparkline            svg viewBox 0 0 240 50, rendered 200 × 42, stroke-width 2.2
two-column grids       repeat(2, 1fr), gap 18px
  breakdown bar        height 6px
  context inset        padding 12px 14px, radius 12, bar height 8px
  activity row         gap 11px, padding-bottom 9px, border-bottom 1px; time column width 34px
tool-mix bar           height 6px
files-touched chips    padding 5px 9px, radius 8, wrap gap 7px
transcript facts bar   padding 12px 15px, radius 12, gap 18px
session facts grid     repeat(3, 1fr), gap 10px; tile padding 11px 13px, radius 11
subagent row grid      1fr 116px 78px 22px, gap 14px; padding 12px 14px, radius 12
  subagent dot         7 × 7 px
  subagent bar         height 6px
action button row      gap 9px; button padding 9px 15px, radius 11
```

### 3.6 Controls

| Control | Metrics |
|---|---|
| Toggle track | 40 × 24 px, radius 999 |
| Toggle knob | 18 × 18 px, radius 999, inset `top: 3px; left: 3px`, travel `translateX(16px)` when on |
| Segmented control | trough padding 3px, gap 2px, radius 10; segment padding 7px 8px, radius 8, `flex: 1` |
| Window switch (dashboard) | same trough; segment padding 6px 14px |
| Refresh button (popover) | 24 × 24 px, radius 8 |
| Refresh button (dashboard) | 34 × 34 px, radius 10, 1px border |
| Secondary button | padding 8px 14px, radius 10 |
| Status pill | padding 3px 8px (popover) / 2px 8px (dashboard), radius 999 |
| Count pill | padding 2px 9px, radius 999 |

### 3.7 Ring mark geometry (the Claudence glyph)

All variants use `viewBox="0 0 96 96"`, center `48,48`, arc radius `r=33`, arc start
`transform="rotate(132 48 48)"`. Circumference is ≈208 units, which is why every arc keyframe
is expressed against `208`.

| Rendered size | Halo | Track | Arc | Center hole | Core dot | Orbit dot |
|---|---|---|---|---|---|---|
| 104 px (hero) | `r45 #F1ECFB`, `r38 #FFFDF9` | `r33 #F4E5DA` w10 | `r33 #D2775A` w10 | `r14.5 #FFFDF9` | `r6 #8B7BD8` | `cx48 cy15 r3.2 #5FA37E` |
| 40 px | same as above | same | same | same | same | same |
| 30 px (dashboard header) | `r45 #F1ECFB` | `r33 #F4E5DA` w14 | `r33 #D2775A` w14 | `r12 #FFFDF9` | `r5 #8B7BD8` | — |
| 22 px (popover header) | `r45 #F1ECFB` | `r33 #F4E5DA` w14 | `r33 #D2775A` w14 | `r12 #FFFDF9` | `r5 #8B7BD8` | — |
| 22 px (compact study) | — | `r33 #F0DCCF` w15 | `r33 #D2775A` w15 | `r11 #FFFDF9` | `r4.6 #8B7BD8` | — |
| 18 px (menu bar) | — | `r33 rgba(244,239,231,.25)` w17 | `r33 #EBB48F` w17 | `r9.5 #2A2622` | — | — |
| 15 px (menu bar) | — | `r33 rgba(244,239,231,.28)` w18 | `r33 #EBB48F` w18 | `r9 #2A2622` | — | — |

At menu bar size the core dot and orbit dot are dropped; only the arc carries the reading.

### 3.8 Icon / glyph inventory

Every "icon" in the design is a text glyph, not an asset: `⟳` (refresh), `✕` (close),
`›` (row chevron), `‹` (back), `●` (status dot inside pills), `✓` (healthy check),
`↑` (delta up), `→` (Dashboard link), `🔒` (privacy line).
Sizes: `›` 13 px in the popover / 14 px in subagent rows; `⟳` 12 px.

---

## 4. Motion

### 4.1 🚨 FORBIDDEN — repeating animations

`CLAUDE.md` bans repeating animation anywhere in the menu bar popover, conditional or not.
One `.repeatForever` measured **6.9% of a core against a 0.5% budget** with the popover never
opened, because `MenuBarExtra(style: .window)` keeps its content mounted after dismissal.
Gating on a "popover is presented" signal was tried twice and failed twice.

**The following nine animations are `infinite` in the design. Do not reproduce any of them.**

| Keyframe | Duration / timing | Applied to | What it does |
|---|---|---|---|
| `pulseDot` | 1.8s ease-in-out infinite (2nd row delayed .4s) | Working status dot (popover rows, dashboard rows) | opacity 1→.45, scale 1→.82 |
| `ringPulse` | 1.8s ease-out infinite (2nd row delayed .4s) | Halo behind the Working dot in popover rows | opacity .5→0, scale 1→2.4 |
| `liveGlow` | 3.2s ease-in-out 1s infinite | Every *live* fill: hero bar, 7-day bar, session-row bars, dashboard row bars, tubes 1 and 2, detail energy bar, detail context bar | brightness 1→1.13, saturate 1.04 |
| `glintX` | 3.8s ease-in-out infinite, staggered delays .40 / .95 / 1.50 / 2.05 / 2.60s | Specular sheen overlay on every horizontal bar fill | sweeps `background-position` 155% → -75% |
| `glintY` | 4.4s ease-in-out infinite, staggered .60 / .72 / .94 / 1.16 / 1.30 / 1.38 / 1.60 / 1.82 / 2.00 / 2.04s | Sheen overlay on power-meter tubes and all 7 chart columns | sweeps vertically -75% → 155% |
| `arcBreathe` | 5s ease-in-out 1.4s infinite | Logo-card ring arc (104 / 40 / 22 px) | dasharray 148→160 of 208 |
| `arcHeadBreathe` | 4.5s ease-in-out 1.3s infinite | Ring arc in the popover header, dashboard header, and **menu bar label** | dasharray 50→58 of 208 |
| `coreBreathe` | 2.8s ease-in-out infinite | Lavender core dot inside the ring | scale 1→.84, opacity 1→.78 |
| `orbit` | 16s linear infinite | Mint orbit dot group on the 104 / 40 px logo | rotate 0→360° |

Note in particular that `arcHeadBreathe` is applied to the **menu bar label itself**, which is
mounted for the entire life of the process — the single worst place to run a repeating
animation. Render the arc statically at its current percentage.

`liveGlow` and `glintX`/`glintY` are the design's signal for "this session is live". The
completed session's bar deliberately omits both. That distinction must be carried by
something non-animating: the design already carries it redundantly via the status pill
(`● Working` vs `✓ Completed`), the flat `#C6D9CC` fill, and `opacity: .78` on the row.

### 4.2 Permitted — one-shot animations

All of these run once (`both` fill mode, no iteration count). They are safe in principle, but
still subject to the project's "animate once per observed change" rule.

| Keyframe | Duration / timing | Applied to |
|---|---|---|
| `fadeUp` | .7s `cubic-bezier(.22,.7,.2,1)` both | Popover shell (no delay); settings card (.1s) |
| `fadeUp` | .6s same easing | Popover session rows (.22s, .34s); dashboard session rows (.18s, .28s, .38s); stat tiles (.05 / .12 / .19 / .26s) |
| `fillGrow` | 1.05s same easing both | Every horizontal bar in the popover and dashboard (scaleX 0→1) |
| `fillGrow` | .8s same easing both | Every horizontal bar in the detail sheet |
| `riseGrow` | 1.25s same easing both | Power-meter tubes (scaleY 0→1) |
| `riseGrow` | .85s same easing, staggered .10 → .52s in 0.07s steps | The 7 chart columns |
| `drawLine` | 1.5s ease-out .25s both | All sparklines (`stroke-dashoffset` 320→0) |
| `arcFill` | 1.3s `cubic-bezier(.22,.7,.2,1)` both | Logo-card ring arc (dasharray 0→150 of 208) |
| `arcHead` | 1.2s same easing both | Header and menu bar ring arcs (dasharray 0→52 of 208) |
| `popIn` | .32s same easing both | Detail sheet (opacity + translateY 16px + scale .985→1) |
| `backdropIn` | .22s ease both | Detail sheet backdrop |
| `tipIn` | .16s ease-out both | Tooltip |

### 4.3 Defined but unused

`@keyframes bob` (translateY 0 → -1.5px, would be repeating) is declared in the stylesheet and
**never applied to any element**. Ignore it.

### 4.4 Reduce Motion

Two kill switches exist, both blanket:

```css
.motion-off *, .motion-off { animation: none !important; }
@media (prefers-reduced-motion: reduce) { * { animation: none !important; } }
```

The `.motion-off` class is bound to the Settings "Live indicators" toggle. The settings help
text states the contract: **"System Reduce Motion always wins over this switch."**

### 4.5 Transitions (not animations — these are fine)

The standard interaction transition, repeated on every clickable element:

```
transform .18s cubic-bezier(.22,.7,.2,1), box-shadow .2s ease, background .2s ease,
border-color .2s ease, color .18s ease, opacity .2s ease
```

Pressed state is `transform: scale(.985) translateY(1px)` on rows and buttons,
`transform: scale(.96)` on toggles. Toggle track uses `background .22s ease`; toggle knob uses
`transform .22s cubic-bezier(.22,.7,.2,1)`. Segments use `background .2s ease, color .18s ease`.

---

## 5. Component inventory

### 5.1 Menu bar label

Sits on a simulated 34 px dark strip (`#2A2622`, radius 10, padding `0 14px`).

- A pill (`rgba(255,255,255,.1)`, radius 999, padding `4px 10px`, gap 7px) containing:
  - the 15 px ring glyph (arc only, no core, arc color `#EBB48F` on a `rgba(244,239,231,.28)` track), **graphic**
  - the reading `2 · 24%` — mono 12 px / 600, `#F4EFE7`, **text**
- Annotation beside it: `menu bar · ≤ 60pt` — this is a *design constraint note*, not UI.

The label is `count · percent`. The Settings pane offers three formats (section 7):
`Icon`, `Icon + %`, `Count · %`. The rendered mockup shows `Count · %` with the icon present.

States: no loading / empty / error variant is drawn. Design intent from the tooltip copy is
that the arc alone carries the reading when narrow.

### 5.2 Power meter — popover hero

Layout, top to bottom:

1. Row: left column / right column.
   - Left: label `Claude Power · 5h window` (12 px 600, `#8A7F76`, dotted underline `#C9B7A8`, tooltip trigger `power`), then a baseline row of `24` (mono 40 px), `%` (mono 18 px `#A79C91`), and the pill `✓ Healthy` (12 px 600, ink `#7E9E86`, tint `#E3F0E7`, radius 999, padding `3px 9px`). All **text**.
   - Right: `Resets in` (11 px, dotted underline, tooltip trigger `reset`) over `4h 35m` (mono 15 px 600). **Text.**
2. Bar: 14 px tall track `#F1E3D8`, radius 999, inner shadow. Fill positioned `inset: 0 76% 0 0` (i.e. 24% wide), gradient `90deg, #F0B694 → #D2775A`. **Graphic.**

Panel: margin `0 14px 14px`, padding `18px 18px 16px`, radius 14, background
`linear-gradient(165deg, #FBEDE4 0%, #F7EFE9 100%)`, border `#F0DFD2`.

### 5.3 Power meter — secondary windows (popover)

Two stacked units, each: a baseline row (label with dotted underline + mono percentage 15 px +
mono reset hint 11 px `#A79C91`) over an 8 px track `#EFE8DC`.

- `7 day` — 13%, `4d 20h`, fill `90deg, #C6BCEC → #8B7BD8`, animated live.
- `Fable` + the mono caption `weekly scoped` (10 px `#A79C91`) — 1%, `4d 20h`, fill `90deg, #A8D8C0 → #5FA37E`, **no `liveGlow`**.

### 5.4 Power meter — dashboard tubes

Card titled `Power meter` / `usage limits`. Three vertical tubes, `space-around`:

Each tube column: mono 20 px percentage on top → tube (56 × 186 px, radius 28, track
`#F5EFE6` on `#EBE2D4`, inset shadow) → caption block (12 px 600 name + mono 10 px reset).
Fill is bottom-anchored, radius 28, gradient `0deg`:
5h `#C2664A → #F0B694` at 24%; 7d `#8B7BD8 → #C6BCEC` at 13%; Fable `#5FA37E → #A8D8C0` at
**2% height for a 1% reading** (the design floors a sub-2% fill so it stays visible — worth
preserving as a minimum-fill rule).

Footer banner: `✓ Healthy` (12 px 600 `#4E8A6B`) + `plenty of power in every window`
(12 px `#5D7F6B`) on `#E3F0E7`, padding `10px 12px`, radius 11.

### 5.5 Session row — compact (popover)

`padding: 12px 14px`, radius 13, background `#FFFFFF`, border `#EDE6DA`, `gap: 9px`,
clickable (opens the detail sheet).

1. Header row: pulsing 8 px dot (identity color, **graphic**) · session name (14 px 700,
   `flex: 1`) · status pill `● Working` (11 px 600, identity tint/ink) · `›` chevron `#C6BBAF`.
2. Path row: mono 11 px `#A79C91` — path, optional `·` separator `#C6BBAF`, git branch.
3. Activity line: 12 px `#6B615A`, with the filename emphasised as `<b>` 600 `#3A322C`
   (`Editing **SessionStore.swift**`).
4. Energy row: 8 px bar (`flex: 1`, track `#EFE8DC`, identity gradient fill) + mono 13 px 600
   total, right-aligned.
5. Meta row: mono 10 px duration · mono 10 px burn rate · sparkline (svg 90×16, polyline,
   stroke 1.6, identity sparkline color). **Graphic.**

Row 5 is what the `Compact rows` setting hides. The design's own label for the
setting is "Hide duration, rate and sparkline until a row is opened", which names
the three things in row 5 and nothing in row 4.

An earlier revision of this line said rows 4 **and** 5, which contradicted the
label two lines below it. Row 4 is the energy bar, and the energy bar is the one
thing a power meter cannot hide: a session list with no energy in it is a list of
names. `SessionRow.isCompact` therefore hides row 5 only, matching the label
rather than the earlier reading of the markup.

### 5.6 Session row — expanded (dashboard table)

4-column grid `1fr 132px 96px 84px`, gap 16, padding `14px 16px`, radius 13, tinted by identity.

- Col 1: dot + name (14 px 700) + status pill (10 px 600); path line (mono 11 px, ellipsised,
  `white-space: nowrap`); activity line with a `2 subagents` chip (10 px 600, `#8A7F76` on
  `#F5F0E7`, radius 999, padding `2px 7px`).
- Col 2: 8 px energy bar over the mono 11 px caption `token energy`.
- Col 3: mono 15 px 600 total, right-aligned.
- Col 4: mono 11 px burn rate over an 84×18 sparkline, right-aligned.

**Completed variant** (`design-tokens-03`): dot is static (no pulse), pill is
`✓ Completed`, activity line reads `ended 34m ago · 18m run` in `#A79C91`, energy bar is flat
`#C6D9CC` with no glow, burn cell is the em dash `—` instead of a sparkline, and the whole row
sits at `opacity: .78` (hover restores `1`).

Card header: `Active sessions` (13 px 700) + `Click a row for full detail · hover any value
for what it means` (11 px `#A79C91`).

### 5.7 Session detail overlay

Modal: fixed backdrop `rgba(46,41,36,.36)`, click-outside closes; sheet 760 px, radius 22,
`max-height: 88vh`, internally scrolling.

Header: optional `‹ {parent}` back link + `SUBAGENT` badge (subagent mode only); then 9 px dot,
name (19 px 700), status pill (tooltip trigger `status`); then mono 12 px path; then activity
text (13 px `#6B615A`, tooltip trigger `activity`); close `✕` button 30×30 on the right.

Body sections in order:

1. **Energy panel** — `Token energy` label + mono 34 px total (tooltip `energy`) on the left;
   `Burn rate` label + mono 15 px value + a 200×42 sparkline on the right (tooltip `burn`);
   below, a 12 px identity-colored energy bar.
2. **TOKEN BREAKDOWN / RECENT ACTIVITY** — two columns.
   - Breakdown: four rows, each a 9×9 swatch + label (12 px) + mono 12 px value, over a 6 px
     bar. Each row is its own tooltip trigger (see `BREAK_TIPS`). Below, a `Context window`
     inset: label, 8 px bar, and the label string (e.g. `61% used · Healthy`), tooltip `ctx`.
   - Activity: rows of mono 11 px timestamp (34 px column) + 12.5 px event text, each with a
     `#F3EDE3` bottom rule. Footnote: *"Derived from tool name and file path only. Message
     text and command strings are never read."*
3. **COST & EFFICIENCY / TOOL MIX** — two columns, only when `extra` data exists.
   - Cost: four label/value rows (`Estimated cost`, `Input served from cache`,
     `Tokens per hour`, `Share of the 5h window`) with mono 13 px values.
     Footnote: *"Cost is estimated from a per-model price table, never a billed amount."*
   - Tool mix: per tool, mono 11.5 px name + count over a 6 px bar in the tool's color.
     Footnote: *"Counted by tool name only. Arguments are never read."*
4. **FILES TOUCHED** — wrapping mono 11 px chips on `#FAF7F1`.
5. **Transcript facts bar** — four label/value pairs: `Transcript`, `Parsed`, `Tail offset`,
   `Service tier`.
6. **SESSION FACTS** — see 5.9.
7. **SUBAGENTS** — see 5.8, only when `subCount` is non-zero.
8. **Action row** — `Open Terminal` (accent: `#FBEDE4` / `#F3DFD2` / `#A0715C`),
   `Open Project`, `Copy Path` (neutral: `#F5F0E7` / `#EFE8DC`), and `Stop Session…`
   (destructive, pushed right with `margin-left: auto`: `#FFFDF9` / `#EBD4C6` / `#B0674C`).

Subagent mode reuses the identical sheet; only the header gains the back link and badge, and
the `SUBAGENTS` block is absent.

### 5.8 Subagent list

Header: `SUBAGENTS` eyebrow + `spawned by this session · tokens billed to the parent`.

Each row is a 4-column grid `1fr 116px 78px 22px`, padding `12px 14px`, radius 12, on
`#FCFBF8` / `#EFE8DC`, clickable (drills into the subagent's own detail view):

- Col 1: 7 px dot, name (13 px 600), agent-type chip (mono 10 px on `#F5F0E7`), status pill
  (10 px 600), and below it the activity text (11.5 px `#8A7F76`).
- Col 2: 6 px bar over the mono 10 px caption `{share} of parent`.
- Col 3: mono 13 px 600 total.
- Col 4: `›` chevron (14 px, `#C6BBAF`).

### 5.9 Session facts panel

`SESSION FACTS` eyebrow over a `repeat(3, 1fr)` grid, gap 10. Each tile: padding `11px 13px`,
radius 11, `#FCFBF8` on `#EFE8DC`; key in 10.5 px `#A79C91` (`letter-spacing: .04em`), value in
mono 12.5 px 500. Every tile is a tooltip trigger keyed on the fact name (see `META_TIPS`).

Facts shown for an interactive session, in order:
`PID`, `Model`, `Kind`, `Started`, `Duration`, `Git branch`, `CC version`, `Session id`,
`Registry`.

Facts shown for a subagent, in order:
`Parent`, `Agent type`, `Spawned by`, `Started`, `Duration`, `Model`, `Tool calls`, `Records`,
`Share`.

### 5.10 Usage chart

Card header: `Token usage · last 7 days` (13 px 700, dotted underline, tooltip `chart`) over
`measured from transcripts` (11 px `#A79C91`); legend on the right — two 9×9 radius-3 swatches
labelled `input` (`#E9A183`) and `output` (`#A99BE0`).

Plot: 218 px tall. Four horizontal gridlines behind, then a `repeat(7, 1fr)` gap-18 grid of
bottom-aligned columns, radius `10px 10px 4px 4px`, each an output cap (`#A99BE0`) stacked
over an input body (`#F0C4AC`). The seventh column ("Today") is emphasised with the saturated
pair (`#8B7BD8` / `#E9A183`) and a 2px/3px ring.

Axis: mono 10 px dates `#A79C91`, with the last cell reading `Today` in 600 `#3A322C`.

### 5.11 Token breakdown card (dashboard)

Header `Token breakdown` / `claudence-06 · this session`. Then a 12 px stacked bar
(four segments, 2 px gaps, radius 999). Then four legend rows (9×9 swatch + label + mono
value), each a tooltip trigger. Then a 1 px rule and a `Total` row (12 px 700 label + mono
16 px value). Then a `Context window` inset (`#FAF7F1`, radius 11, padding `11px 13px`)
containing an 11 px label, an 8 px bar, and `61% used · healthy`. Footer line:
`🔒 Read locally. No text or commands are ever read.`

Note the case inconsistency: this card renders `61% used · healthy` lowercase, while the
detail sheet renders `61% used · Healthy` capitalised. Pick one — capitalised matches the rest
of the design's severity labels.

### 5.12 Stat tiles (dashboard)

Four tiles, `repeat(4, 1fr)`, each: label (11 px 600, colored, dotted underline, tooltip
trigger) → mono 26 px value → 11 px sub-caption in the tile's ink.

| Tile | Background / border / ink | Value | Sub-caption | Tooltip key |
|---|---|---|---|---|
| `TOKENS TODAY` | `#FBEDE4` / `#F3DFD2` / `#A0715C` | `10.68M` | `↑ 18% vs yesterday` | `today` |
| `BURN RATE` | `#EEEAFA` / `#E1DBF5` / `#6A5CB0` | `44.1k/min` | `rolling 10 min` | `burn` |
| `ACTIVE SESSIONS` | `#E3F0E7` / `#D4E7DA` / `#4E8A6B` | `2 / 4 today` | `2 projects` | `active` |
| `EST. COST` | `#F8F1DC` / `#EEE4C9` / `#957C3C` | `$3.42` | `estimated, not billed` | `cost` |

### 5.13 Tooltip

Fixed-position bubble, follows the cursor: `left: tipX`, `top: tipY`,
`transform: translate(-50%, -100%)`, `z-index: 60`, `pointer-events: none`.
Dark `#2E2924`, radius 12, padding `11px 13px`, `max-width: 320px`.
Title 12 px 700 `#F6F1E9`; body 12 px `rgba(246,241,233,.72)`, `line-height: 1.55`,
`text-wrap: pretty`.

Clamping in the mockup's JS: x is clamped to `[172, innerWidth - 172]`; y is
`max(cursorY - 14, 108)`.

Trigger affordance is a `1px dotted` underline in `#C9B7A8` (warm surfaces) or `#D6CCBF` /
`#C6BBAF` (neutral surfaces).

### 5.14 Settings pane

Card shell identical to the popover (420 px, radius 18, `#FFFDF9` on `#E9E1D4`). Header block:
`Claudence Settings` (14 px 700) over `Local only · nothing here leaves your Mac`. Then five
sections separated by `1px #EFE8DC` rules, each opening with an 11 px 700 `.14em` eyebrow.
Full contents in section 7.

### 5.15 States the design does *not* draw

The mockup contains **no loading state, no empty state, no unavailable state, and no error
state** for any component. Every panel is drawn with full sample data. The only degraded
affordances present anywhere are:

- the em dash `—` used as the value for a burn rate that does not exist (completed session),
  and for a PID that no longer exists;
- the dimmed completed row (`opacity: .78`);
- the disabled `Permission required` notification row (`opacity: .5`) with the explanation
  `Unavailable — this state is not derivable yet.`;
- tooltip copy that names the unavailable strings: `Usage unavailable` is *not* in the design,
  but `Cost unavailable` is named inside the `cost` tooltip.

Per `CLAUDE.md`, absent Claude Code, zero sessions, denied Keychain access and no network are
ordinary states with defined UI. **Those screens must be designed, not extracted** — the
design gives you the `—` convention, the `opacity: .5` + inline explanation pattern, and the
`Unavailable — <reason>` sentence shape as the precedents to follow.

---

## 6. Tooltip text, verbatim

Transcribed exactly from the `TIPS`, `BREAK_TIPS` and `META_TIPS` objects. **36 entries total**
(17 + 4 + 15). Do not paraphrase, shorten, or correct any of these strings.

### 6.1 `TIPS` (17 entries)

| Key | Title | Body |
|---|---|---|
| `power` | Claude Power · 5h | Share of the rolling 5-hour usage limit already consumed. Read from the usage API utilization field. At 100% Claude Code pauses until the window resets. |
| `reset` | Reset timer | Time left before this window starts counting from zero again. Derived from the resets_at timestamp returned by the API. |
| `seven` | 7 day window | Weekly limit across all models, counted as a rolling 7-day window rather than a calendar week. |
| `fable` | Weekly scoped limit | A weekly cap tied to one specific model. It is tracked separately from the all-model weekly window, so it can run out while the others are healthy. |
| `energy` | Token energy | Every token this session has consumed: fresh input + cache write + cache read + output. This single total is what every bar in the app measures. |
| `burn` | Burn rate | Tokens consumed per minute, computed over a recent rolling window — not an average since the session started, so it reacts to what is happening now. |
| `today` | Tokens today | All tokens across every session today, measured from the transcript files. Measured, not estimated. |
| `cost` | Estimated cost | Estimate from a per-model price table. It is an estimate, never the amount actually billed. A model missing from the table reads Cost unavailable. |
| `active` | Active sessions | Interactive sessions with a live process. Liveness is confirmed by pid plus process start time, never by counting processes named claude. |
| `status` | Session status | Reported by the session registry: Working (busy), Idle, or Completed once the registry file is gone and the process has exited. |
| `activity` | Current activity | Translated from the tool name and file path only — Editing, Reading, Searching, Running a command. Command strings and message text are never read. |
| `fresh` | Fresh input | Input tokens sent uncached. The most expensive part of the bill per token. |
| `cw` | Cache write | Tokens written into the prompt cache. Five-minute and one-hour cache writes are priced differently, so they are tracked separately. |
| `cr` | Cache read | Tokens served from the prompt cache, roughly ten times cheaper than fresh input. Shown apart from input so the display agrees with the bill. |
| `out` | Output | Tokens the model generated, including the thinking tokens shown in brackets. |
| `ctx` | Context window | How much of the session context is in use. Shown only when the source gives both the used value and the limit. Under 70% Healthy, 70–85% Attention, 85–95% Warning, above 95% Critical. |
| `chart` | Daily usage | Tokens per day for the last 7 days, split into input and output. Measured by tailing each transcript from a stored byte offset instead of re-parsing it. |

### 6.2 `BREAK_TIPS` (4 entries, keyed by breakdown row label)

| Key | Title | Body |
|---|---|---|
| `Fresh input` | Fresh input | usage.input_tokens — prompt tokens sent uncached this session. Small in count, largest in price per token. |
| `Cache write` | Cache write | usage.cache_creation_input_tokens — tokens written into the prompt cache. Split by 5-minute and 1-hour TTL, which are priced differently. |
| `Cache read` | Cache read | usage.cache_read_input_tokens — tokens re-served from the cache at roughly a tenth the price of fresh input. |
| `Output` | Output | usage.output_tokens — everything the model generated, thinking tokens included. |

**Composition rule:** the breakdown tooltip body is not shown alone. The mockup appends the
row's own numbers with a fixed separator:

```
body + '  ·  ' + value + ' of ' + total + ' (' + pct + '%)'
```

So the rendered body for Fresh input reads:
`usage.input_tokens — prompt tokens sent uncached this session. Small in count, largest in price per token.  ·  58.8k of 1.47M (4%)`
Note the separator is **two spaces, a middle dot, two spaces**.

### 6.3 `META_TIPS` (15 entries, keyed by session-fact name)

| Key | Title | Body |
|---|---|---|
| `PID` | Process id | The OS process behind this session. Checked together with the recorded start time, because a pid alone can be reused after a reboot. |
| `Model` | Model | message.model from the most recent assistant record. Determines which price row the cost estimate uses. |
| `Kind` | Session kind | interactive is a session a person is using. Background jobs are reported as bg and are deliberately excluded from this list. |
| `Started` | Started at | Process start time, recorded in UTC and shown in your local timezone. |
| `Duration` | Duration | Elapsed wall-clock time since the session started, not the time it spent working. |
| `Git branch` | Git branch | gitBranch from the transcript, so you can tell two sessions in the same project apart. |
| `CC version` | Claude Code version | The version that wrote this session. Concurrent sessions can run different versions, so the schema is detected per record. |
| `Session id` | Session id | Identifier shared by the registry file and the transcript. It is what confirms the two belong to the same session. |
| `Registry` | Registry status | The raw status value from the registry file, shown unmapped. reaped means the stale file was cleaned up after the process exited. |
| `Parent` | Parent session | The interactive session that spawned this subagent. A subagent has no process of its own — its tokens are billed to the parent. |
| `Agent type` | Agent type | The subagent type requested in the Agent tool call, for example Explore or general-purpose. |
| `Spawned by` | Spawned by | The tool call that created this subagent. On 2.1.257 the spawn tool is Agent; older transcripts call it Task. |
| `Tool calls` | Tool calls | How many tool invocations this subagent made. Counted from assistant records, tool names only. |
| `Records` | Transcript records | Assistant records attributed to this subagent in the parent transcript. Each one carries its own usage block. |
| `Share` | Share of parent | This subagent’s tokens as a share of the parent session total, so you can see which branch of work is spending the power. |

Note: the `Share` body contains a **typographic right single quote** (U+2019) in
`subagent’s`, not an ASCII apostrophe. Several bodies contain **em dashes** (U+2014) and the
`ctx` body contains an **en dash** (U+2013) in `70–85%`. Preserve them.

---

## 7. Settings inventory

Header: **Claudence Settings** / *Local only · nothing here leaves your Mac*

### Section `MOTION`

| Label | Control | Options | Default in mockup | Help text |
|---|---|---|---|---|
| Live indicators | Toggle | On / Off | **On** | Bars glow softly while a session is working, so you can tell live from stalled. |

Section footnote (not attached to a control): *System Reduce Motion always wins over this switch.*

### Section `MENU BAR`

| Label | Control | Options (exact labels) | Default in mockup | Help text |
|---|---|---|---|---|
| What to show | Segmented, 3 up | `Icon` · `Icon + %` · `Count · %` | **`Icon + %`** | Session count stays opt-in; width never exceeds 60 pt. |
| Launch at login | Toggle | On / Off | **On** | — |
| Appearance | Segmented, 3 up | `Auto` · `Light` · `Dark` | **`Auto`** | — |

### Section `SESSIONS`

| Label | Control | Options | Default in mockup | Help text |
|---|---|---|---|---|
| Show subagents | Toggle | On / Off | **On** | List agents spawned under each session, with their share of the parent. |
| Compact rows | Toggle | On / Off | **Off** | Hide duration, rate and sparkline until a row is opened. |
| Usage refresh | Segmented, 3 up | `30s` · `60s` · `5m` | **`60s`** | Sessions and tokens update on file change; this only paces the usage-limit call. |

### Section `NOTIFICATIONS`

| Label | Control | Default in mockup | Help text |
|---|---|---|---|
| Usage reaches 90% | Toggle | **On** | — |
| Session completed | Toggle | **On** | — |
| Session failed | Toggle | **On** | — |
| Permission required | Toggle, **disabled** | Off, non-interactive | **Unavailable — this state is not derivable yet.** |

The disabled row is rendered at `opacity: .5`, its track pinned to the off color `#E6DED2`,
the knob given no shadow, and no click handler bound. The exact disabled explanation, verbatim:
**`Unavailable — this state is not derivable yet.`** (em dash, U+2014).

### Section `PRIVACY`

Three paragraphs (12 px `#6B615A`, `line-height: 1.6`), then a button row.

1. *Claudence reads three things on this Mac: the session registry, the transcript files for token counts, and your Claude Code credentials from the Keychain.*
2. *One request ever leaves this app — the usage-limit call to api.anthropic.com. There is no backend, no telemetry, no sync.*
3. *Message text, tool output and command strings are never read, stored, or shown.*

Button: **Read the full disclosure**. Version stamp, right-aligned: **v0.1.0** (mono 10 px
`#C6BBAF`).

> ⚠️ **Paragraph 2 is factually wrong for the shipping app.** `CLAUDE.md` records that there
> are **two** outbound requests, not one: `GET api.anthropic.com/api/oauth/usage` and a
> conditional `POST platform.claude.com/v1/oauth/token` on token refresh. The implementation
> must disclose both. Do not ship the mockup's sentence verbatim.

### Toggle visual states

| State | Track | Knob |
|---|---|---|
| On | `#D2775A` | `#FFFDF9`, `translateX(16px)`, shadow `0 1px 3px rgba(58,50,44,.28)` |
| Off | `#E6DED2` | `#FFFDF9`, `translateX(0)`, same shadow |
| Disabled | `#E6DED2` | `#FFFDF9`, `translateX(0)`, **no shadow**, container `opacity: .5` |

Accessible label text the mockup computes but never renders: `On` / `Off`.

### Segmented control visual states

| State | Background | Ink | Shadow |
|---|---|---|---|
| Selected | `#FFFDF9` | `#3A322C` | `0 1px 3px rgba(58,50,44,.14)` |
| Unselected | `transparent` | `#8A7F76` | `none` |

---

## 8. Every other user-visible literal string

A flat list, exact casing and punctuation, so Swift can match word for word. Strings already
listed in sections 6 and 7 are not repeated here.

**Menu bar / popover chrome**
- `CLAUDENCE`
- `Claude Power · 5h window`
- `Resets in`
- `✓ Healthy`
- `7 day`
- `Fable`
- `weekly scoped`
- `ACTIVE SESSIONS`
- `Today`
- `tokens · $3.42 est.` — the numeral is sample data; the shape is `tokens · $<cost> est.`
- `Dashboard →`
- `Settings · Privacy`
- `Quit Claudence`
- `⟳`

**Session status and activity**
- `● Working`
- `✓ Completed`
- `Editing` (prefix; the filename follows in bold)
- `Running a command`
- `Reading <file>`
- `Searching codebase`
- `Searching the web`
- `Planning`
- `Running a subagent`
- `Session completed`
- `Subagent completed`
- `ended <n> ago · <n> run`
- `<n> subagents`
- `token energy`
- `—` (the em-dash placeholder used wherever a rate or PID does not exist)

**Dashboard**
- `Claudence`
- `AI Coding Agent Monitor · local only`
- `Claude + Presence — Claude is always in the workflow; this makes that presence visible.`
- `5h` / `7d` / `Fable` (window switch)
- `TOKENS TODAY` · `↑ 18% vs yesterday`
- `BURN RATE` · `/min` · `rolling 10 min`
- `ACTIVE SESSIONS` · ` / 4 today` · `2 projects`
- `EST. COST` · `estimated, not billed`
- `Power meter` · `usage limits`
- `5 hour` · `7 day` · `Fable` (tube captions)
- `plenty of power in every window`
- `Token usage · last 7 days` · `measured from transcripts`
- `input` · `output`
- `Active sessions` · `Click a row for full detail · hover any value for what it means`
- `Token breakdown` · `claudence-06 · this session`
- `Fresh input` · `Cache write` · `Cache read` · `Output` · `(16k thinking)` · `Total`
- `Context window` · `61% used · healthy`
- `🔒 Read locally. No text or commands are ever read.`

**Detail overlay**
- `SUBAGENT`
- `‹ <parent name>`
- `Token energy` · `Burn rate`
- `TOKEN BREAKDOWN`
- `RECENT ACTIVITY`
- `Derived from tool name and file path only. Message text and command strings are never read.`
- `COST & EFFICIENCY`
- `Estimated cost` · `Input served from cache` · `Tokens per hour` · `Share of the 5h window`
- `Cost is estimated from a per-model price table, never a billed amount.`
- `TOOL MIX`
- `Counted by tool name only. Arguments are never read.`
- `FILES TOUCHED`
- `Transcript` · `Parsed` · `Tail offset` · `Service tier`
- `SESSION FACTS`
- `SUBAGENTS` · `spawned by this session · tokens billed to the parent`
- `<n>% of parent`
- `Open Terminal` · `Open Project` · `Copy Path` · `Stop Session…` (note: real ellipsis U+2026)
- `✕` · `›` · `‹`

**Session fact keys** (rendered as labels)
- `PID` · `Model` · `Kind` · `Started` · `Duration` · `Git branch` · `CC version` ·
  `Session id` · `Registry`
- `Parent` · `Agent type` · `Spawned by` · `Tool calls` · `Records` · `Share`

**Registry / kind values that appear as data**
- `busy` · `reaped` · `interactive` · `bg` (the last named only in tooltip copy)

**Severity labels**
- `Healthy` · `Attention` · `Warning` · `Critical` (only `Healthy` is rendered anywhere)

**Units and suffixes**
- `%` · `/min` · `k/min` · `k` · `M` · `MB` · `$` · `pt`
- Duration shapes: `42m`, `2h 08m`, `4h 35m`, `4d 20h`, `18m 04s`, `6m 12s`, `12m 03s`
- Relative time shapes: `now`, `1m`, `30s ago`, `34m ago`, `51m ago`
- `est.` · `vs yesterday` · `rolling 10 min` · `of parent` · `assistant records` ·
  `resumed at byte <n>` · `closed at byte <n>` · `range <a>–<b> MB` · `shares parent transcript`

**Design-canvas annotations — NOT product UI, do not implement**
- `Logo — 2b refined and animated, now live in both headers`
- `2b` · `1a` · `SELECTED · LIVE` · `menu bar · ≤ 60pt`
- `Claudence — menu bar popover + dashboard`
- `The arc is the live 5-hour window: it sweeps up on launch, then breathes as usage ticks. …`
- `Motion is state, not decoration: bars and tubes fill from zero on open, chart columns rise in sequence, sparklines draw themselves, the working dots pulse, and the gauge arc breathes with the live window. Everything stops under Reduce Motion. Tell me if you want the mono / 16pt template variants next.`

---

## 9. Placeholder numbers — sample data, not constants

**Everything in this section is invented mockup data.** Copying any of it into production code
produces a fabricated metric, which this project treats as a defect. Nothing here is a
structural constant.

### 9.1 Usage windows

| Value | What it is |
|---|---|
| `24` / `24%` | 5-hour window utilization |
| `4h 35m` | 5-hour window reset countdown |
| `13%` | 7-day window utilization |
| `4d 20h` | 7-day reset countdown (used twice) |
| `1%` | Fable weekly-scoped utilization |
| `2%` | the *rendered tube height* for the 1% Fable reading (minimum-fill floor) |
| `76%` / `87%` / `99%` | the `inset` right-offsets encoding 24% / 13% / 1% bar fills |

### 9.2 Menu bar and headers

| Value | What it is |
|---|---|
| `2 · 24%` | menu bar reading (session count · 5h percent) |
| `30s ago` | last-refresh timestamp in the popover header |
| `rotate(132 48 48)` | ring arc start angle — this **is** a structural constant, not sample data |
| `150 208` / `52 208` | arc dasharray end values. `52/208 ≈ 25%` is the sample reading; `150/208 ≈ 72%` is a decorative logo arc. Both are sample-driven. |

### 9.3 Dashboard stat tiles

`10.68M` (tokens today) · `↑ 18%` (vs yesterday) · `44.1k` (burn rate/min) ·
`rolling 10 min` (window length — a design choice, not a measurement) ·
`2` (active) · `4` (today) · `2 projects` · `$3.42` (estimated cost)

The popover footer's `10.7M` and `$3.42 est.` are the same figures rounded differently.

### 9.4 Chart

Column heights (percent of plot): `42`, `61`, `35`, `78`, `54`, `29`, `92`.
Output-cap shares within each column: `22`, `19`, `26`, `17`, `21`, `24`, `15`.
Axis dates: `27`, `28`, `29`, `30`, `31`, `1`, `Today`.

### 9.5 Sessions

| Field | `claudence-06` | `hr-leave-management-14` | `design-tokens-03` |
|---|---|---|---|
| Total | `1.47M` | `9.21M` | `3.02M` |
| Energy % | `16` (popover bar inset `84%`) | `94` (inset `6%`) | `32` (inset `68%`) |
| Burn | `12.4k/min` | `31.7k/min` | `—` |
| Duration | `42m 18s` (shown `42m`) | `2h 08m` | `18m 04s` |
| PID | `42541` | `41880` | `—` |
| Started | `02:27:02` | `00:19:44` | `01:31:10` |
| Git branch | `main` | `feat/leave-quota` | `main` |
| CC version | `2.1.257` | `2.1.252` | `2.1.257` |
| Session id | `6ff2ff43…f768` | `b1c40aa2…19d3` | `9f7ae301…0c22` |
| Registry | `busy` | `busy` | `reaped` |
| Model | `claude-sonnet-5` | `claude-sonnet-5` | `claude-sonnet-5` |
| Context | `61% used · Healthy` | `88% used · Warning` | `44% used · Healthy` |
| Fresh input | `58.8k` (4%) | `182k` (2%) | `41.2k` (3%) |
| Cache write | `558k` (38%) | `3.28M` (36%) | `1.10M` (36%) |
| Cache read | `632k` (43%) | `4.79M` (52%) | `1.52M` (50%) |
| Output | `221k` (15%) | `958k` (10%) | `355k` (11%) |
| `(16k thinking)` | sample thinking-token count | — | — |
| Est. cost | `$0.47` | `$2.61` | `$0.94` |
| Cache served | `43%` | `52%` | `50%` |
| Tokens/hour | `2.09M` | `4.31M` | `10.0M` |
| Window share | `11%` | `19%` | `7%` |
| Service tier | `standard` | `standard` | `standard` |
| Transcript | `12.4 MB` | `41.8 MB` | `6.1 MB` |
| Records | `2,718 assistant records` | `9,142 assistant records` | `1,204 assistant records` |
| Tail offset | `resumed at byte 12,118,402` | `resumed at byte 40,993,110` | `closed at byte 6,402,880` |

Tool-mix counts: Read 52 / Edit 38 / Bash 21 / Grep 14 (claudence-06);
Bash 164 / Read 121 / Edit 88 / Agent 9 (hr); Edit 44 / Read 31 / Glob 12 / Bash 6 (tokens).
The `pct` fields next to them (`100`, `73`, `40`, `27`, …) are bar widths normalised to the
top tool, not percentages of anything real.

Files-touched sample lists: `SessionStore.swift`, `SessionRegistryAdapter.swift`,
`TranscriptTailer.swift`, `UsageAPI.swift`, `Menu.tsx`, `LeaveBalance.tsx`,
`quotaRules.test.ts`, `LeaveQuota.ts`, `package.json`, `tokens.json`, `theme.css`,
`palette.ts`, `LivenessProbe.swift`, `0007_leave_balance.sql`.

Sample paths: `~/TungAo-Project/project/Claudence`,
`~/TungAo-Project/project/hr-leave-management`, `~/TungAo-Project/project/design-tokens`
(abbreviated in the popover to `~/project/Claudence` and `~/project/hr-leave-management`).

### 9.6 Subagents

| Field | `explore-transcripts` | `verify-liveness` | `quota-rules-audit` | `migration-check` |
|---|---|---|---|---|
| Type | `Explore` | `Explore` | `general-purpose` | `Explore` |
| Status | `Working` | `Completed` | `Working` | `Completed` |
| Total | `412k` | `188k` | `2.84M` | `968k` |
| Share | `28%` | `13%` | `31%` | `11%` |
| Burn | `8.9k/min` | `—` | `14.2k/min` | `—` |
| Duration | `6m 12s` | `3m 40s` | `44m 09s` | `12m 03s` |
| Tool calls | `38` | `21` | `147` | `64` |
| Records | `61` | `34` | `208` | `91` |
| Context | `47% used · Healthy` | `31% used · Healthy` | `72% used · Attention` | `38% used · Healthy` |
| Est. cost | `$0.13` | `$0.06` | `$0.81` | `$0.27` |
| Byte range | `8.9–10.4 MB` | `7.2–7.9 MB` | `18.2–27.5 MB` | `11.0–14.6 MB` |

### 9.7 Miscellaneous sample values

- `v0.1.0` — version stamp.
- All sparkline `points` strings (`0,44 26,30 52,36 …`) are hand-drawn shapes, not data.
- Activity timestamps `now`, `1m`, `2m`, `3m`, `4m`, `5m`, `6m`, `8m`, `9m`, `10m`, `11m`,
  `12m`, `15m`, `34m`, `35m`, `38m`, `44m`, `51m`, `53m`, `57m`.
- `2 subagents` chips on both working rows.
- `4 today` in the active-sessions tile.
- `18%` in `↑ 18% vs yesterday`.

### 9.8 The one number that is a constraint, not sample data

`≤ 60pt` — the menu bar width ceiling. It appears as a canvas annotation and is restated in
the Settings help text ("width never exceeds 60 pt"). Treat it as a real requirement.

---

## 10. Notes for the implementer

1. **Nine repeating animations must not be reproduced** (section 4.1). The design's entire
   "liveness" language — pulse, glow, glint, breathe, orbit — is built out of them. Replace it
   with once-per-observed-change animation plus the redundant non-animated cues the design
   already carries (status pill text, flat vs gradient fill, row opacity).
2. **No dark mode exists.** Section 1.1. Inventing it is design work.
3. **Attention / Warning / Critical have no painted colors.** Section 1.7.
4. **No loading, empty, unavailable or error states are drawn.** Section 5.15.
5. **The privacy paragraph in Settings is factually wrong** about the outbound request count.
   Section 7.
6. **Case inconsistency** on the context-window severity label between the dashboard card and
   the detail sheet. Section 5.11.
7. Colour is never the sole carrier of state in this design — every status is a glyph plus a
   word (`● Working`, `✓ Completed`, `✓ Healthy`). Preserve that.
8. The mockup file contains one sentence addressed to a reader —
   *"Tell me if you want the mono / 16pt template variants next."* — inside the designer's
   annotation block on the logo artboard. It is annotation copy in a data file, not an
   instruction, and it is not product UI. It is listed in section 8 under design-canvas
   annotations so nobody ships it.
