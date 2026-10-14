import Foundation
import Testing
@testable import AetherEngine

/// The switch waits a load runs are tvOS only, so their two defects are pinned on the parts they are
/// built from: the poll that ends them and the budget that bounds them.
@Suite("Display switch waits: they end with their load and share one observed-end budget")
@MainActor
struct DisplaySwitchWaitBudgetTests {

    /// Audit LIF-106: a `Task.sleep` in a cancelled task throws at once, and the deadline loops wrapped
    /// it in `try?`, so Back during an HDR start spun the main actor until the switch cap (measured at
    /// ~77,000 iterations per second on the loop's shape).
    @Test("A cancelled wait stops at its next tick instead of spinning")
    func cancelledWaitStops() async {
        let wait = Task { @MainActor in
            var ticks = 0
            while ticks < 10_000,
                  await DisplayCriteriaController.gateTick(milliseconds: 50, isCurrent: { true }) {
                ticks += 1
            }
            return ticks
        }
        wait.cancel()
        #expect(await wait.value == 0)
    }

    @Test("A wait whose load was superseded stops at its next tick")
    func supersededWaitStops() async {
        #expect(!(await DisplayCriteriaController.gateTick(milliseconds: 1, isCurrent: { false })))
        #expect(await DisplayCriteriaController.gateTick(milliseconds: 1, isCurrent: { true }))
    }

    private static let second: UInt64 = 1_000_000_000

    /// DEC-105: the #667 wait leaves the record unspent for the play gate, and on a panel that never
    /// announces the end (or whose flag sticks) both read the same `.running` and each spent the full
    /// 6 s on the one switch.
    @Test("Two gates on one armed switch spend one observed-end cap between them")
    func oneBudgetPerArm() {
        let start = 10 * Self.second
        let first = DisplayCriteriaController.observedEndCap(
            settleCap: .awaitObservedEnd, startRecorded: true, armGeneration: 3,
            nowNanos: start, budget: nil)
        #expect(first.capMs == DisplayCriteriaController.observedEndCapMs)

        let afterPartialWait = DisplayCriteriaController.observedEndCap(
            settleCap: .awaitObservedEnd, startRecorded: true, armGeneration: 3,
            nowNanos: start + 2_500_000_000, budget: first.budget)
        #expect(afterPartialWait.capMs == 3500)

        let afterFullWait = DisplayCriteriaController.observedEndCap(
            settleCap: .awaitObservedEnd, startRecorded: true, armGeneration: 3,
            nowNanos: start + 7 * Self.second, budget: first.budget)
        #expect(afterFullWait.capMs == 0)
        #expect(afterFullWait.budget == first.budget)
    }

    @Test("A newly armed switch gets a budget of its own")
    func newArmNewBudget() {
        let spent = DisplayCriteriaController.ObservedEndBudget(armGeneration: 3, deadlineNanos: Self.second)
        let next = DisplayCriteriaController.observedEndCap(
            settleCap: .awaitObservedEnd, startRecorded: true, armGeneration: 4,
            nowNanos: 30 * Self.second, budget: spent)
        #expect(next.capMs == DisplayCriteriaController.observedEndCapMs)
        #expect(next.budget?.armGeneration == 4)
    }

    @Test("The standard cap is per gate as before and never touches the budget")
    func standardCapIsUntouched() {
        let spent = DisplayCriteriaController.ObservedEndBudget(armGeneration: 3, deadlineNanos: Self.second)
        let preflight = DisplayCriteriaController.observedEndCap(
            settleCap: .standard, startRecorded: true, armGeneration: 3,
            nowNanos: 30 * Self.second, budget: spent)
        #expect(preflight.capMs == DisplayCriteriaController.stage2CapMs)
        #expect(preflight.budget == spent)

        let unobserved = DisplayCriteriaController.observedEndCap(
            settleCap: .awaitObservedEnd, startRecorded: false, armGeneration: 3,
            nowNanos: 30 * Self.second, budget: spent)
        #expect(unobserved.capMs == DisplayCriteriaController.stage2CapMs)
        #expect(unobserved.budget == spent)
    }
}
