import Foundation
import ClaudenceCore

/// What the onboarding import step needs from history import, named as a
/// closure rather than a direct dependency on `HistoryImporter` so the view
/// that offers it does not have to know how an importer is built or reach
/// into `Composition`'s adapters itself.
///
/// ## Status
///
/// `HistoryImporter` landed in Core on 2026-09-03 while this screen was being
/// built. This type is wired to it directly -- see `Composition.makeServices()`
/// -- rather than left as an unimplemented seam, because the seam's whole
/// purpose was to let this view be finished before that type existed without
/// this file reaching into Core to build one by hand.
///
/// The seam is kept rather than deleted now that its reason is gone, because
/// it is still the right shape: a test can hand `OnboardingView` a
/// `HistoryImportRunner` that returns a canned `Report` without touching a
/// real filesystem, and the view never needs to know `HistoryImporter` or
/// `ClaudenceStore` exist.
///
/// Expected signature, for whoever next changes what runs underneath this:
/// `run(Date) async -> HistoryImporter.Report`, called with the start date the
/// user chose, and run off the main actor -- the walk reads every transcript
/// on disk and must not block it. `Composition` wraps the real call in
/// `Task.detached` for exactly that reason.
struct HistoryImportRunner: Sendable {
    let run: @Sendable (Date) async -> HistoryImporter.Report
}
