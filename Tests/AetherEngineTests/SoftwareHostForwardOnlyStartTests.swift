import Testing
@testable import AetherEngine

/// How the software host honours a start position on a source it cannot reposition.
///
/// A forward-only source (one chunked response with no ranges, a sequential origin, a one-shot
/// custom reader) has exactly one read position. Seeking it on load flushed the packets the probe
/// had read; the reader could not rewind to read them again, libavformat reported `partial file`
/// for the first sample, and the session reached `ready` and then never played. A host resuming a
/// server-seeked progressive stream hit this on every resume, because the server starts the
/// stream at the preceding keyframe and asks the player to skip the pre-roll.
@Suite("Software host start position on a forward-only source")
struct SoftwareHostForwardOnlyStartTests {
    private typealias Host = SoftwarePlaybackHost

    @Test("No start, a zero start and a non-finite start all play from the origin")
    func noStartPlaysFromOrigin() {
        for start in [nil, 0, -3, Double.nan, Double.infinity] as [Double?] {
            for seekable in [true, false] {
                #expect(Host.startPlan(startPosition: start, isSourceSeekable: seekable, isLive: false) == .fromOrigin)
            }
        }
    }

    @Test("A seekable source is repositioned to its start, however far")
    func seekableSourceRepositions() {
        #expect(Host.startPlan(startPosition: 2.8, isSourceSeekable: true, isLive: false) == .reposition)
        #expect(Host.startPlan(startPosition: 5_000, isSourceSeekable: true, isLive: false) == .reposition)
    }

    @Test("A forward-only source decodes forward to a start inside the limit and is never repositioned")
    func forwardOnlySourceDecodesForward() {
        #expect(Host.startPlan(startPosition: 0.8, isSourceSeekable: false, isLive: false) == .decodeForward)
        #expect(Host.startPlan(startPosition: Host.forwardOnlyStartSkipLimitSeconds,
                               isSourceSeekable: false, isLive: false) == .decodeForward)
    }

    @Test("The decode-forward limit is the clock anchor's tolerance")
    func limitIsTheClockAnchorTolerance() {
        // Past the tolerance the clock re-anchors at the first sample, which without a reposition
        // is the stream origin: pre-roll audio with no picture. The two must move together.
        let limit = Host.forwardOnlyStartSkipLimitSeconds
        #expect(limit == SWClockAnchorPolicy.toleranceSeconds)
        #expect(SWClockAnchorPolicy.resolve(initialSeconds: limit, firstSampleSeconds: 0).anchorSeconds == limit)
        #expect(SWClockAnchorPolicy.resolve(initialSeconds: limit + 0.1, firstSampleSeconds: 0).anchorSeconds == 0)
    }

    @Test("A forward-only source drops a start the clock anchor would not hold")
    func forwardOnlySourceDropsAFarStart() {
        #expect(Host.startPlan(startPosition: Host.forwardOnlyStartSkipLimitSeconds + 0.1,
                               isSourceSeekable: false, isLive: false) == .dropStart)
        #expect(Host.startPlan(startPosition: 1_004.87, isSourceSeekable: false, isLive: false) == .dropStart)
    }

    @Test("A seek is refused on a forward-only source, and never on a live or seekable one")
    func seekRefusal() {
        #expect(AetherEngine.seekRefusedForForwardOnlySource(isLive: false, sourceCanReposition: false))
        #expect(!AetherEngine.seekRefusedForForwardOnlySource(isLive: false, sourceCanReposition: true))
        #expect(!AetherEngine.seekRefusedForForwardOnlySource(isLive: true, sourceCanReposition: false))
        #expect(!AetherEngine.seekRefusedForForwardOnlySource(isLive: true, sourceCanReposition: true))
    }

    @Test("A live source keeps its existing start handling")
    func liveKeepsItsStartHandling() {
        #expect(Host.startPlan(startPosition: 40, isSourceSeekable: false, isLive: true) == .reposition)
        #expect(Host.startPlan(startPosition: 40, isSourceSeekable: true, isLive: true) == .reposition)
    }
}
