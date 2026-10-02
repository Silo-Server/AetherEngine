import Testing
@testable import AetherEngine

/// Issue #27 (Sodalite): FrameDecodeContext requested thread_count = activeProcessorCount,
/// so the disposable scrub-thumbnail decoder grabbed all 6 A12 cores at the same QoS as the
/// real-time software playback decode (and, with subs on, a third context), starving the
/// preview. The still-extraction thumbnail has no clock deadline, so its thread budget must be
/// capped well below the core count to leave headroom for playback.
struct FrameDecodeThreadBudgetTests {

    @Test("still-extraction thread count is capped below the core count")
    func capsThreads() {
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 8) <= 2)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 6) <= 2)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 6) < 6)
    }

    @Test("still-extraction thread count stays at least 1 on constrained hosts")
    func atLeastOne() {
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 1) >= 1)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 0) >= 1)
    }

    /// Each frame thread delays software playback output by one frame, so one thread per core
    /// held 31 frames back after every load and seek on a 32-core Mac.
    @Test("software playback thread count stops at FFmpeg's 16-thread ceiling")
    func playbackCapsAtSixteen() {
        #expect(SoftwareVideoDecoder.playbackThreadCount(activeProcessorCount: 32) == 16)
        #expect(SoftwareVideoDecoder.playbackThreadCount(activeProcessorCount: 16) == 16)
        #expect(SoftwareVideoDecoder.playbackThreadCount(activeProcessorCount: 6) == 6)
        #expect(SoftwareVideoDecoder.playbackThreadCount(activeProcessorCount: 0) == 1)
    }
}
