import Foundation
import Testing

@testable import ClaudenceCore

/// The arithmetic behind arrow-key navigation over the session lists.
///
/// The views that use it are in the executable target, which this test target
/// deliberately does not depend on, so the rules live in Core where they can
/// be asserted rather than argued from reading a view.
@Suite("List keyboard selection")
struct ListKeyboardSelectionTests {

    private let rows = ["a", "b", "c"]

    @Test("down from nothing lands on the first row, up from nothing on the last")
    func enteringFromEitherEnd() {
        #expect(ListKeyboardSelection.move(from: nil, .down, in: rows) == "a")
        #expect(ListKeyboardSelection.move(from: nil, .up, in: rows) == "c")
    }

    @Test("the cursor moves one row at a time")
    func stepsOneAtATime() {
        #expect(ListKeyboardSelection.move(from: "a", .down, in: rows) == "b")
        #expect(ListKeyboardSelection.move(from: "b", .down, in: rows) == "c")
        #expect(ListKeyboardSelection.move(from: "c", .up, in: rows) == "b")
        #expect(ListKeyboardSelection.move(from: "b", .up, in: rows) == "a")
    }

    /// A list of live sessions is short and its ends mean something -- the
    /// newest and the oldest. A cursor that jumped from one to the other reads
    /// as a lost cursor, and it makes a held arrow key impossible to follow.
    @Test("the ends hold rather than wrapping")
    func endsDoNotWrap() {
        #expect(ListKeyboardSelection.move(from: "c", .down, in: rows) == "c")
        #expect(ListKeyboardSelection.move(from: "a", .up, in: rows) == "a")
    }

    @Test("an empty list has nothing to select, whichever way it is asked")
    func emptyListSelectsNothing() {
        #expect(ListKeyboardSelection.move(from: nil, .down, in: []) == nil)
        #expect(ListKeyboardSelection.move(from: nil, .up, in: []) == nil)
        // Including when a selection survived from when the list was not empty.
        #expect(ListKeyboardSelection.move(from: "a", .down, in: []) == nil)
    }

    /// Sessions come and go while the popover is open. Substituting the row
    /// that took the missing one's index would move the cursor onto a row the
    /// user never chose, and Return would then open that one.
    @Test("a selection that left the list is cleared, not replaced by its neighbour")
    func aDepartedRowClearsTheCursor() {
        #expect(ListKeyboardSelection.surviving("b", in: rows) == "b")
        #expect(ListKeyboardSelection.surviving("b", in: ["a", "c"]) == nil)
        #expect(ListKeyboardSelection.surviving(nil, in: rows) == nil)
        #expect(ListKeyboardSelection.surviving("a", in: []) == nil)
    }

    /// The move after a row has gone starts from the end again rather than
    /// from wherever the missing row used to be, which is the behaviour that
    /// makes `surviving` safe to call on every rebuild.
    @Test("a stale identifier is treated as no selection")
    func aStaleIdentifierEntersFromTheEnd() {
        #expect(ListKeyboardSelection.move(from: "gone", .down, in: rows) == "a")
        #expect(ListKeyboardSelection.move(from: "gone", .up, in: rows) == "c")
    }

    @Test("a list of one row is a fixed point in both directions")
    func singleRowHolds() {
        #expect(ListKeyboardSelection.move(from: "only", .down, in: ["only"]) == "only")
        #expect(ListKeyboardSelection.move(from: "only", .up, in: ["only"]) == "only")
        #expect(ListKeyboardSelection.move(from: nil, .down, in: ["only"]) == "only")
    }
}
