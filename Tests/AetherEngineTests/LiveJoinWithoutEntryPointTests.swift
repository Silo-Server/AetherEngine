// AE#627: a live join that reads video for the whole keyframe wait and finds nothing the native route
// can open a segment on. Reopening joins the same bitstream, so three barren cycles bought a minute of
// black before the host heard anything. The first join now goes to the software path, or to the host.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Live join without an entry point (AE#627)")
struct LiveJoinWithoutEntryPointTests {

    @Test("A first join that starved while video kept arriving has no entry point")
    func firstJoinStarvedOnVideo() {
        #expect(HLSVideoEngine.liveJoinFoundNoEntryPoint(
            reason: .keyframeStarvation, segmentsProduced: 0, starvedVideoDrops: 794))
    }

    /// Segments exist, so the bitstream had an entry point once: this is a mid-session loss, which
    /// is what the reopen budget is for.
    @Test("A starvation after segments were produced keeps its reopens")
    func laterStarvationReopens() {
        #expect(!HLSVideoEngine.liveJoinFoundNoEntryPoint(
            reason: .keyframeStarvation, segmentsProduced: 12, starvedVideoDrops: 794))
    }

    /// No video arrived at all, so nothing is known about the bitstream and a reopen may well help.
    @Test("A wait that saw no video is not a verdict on the bitstream")
    func noVideoIsNotAVerdict() {
        #expect(!HLSVideoEngine.liveJoinFoundNoEntryPoint(
            reason: .keyframeStarvation, segmentsProduced: 0, starvedVideoDrops: 0))
    }

    @Test("Other pump exits are not a join without an entry point")
    func otherExits() {
        for reason: HLSSegmentProducer.PumpExitReason in [.eof, .readError(code: -5), .segmentStall] {
            #expect(!HLSVideoEngine.liveJoinFoundNoEntryPoint(
                reason: reason, segmentsProduced: 0, starvedVideoDrops: 794))
        }
    }

    private static func availability(hostAllows: Bool = true, path: DecodePath = .automatic)
        -> SoftwarePathEscalation.Availability {
        SoftwarePathEscalation.Availability(
            alreadyEscalated: false, preferredDecodePath: path, nativeRemoteHLS: false,
            hostAllowsEscalation: hostAllows)
    }

    @Test("The join verdict is offered the software path like a media failure")
    func joinVerdictEscalates() {
        #expect(SoftwarePathEscalation.shouldEscalate(
            errorDomain: SoftwarePathEscalation.liveJoinErrorDomain, availability: Self.availability()))
    }

    @Test("A host that declined the rung, or a session already on software, is not escalated")
    func declinedOrPinned() {
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: SoftwarePathEscalation.liveJoinErrorDomain,
            availability: Self.availability(hostAllows: false)))
        #expect(!SoftwarePathEscalation.shouldEscalate(
            errorDomain: SoftwarePathEscalation.liveJoinErrorDomain,
            availability: Self.availability(path: .software)))
    }
}
