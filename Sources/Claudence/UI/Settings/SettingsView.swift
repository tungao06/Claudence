import SwiftUI

// MARK: - Layout tokens

/// Tokens the popover never needed. Added here rather than in `Theme.swift`
/// because settings is the only surface that is a real window.
extension Theme.Layout {
    /// The card's own width. Design 5.14 draws it at 420 pt with an 18 pt
    /// radius, `surface` on `canvas` — identical to the popover shell, just
    /// hosted in a window instead of a `MenuBarExtra` attachment.
    static let settingsWidth: CGFloat = 420
    /// Horizontal padding inside a section block. Design's per-block padding
    /// is "16px 20px"; 20 is exact, so it is kept as its own constant rather
    /// than folded into `Theme.Space`, whose nearest rung (`xl`, 18) would
    /// quietly round a value the source is explicit about.
    static let settingsPadding: CGFloat = 20
    static let settingsMinHeight: CGFloat = 420
    static let settingsMaxHeight: CGFloat = 760
    /// Gap between the card's edge and the window's, so the design's `canvas`
    /// ground shows as a visible margin rather than a hairline.
    static let settingsCardMargin: CGFloat = Theme.Space.xl
    /// The window itself. Wider than the card by the margin on both sides, so
    /// the card renders at exactly the design's 420 pt regardless of how much
    /// ground shows around it.
    static var settingsWindowWidth: CGFloat { settingsWidth + settingsCardMargin * 2 }
    /// Indent for a cluster of controls nested under a master switch — the
    /// notification section's per-event toggles under "Notify me…". Not used
    /// for the ordinary label/explanation pairing inside a single row; that
    /// pair now shares one left edge, matching the design's own column.
    static let settingsExplanationIndent: CGFloat = 20
    /// How far a permanently unavailable row is dimmed. Design section 7 draws
    /// the disabled notification row at half strength; the inline sentence
    /// beside it, not the dimming, is what actually explains the state.
    static let settingsDisabledOpacity: Double = 0.5
}

/// Pixel metrics for the toggle and segmented pill that the design specifies
/// as literal numbers (3.6 and 7's visual-state tables) rather than as
/// anything already in `Theme`'s spacing or radius ladders. Kept local to this
/// file, next to the two controls that use them, rather than lobbied into
/// `Theme.swift` for two numbers nothing else in the app needs.
private enum ControlMetric {
    static let toggleTrackWidth: CGFloat = 40
    static let toggleTrackHeight: CGFloat = 24
    static let toggleKnobSize: CGFloat = 18
    static let toggleKnobInset: CGFloat = 3
    static let toggleKnobTravel: CGFloat = 16
    static let segmentTroughPadding: CGFloat = 3
    static let segmentGap: CGFloat = 2
    static let segmentVerticalPadding: CGFloat = 7
    static let segmentHorizontalPadding: CGFloat = 8
}

// MARK: - Section chrome

/// A titled block, padded and ruled off exactly as the design's own settings
/// card divs are: 20 pt horizontal padding, a bottom hairline, and an 11 pt
/// bold, tracked eyebrow. Every pane composes these directly against each
/// other with no gap of its own, so the hairline this view draws is the only
/// seam between one topic and the next — precisely the design's card, which
/// never leaves a gap between one bordered div and the one below it.
///
/// `showDivider` exists for exactly one caller: the very last section in the
/// card, `PRIVACY`, which the design does not rule off, because there is
/// nothing beneath it before the card's rounded corner.
struct SettingsSection<Content: View>: View {
    let title: String
    var showDivider: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title.uppercased())
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Layout.settingsPadding)
        .padding(.vertical, Theme.Space.l)
        .overlay(alignment: .bottom) {
            if showDivider {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 1)
            }
        }
    }
}

/// The one-line explanation that sits under a control's label.
///
/// Hidden from VoiceOver: the same sentence is attached to its control as an
/// accessibility hint, and reading it twice is worse than reading it once.
struct SettingsExplanation: View {
    let text: String
    /// True only for the notification section's nested per-event cluster,
    /// where a whole group of rows sits under a master switch. An ordinary
    /// row's own explanation shares its label's left edge, per the design's
    /// single-column layout for a control's text.
    var indented: Bool = false

    var body: some View {
        Text(text)
            .font(Theme.Typography.help)
            .foregroundStyle(Theme.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, indented ? Theme.Layout.settingsExplanationIndent : 0)
            .accessibilityHidden(true)
    }
}

// MARK: - Toggle

