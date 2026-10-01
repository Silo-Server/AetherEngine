// Tests/AetherEngineTests/Issue684JoinBoundSealTests.swift
// AE#684 review: sealing over the upstream segment made every zap on a SHALLOW upstream window slower.
// An upstream that lists three 6 s segments joins 18 s; the last GOP stays open until the next upstream
// delivery, so 16 s are cut, and the 18 s holdback of a TARGETDURATION 6 is not reachable from the join
// at all. The gate waited out the fastZap grace and served under its own holdback: measured 4.25 s to
// first picture where 7.25.1 took 0.18 s (2.24 s with the first-serve latch alone). `.standard` has no
// bounded start and waits for the next upstream segment instead.
//
// A join that has handed over everything it will seals the largest value its cut content covers, between
// what the seal was without the upstream term and the full one.
import XCTest
@testable import AetherEngine

private final class JoinedUpstream: @unchecked Sendable {
    var segmentDuration: Double?
    var joinBacklog: Double?
}

final class Issue684JoinBoundSealTests: XCTestCase {

    private func makeProvider(_ upstream: JoinedUpstream, cutTarget: Double,
                              boundedStart: Bool) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let policy = LiveCadencePolicy(
            observe: { 0.1 },
            cutTargetSeconds: cutTarget,
            observeSealEvidence: {
                LiveCadenceEvidence(closedCadenceSeconds: nil,
                                    servedSegmentDurationSeconds: upstream.segmentDuration,
                                    joinBacklogSeconds: upstream.joinBacklog)
            },
            selfReportedTargetDurationSeconds: upstream.segmentDuration,
            clock: { 0 }
        )
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.4D001E,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (720, 576),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 1_500_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: cutTarget, dvrWindowSeconds: nil),
            allowsBoundedDegradedStart: boundedStart,
            liveCadencePolicy: policy
        )
        return (provider, cache)
    }

    private func append(_ provider: VideoSegmentProvider, count: Int, each: Double) {
        for index in 0..<count {
            provider.appendLiveSegment(index: index, startSeconds: Double(index) * each, durationSeconds: each)
        }
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// The reviewer's shape: three 6 s segments, fastZap, eight 2 s GOPs cut.
    func testShallowFastZapJoinServesAtOnceOnTheSealItCanPay() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 18.0
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: true)
        defer { cache.close() }
        append(provider, count: 8, each: 2.0)

        var served = false
        let waited = seconds { served = provider.waitForFirstLiveSegment(timeout: 5) }
        XCTAssertTrue(served)
        XCTAssertLessThan(waited, 0.5, "no grace: the join has nothing more to give")
        let td = provider.liveTargetDurationSeconds(maxSegmentDuration: 2.0)
        XCTAssertEqual(td, 5, "16 s of window pays for 5, between the old 4 and the full 6")
        XCTAssertLessThanOrEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 16.0,
                                 "and the holdback it advertises is one the window holds")
    }

    /// The same join one upstream segment deeper pays in full.
    func testDeepJoinKeepsTheFullSeal() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 24.0
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: true)
        defer { cache.close() }
        append(provider, count: 11, each: 2.0)
        XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 5))
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 2.0), 6)
    }

    /// A join still arriving is not exhausted: the gate keeps waiting for the cushion, as before.
    func testAJoinStillArrivingIsNotSealedShort() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 24.0
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 5, each: 2.0)
        let derivation = provider.firstServeTargetDuration((count: 5, summed: 10.0, maxDuration: 2.0))
        XCTAssertEqual(derivation.value, 6)
        XCTAssertNil(derivation.joinBound)
    }

    /// `.standard` on a 10 s provider listing three segments: 4 s cuts, 28 s of them. It has no
    /// bounded start, so without this it waits for the next upstream segment, up to 10 s of wall clock.
    func testShallowStandardJoinOnTenSecondSegmentsServesAtOnce() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 10.0
        upstream.joinBacklog = 30.0
        let (provider, cache) = makeProvider(upstream, cutTarget: 4.0, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 7, each: 4.0)

        var served = false
        let waited = seconds { served = provider.waitForFirstLiveSegment(timeout: 5) }
        XCTAssertTrue(served)
        XCTAssertLessThan(waited, 0.5)
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 4.0), 9,
                       "28 s of window pays for 9, between the old 7 and the full 10")
    }

    /// `.standard` on 6 s segments was at 6 before the term and is at 6 with it: nothing to pay down.
    func testStandardOnSixSecondSegmentsIsWhatItWas() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 18.0
        let (provider, cache) = makeProvider(upstream, cutTarget: 4.0, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 4, each: 4.0)
        let derivation = provider.firstServeTargetDuration((count: 4, summed: 16.0, maxDuration: 4.0))
        XCTAssertEqual(derivation.value, 6)
        XCTAssertNil(derivation.joinBound)
    }

    /// The seal line says what was paid and what was asked, and the drift line names the term too.
    func testSealAccountStatesWhatTheJoinPaid() {
        var derivation = LiveTargetDurationDerivation(
            value: 5, maxSegmentDuration: 2.0, cutTargetFloor: 0.5,
            cadenceFloor: .measured(6.0), upstreamSegment: 6.0, selfReported: 6.0)
        derivation.joinBound = (backlogSeconds: 18.0, finalizedSeconds: 16.0, full: 6)
        let account = derivation.account
        XCTAssertTrue(account.contains("sealed at 5s (holdback 15.000s)"), account)
        XCTAssertTrue(account.contains("upstream segment 6.000s"), account)
        XCTAssertTrue(account.contains("of which the join pays 5s of 6s (16.000s cut of the 18.000s it held)"),
                      account)
    }
}
