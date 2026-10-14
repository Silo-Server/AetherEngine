import Testing
@testable import AetherEngine

/// Audit SEG-107: `LoadOptions.dvrWindowSeconds` reached `Int(ceil(window / cadence))` unvalidated, so a
/// host expressing "keep everything" as `.infinity` trapped on the first live manifest request.
@Suite("Live window sizing is total over the host's DVR window")
struct LiveWindowSizingTotalityTests {

    @Test("An unbounded window serves the playlist ceiling", arguments: [
        Double.infinity, 1e300, Double.greatestFiniteMagnitude, 5e18,
    ])
    func unboundedWindow(window: Double) {
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 4, dvrWindowSeconds: window)
        #expect(sizing.windowSegmentCount == LiveWindowSizing.maxWindowSegments)
        #expect(sizing.requestedSegmentCount(observedSegmentDurationSeconds: 2) > LiveWindowSizing.maxWindowSegments)
    }

    @Test("A NaN window sizes like no window, a negative one like the smallest")
    func nanAndNegativeWindows() {
        let nan = LiveWindowSizing(targetSegmentDurationSeconds: 4, dvrWindowSeconds: .nan)
        let none = LiveWindowSizing(targetSegmentDurationSeconds: 4, dvrWindowSeconds: nil)
        #expect(nan.windowSegmentCount == none.windowSegmentCount)
        let negative = LiveWindowSizing(targetSegmentDurationSeconds: 4, dvrWindowSeconds: -.infinity)
        #expect(negative.windowSegmentCount == LiveWindowSizing.minSafeSegments)
    }

    @Test("Ordinary windows are unchanged")
    func ordinaryWindows() {
        #expect(LiveWindowSizing(targetSegmentDurationSeconds: 4, dvrWindowSeconds: 1800)
            .requestedSegmentCount(observedSegmentDurationSeconds: nil) == 450)
        #expect(LiveWindowSizing(targetSegmentDurationSeconds: 4, dvrWindowSeconds: 86_400)
            .requestedSegmentCount(observedSegmentDurationSeconds: 6) == 14_400)
    }
}
