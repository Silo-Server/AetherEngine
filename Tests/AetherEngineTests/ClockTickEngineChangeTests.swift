import Combine
import Testing
@testable import AetherEngine

/// `player.clock` exists so the ~10 Hz ticks never fire `objectWillChange` on the engine (docs/api.md,
/// Time). `playlistShiftSeconds` is published on the engine, and the tick assigned it on every pass
/// whether it had moved or not, so every SwiftUI view observing the engine re-rendered at 10 Hz again.
@Suite("The clock tick leaves the engine's objectWillChange quiet")
@MainActor
struct ClockTickEngineChangeTests {

    @Test("A shift that did not move is not published again on the next tick (audit PERF-106)")
    func steadyShiftIsNotRepublished() throws {
        let engine = try AetherEngine()
        engine.setPresentationAxis(.anchored(shiftSeconds: 12.5))
        engine.applyNativeHostClockTick(1.0)
        #expect(engine.playlistShiftSeconds == 12.5)

        var changes = 0
        let sub = engine.objectWillChange.sink { changes += 1 }
        defer { sub.cancel() }
        for tick in 1...20 {
            engine.applyNativeHostClockTick(1.0 + Double(tick) * 0.1)
        }

        #expect(changes == 0)
        #expect(engine.playlistShiftSeconds == 12.5)
    }

    @Test("A shift that did move is still published")
    func movedShiftIsPublished() throws {
        let engine = try AetherEngine()
        var map = PresentationAxisMap.anchored(shiftSeconds: 12.5)
        map.appendSeam(shiftSeconds: 30, activatingAtItemSeconds: 5)
        engine.setPresentationAxis(map)
        engine.applyNativeHostClockTick(1.0)
        #expect(engine.playlistShiftSeconds == 12.5)

        var changes = 0
        let sub = engine.objectWillChange.sink { changes += 1 }
        defer { sub.cancel() }
        engine.applyNativeHostClockTick(6.0)

        #expect(changes == 1)
        #expect(engine.playlistShiftSeconds == 30)
    }
}
