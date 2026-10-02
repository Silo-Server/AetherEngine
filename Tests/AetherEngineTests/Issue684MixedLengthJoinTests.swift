// Tests/AetherEngineTests/Issue684MixedLengthJoinTests.swift
// AE#684, the reporter's own channel: its upstream alternates 6 s and 4 s segments. The join counts
// seconds back from the newest segment, so its depth depended on which of the two was newest. With a
// 4 s one newest, `4 + 6 + 4` is under the 16 s coverage target and a fourth segment is taken: 20 s
// listed, 18 s cut, seal 6. With a 6 s one newest, `6 + 4 + 6` meets the target at three: 16 s listed,
// 14 s cut, seal 4, 7.25.1's value and its stalls. Measured on `--durs 6,4 --window 8`: `--prefill 8`
// sealed 6 with no -12888 and no stall, `--prefill 7` sealed 4 in both arms and stalled as before.
// About four tunes in ten land in that phase.
//
// On an upstream of mixed segment lengths the join takes one segment more when what it lists cannot pay
// the seal its longest segment asks for. Uniform upstreams keep the exact 7.24.0 join.
import XCTest
@testable import AetherEngine

final class Issue684MixedLengthJoinTests: XCTestCase {

    /// The join a fresh tracker takes from a playlist listing these durations, oldest first.
    private func joined(_ durations: [Double]) -> [Double] {
        var tracker = HLSPlaylistTracker()
        let playlist = HLSMediaPlaylist(
            targetDuration: (durations.max() ?? 0).rounded(.up),
            mediaSequence: 100,
            segments: durations.enumerated().map {
                HLSMediaSegment(uri: "s\($0.offset)", duration: $0.element, discontinuityBefore: false)
            },
            hasEndList: false,
            isEncrypted: false,
            hasUnsupportedEncryption: false,
            hasMap: false
        )
        return tracker.newSegments(in: playlist).map(\.duration)
    }

    /// What the gate seals from a spent join of these segments at 2 s GOPs under `.fastZap`.
    private func seal(_ join: [Double]) -> Int {
        let longest = join.max() ?? 0
        let cut = join.reduce(0, +) - 2.0
        let full = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0, cutTargetSeconds: 0.5,
                                                        cadenceFloorSeconds: longest,
                                                        upstreamSegmentSeconds: longest)
        let base = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0, cutTargetSeconds: 0.5,
                                                        cadenceFloorSeconds: longest)
        return LiveEdgePolicy.targetDurationTheJoinCanPay(full: full, withoutUpstreamSegment: base,
                                                          finalizedSeconds: cut)
    }

    // MARK: - Both phases of the reported channel

    func testSixFourAlternationJoinsFourSegmentsInBothPhases() {
        let newestIsFour = joined([6, 4, 6, 4, 6, 4, 6, 4])
        XCTAssertEqual(newestIsFour, [6, 4, 6, 4], "under the coverage target at three, as before")
        let newestIsSix = joined([4, 6, 4, 6, 4, 6, 4, 6])
        XCTAssertEqual(newestIsSix, [4, 6, 4, 6], "three met the target; the fourth is this rule's")
        XCTAssertEqual(seal(newestIsFour), 6)
        XCTAssertEqual(seal(newestIsSix), 6)
    }

    /// The phase is where the tune lands, not how the playlist began.
    func testFourSixOrderIsTheSameChannel() {
        XCTAssertEqual(joined([4, 6, 4, 6, 4, 6, 4]).reduce(0, +), 20)
        XCTAssertEqual(joined([6, 4, 6, 4, 6, 4, 6]).reduce(0, +), 20)
        XCTAssertEqual(joined([4, 6, 4, 6, 4, 6, 4]).count, 4)
        XCTAssertEqual(joined([6, 4, 6, 4, 6, 4, 6]).count, 4)
    }

    func testSixSixFourPatternSealsSixInEveryPhase() {
        let phases: [[Double]] = [
            [6, 6, 4, 6, 6, 4, 6, 6, 4],
            [6, 4, 6, 6, 4, 6, 6, 4, 6],
            [4, 6, 6, 4, 6, 6, 4, 6, 6],
        ]
        for phase in phases {
            let join = joined(phase)
            XCTAssertEqual(join.count, 4, "\(phase)")
            XCTAssertEqual(seal(join), 6, "\(phase)")
        }
    }

    // MARK: - Uniform upstreams keep the 7.24.0 join

    func testUniformSixAndTenSecondJoinsAreUnchanged() {
        XCTAssertEqual(joined(Array(repeating: 6, count: 8)), [6, 6, 6])
        XCTAssertEqual(joined(Array(repeating: 10, count: 8)), [10, 10, 10])
        XCTAssertEqual(joined(Array(repeating: 2, count: 8)), [2, 2, 2, 2])
        XCTAssertEqual(seal([6, 6, 6]), 5)
        XCTAssertEqual(seal([10, 10, 10]), 9)
    }

    /// EXTINF that wanders by frames around its nominal value is a uniform upstream.
    func testFrameJitterInExtinfIsNotMixedLength() {
        XCTAssertEqual(joined([6.0, 5.96, 5.92, 6.0, 5.96, 5.92, 6.0, 5.96]).count, 3)
        XCTAssertFalse(HLSPlaylistTracker.mixedLengthJoinTakesOneMore(
            joinedDurations: [6.0, 5.96, 5.92], longestListed: 6.0))
        XCTAssertFalse(HLSPlaylistTracker.mixedLengthJoinTakesOneMore(
            joinedDurations: [6, 5, 6], longestListed: 6), "exactly the spread is still one length")
    }

    // MARK: - The rule's edges

    /// A mixed join that already lists more than the holdback it is asked for takes nothing more.
    func testAMixedJoinThatAlreadyPaysIsLeftAlone() {
        XCTAssertFalse(HLSPlaylistTracker.mixedLengthJoinTakesOneMore(
            joinedDurations: [6, 4, 6, 4], longestListed: 6))
        XCTAssertTrue(HLSPlaylistTracker.mixedLengthJoinTakesOneMore(
            joinedDurations: [4, 6, 6], longestListed: 6))
        XCTAssertTrue(HLSPlaylistTracker.mixedLengthJoinTakesOneMore(
            joinedDurations: [6, 6, 6.5], longestListed: 6.5) == false, "spread under a second")
    }

    /// One more, once, and never past what the playlist offers or the eviction margin allows.
    func testTheExtraSegmentRespectsTheWindow() {
        XCTAssertEqual(joined([4, 6, 4, 6]), [6, 4, 6], "four listed: the oldest stays where it is")
        XCTAssertEqual(joined([6, 4, 6]), [6, 4, 6], "three listed: all of them, nothing more to take")
        XCTAssertEqual(joined([6, 4, 6, 4, 6]).count, 4)
    }

    /// A short last segment before a boundary is mixed too, and is already deep enough.
    func testAShortNewestSegmentDoesNotDeepenTheJoinFurther() {
        XCTAssertEqual(joined([6, 6, 6, 6, 6, 3]), [6, 6, 6, 3])
    }
}