/// The design's own switch: a 40x24 pill track and an 18 pt knob that travels
/// 16 pt, rendered from `Theme` tokens rather than the system's blue/green
/// `.switch` style so a Claudence window and a Claudence popover agree on
/// what "on" looks like.
///
/// The knob's shadow is the one place this file reads `isEnabled` directly:
/// the design's disabled state (section 7) pins the track to its off colour
/// *and* drops the knob's shadow, and colour is not allowed to carry that
/// difference alone.
///
/// Motion: the knob's travel animates once per change, gated the same way as
/// every other animation in the app — through `Theme.animation`, which
/// returns nil under Reduce Motion so the knob snaps instead of gliding. There
/// is no repeat here to gate in the first place.
struct ClaudenceToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Radius.pill)
                .fill(configuration.isOn ? Theme.accent : Theme.track)
                .frame(width: ControlMetric.toggleTrackWidth, height: ControlMetric.toggleTrackHeight)

            knob
                .padding(.leading, ControlMetric.toggleKnobInset)
                .offset(x: configuration.isOn ? ControlMetric.toggleKnobTravel : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            configuration.isOn.toggle()
        }
        .animation(
            Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
            value: configuration.isOn
        )
    }

    @ViewBuilder
    private var knob: some View {
        let circle = Circle()
            .fill(Theme.surface)
            .frame(width: ControlMetric.toggleKnobSize, height: ControlMetric.toggleKnobSize)
        if isEnabled {
            circle.themeShadow(Theme.Shadow.knob)
        } else {
            circle
        }
    }
}

/// A switch with its label and the sentence underneath it, laid out as the
/// design's own row: label and help text share a left column, the switch sits
/// at the row's trailing edge, and the whole row is vertically centered on the
/// text column rather than on the switch alone.
///
/// The sentence is attached to the control as an accessibility hint and hidden
/// from VoiceOver where it is printed, so it is heard once and read once.
struct SettingsToggle: View {
    let title: String
    let explanation: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(Theme.Typography.cardTitle.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                SettingsExplanation(text: explanation)
            }

            Toggle(isOn: $isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(ClaudenceToggleStyle())
                .accessibilityLabel(title)
                .accessibilityHint(explanation)
        }
    }
}

/// A switch for something Claudence cannot do.
///
/// Not a toggle bound to a dead preference: there is no preference behind it at
/// all, and there is no binding a click could write to. `CLAUDE.md` forbids
/// shipping UI for a state with no data source, and the honest rendering of a
/// state with no source is to show that the option exists, show that it is off,
/// and say why in a sentence rather than leaving the reader to infer it from a
/// grey pixel.
struct SettingsUnavailableToggle: View {
    let title: String
    let reason: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(Theme.Typography.cardTitle.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                SettingsExplanation(text: reason)
            }

            Toggle(isOn: .constant(false)) { EmptyView() }
                .labelsHidden()
                .toggleStyle(ClaudenceToggleStyle())
                .disabled(true)
        }
        .opacity(Theme.Layout.settingsDisabledOpacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("Unavailable")
        .accessibilityHint(reason)
    }
}

// MARK: - Segmented control

/// The design's segmented pill: a `surfaceControl` trough, 3 pt of inner
/// padding, 2 pt between segments, and a selected segment that lifts onto
/// `surface` with `Shadow.segment` while its neighbours sit flat and quiet.
/// Section 7's visual-state table is the literal source for both colour pairs.
///
/// This replaces `Picker(...).pickerStyle(.segmented)`, which draws the
/// system's own blue-selection segmented control and has no seam to carry the
/// design's colours through. The binding it closes over is the same one the
/// system control would have used, so nothing about what the setting reads or
/// writes changes — only how the choice is drawn.
///
/// Exposed as a single accessibility element with an adjustable action rather
/// than one element per segment, so VoiceOver's contract with this control —
/// one label, one current value, swipe up or down to change it — is exactly
/// what the `Picker` it replaces already offered.
struct SettingsSegmentedControl<Value: Hashable & Identifiable>: View {
    let options: [Value]
    let optionTitle: (Value) -> String
    @Binding var selection: Value
    var isEnabled: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: ControlMetric.segmentGap) {
            ForEach(options) { option in
                segment(for: option)
            }
        }
        .padding(ControlMetric.segmentTroughPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.surfaceControl)
        )
        .opacity(isEnabled ? 1 : Theme.Layout.settingsDisabledOpacity)
        .animation(Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion), value: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            guard isEnabled, let index = options.firstIndex(of: selection) else { return }
            switch direction {
            case .increment where index + 1 < options.count:
                selection = options[index + 1]
            case .decrement where index > 0:
                selection = options[index - 1]
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func segment(for option: Value) -> some View {
        let isSelected = option == selection
        Button {
            guard isEnabled else { return }
            selection = option
        } label: {
            let label = Text(optionTitle(option))
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                .padding(.vertical, ControlMetric.segmentVerticalPadding)
                .padding(.horizontal, ControlMetric.segmentHorizontalPadding)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .fill(isSelected ? Theme.surface : Color.clear)
                )
            if isSelected {
                label.themeShadow(Theme.Shadow.segment)
            } else {
                label
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// A segmented choice with its label above and the sentence underneath, full
/// width, exactly as the design's own "What to show" / "Appearance" /
/// "Usage refresh" rows are drawn — unlike a toggle row, the control here
/// spans the row rather than sitting beside the label.
///
/// `explanation` is fixed rather than derived from the selection: these controls
/// answer "what does this setting do", and a sentence that changed on every tap
/// would make the reader re-read it to find out whether anything else had.
struct SettingsPicker<Value: Hashable & Identifiable>: View {
    let title: String
    let options: [Value]
    let optionTitle: (Value) -> String
    let explanation: String
    @Binding var selection: Value
    var isEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Typography.cardTitle.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            SettingsSegmentedControl(
                options: options,
                optionTitle: optionTitle,
                selection: $selection,
                isEnabled: isEnabled
            )
            .accessibilityLabel(title)
            .accessibilityValue(optionTitle(selection))
            .accessibilityHint(explanation)

            SettingsExplanation(text: explanation)
        }
    }
}

/// A paragraph of body copy. Used by the privacy disclosure, which is prose
/// rather than controls.
struct SettingsParagraph: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Version

/// The application version, read from the bundle and never invented.
///
/// A binary launched outside a bundle has no `Info.plist`, so both keys can be
/// absent. That state is reported as "unknown"; a plausible-looking version
/// string would be a fabricated number, which section 9.4 forbids.
enum AppVersion {
    static let unknown = "unknown"

    static var short: String { string(forKey: "CFBundleShortVersionString") }
    static var build: String { string(forKey: "CFBundleVersion") }

    /// The design's footer stamp: `v0.1.0`, or the bundle's own short version
    /// with a `v` in front of it. `unknown` is passed through unprefixed, since
    /// `vunknown` reads as a version rather than as an absence.
    static var stamp: String {
        let short = short
        return short == unknown ? unknown : "v\(short)"
    }

    /// `0.1.0 (1)`, or `unknown` when the bundle says nothing.
    static var display: String {
        let short = short
        let build = build
        if short == unknown && build == unknown { return unknown }
        if build == unknown { return short }
        return "\(short) (\(build))"
    }

    private static func string(forKey key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return unknown }
        return value
    }
}

