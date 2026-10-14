import Foundation
import Testing
@testable import AetherEngine

/// The property the capture exists for: two tests listening at once do not disconnect each other.
/// Swapping the global handler failed it, since whichever test restored last put back a stale one.
@Suite("Engine log capture")
struct EngineLogCaptureTests {

    @Test("ending one capture leaves an overlapping one connected")
    func endingOneLeavesTheOtherConnected() {
        let marker = "capture-\(UUID().uuidString)"
        let first = EngineLogCapture()
        let second = EngineLogCapture()
        defer { second.end() }

        EngineLog.emit("\(marker) before")
        first.end()
        EngineLog.emit("\(marker) after")

        #expect(first.matching(marker).count == 1)
        #expect(second.matching(marker).count == 2)
    }
}