// MARK: - Settings

/// The settings window.
///
/// Five sections, in the design file's own order: MOTION, MENU BAR, SESSIONS,
/// NOTIFICATIONS, PRIVACY. An earlier build split the design's MENU BAR block
/// across three eyebrows of its own and appended an `About` section the design
/// does not have; the version stamp `About` carried is back where the design
/// puts it, in the privacy footer, and its estimate disclaimer is the last block
/// of the full disclosure.
///
/// The card itself is the design's shell, transcribed rather than adapted: a
/// `surface` panel at the design's own 420 pt, radius 18, bordered and shadowed
/// exactly as the popover is, floating on the `canvas` ground the design
/// specifies by name. Each section below draws its own bottom hairline, so
/// the card needs no spacing of its own between them — the rule is the gap.
struct SettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHeader()
                MotionSettings(preferences: preferences)
                MenuBarSettings(preferences: preferences)
                SessionsSettings(preferences: preferences)
                NotificationSettings(preferences: preferences)
                PrivacySettings()
                QuitSection()
            }
            .frame(width: Theme.Layout.settingsWidth, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.shell))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.shell)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
            .themeShadow(Theme.Shadow.popover)
            .padding(Theme.Layout.settingsCardMargin)
        }
        .frame(width: Theme.Layout.settingsWindowWidth)
        .frame(
            minHeight: Theme.Layout.settingsMinHeight,
            maxHeight: Theme.Layout.settingsMaxHeight
        )
        .background(Theme.canvas)
    }
}

// MARK: - Quit

/// A second way out of the application.
///
/// The menu bar item is the first, and it is always there while the process is:
/// `MenuBarExtra` is inserted unconditionally, so nothing in this application
/// hides it. What this application cannot control is macOS running out of menu
/// bar: on a display with a notch and a crowded strip, the item is pushed under
/// it and there is no way to click something that is not on screen. Claudence is
/// `LSUIElement`, so there is no Dock icon to right-click and no entry in the
/// Force Quit list either, and a user in that position has nothing left but
/// Activity Monitor.
///
/// So the settings window carries Quit as well. It is reachable from the
/// dashboard window, which survives the popover being unreachable, and the
/// sentence beside it names the command that works when every window is gone.
struct QuitSection: View {
    var body: some View {
        SettingsSection(title: "Quit") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button("Quit Claudence") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityLabel("Quit Claudence")
                .accessibilityHint(Self.explanation)

                SettingsExplanation(text: Self.explanation)
            }
        }
    }

    private static let explanation = """
    Also in the menu bar popover. If the menu bar item is not reachable, \
    `pkill -f Claudence.app/Contents/MacOS/Claudence` in Terminal ends it.
    """
}

// MARK: - Header

/// Title and the one-line promise, verbatim from design section 5.14. The
/// promise is checkable: the privacy section below says exactly which two
/// requests leave the machine, and neither carries anything set here.
struct SettingsHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text("Claudence Settings")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Local only \u{00B7} nothing here leaves your Mac")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textQuaternary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Layout.settingsPadding)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.l)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
        }
    }
}

// MARK: - Scene

/// The settings window, ready to be added to the app's `body`. Exposed as a
/// `Scene` so composition is one line and `ClaudenceApp` needs no knowledge of
/// what settings contains.
struct SettingsScene: Scene {
    let preferences: Preferences

    var body: some Scene {
        Settings {
            SettingsView(preferences: preferences)
        }
    }
}
