import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

/// Audit HLS-102: the segment-plan builders converted durations and index timestamps to `Int64` / `Int`
/// with trapping conversions and sized arrays from the duration. A container header can state about
/// 9.2e12 s, and a Matroska index can carry entries near both `Int64` extremes (libavformat rejects only
/// the relative-timestamp band), so nothing upstream bounded either.
@Suite("Segment-plan inputs from a hostile header or index")
struct SegmentPlanHostileInputTests {

    private let ts90k = AVRational(num: 1, den: 90_000)
    private let nanos = AVRational(num: 1, den: 1_000_000_000)

    // MARK: - Container duration

    @Test("A container duration past a week is clamped to a week, not zeroed")
    func containerDurationClamps() {
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: nil, discTitle: nil, container: 9.2e12) == 604_800)
        #expect(Demuxer.effectiveDurationSeconds(
            declared: 1e13, readerDuration: nil, discTitle: nil, container: 7508) == 604_800)
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: 1e13, discTitle: nil, container: 7508) == 604_800)
    }

    @Test("A non-finite duration resolves to zero")
    func nonFiniteDurationIsZero() {
        #expect(Demuxer.effectiveDurationSeconds(
            declared: .infinity, readerDuration: nil, discTitle: nil, container: 7508) == 0)
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: nil, discTitle: .infinity, container: 7508) == 0)
    }

    @Test("An ordinary duration keeps the precedence chain")
    func ordinaryDurationUnchanged() {
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: nil, discTitle: 42, container: 91_843.97) == 42)
        #expect(Demuxer.effectiveDurationSeconds(
            declared: nil, readerDuration: nil, discTitle: nil, container: 7508.93) == 7508.93)
    }

    // MARK: - Index entries

    @Test("Index entries past 2^62 ticks or 4e9 seconds are implausible")
    func implausibleIndexEntries() {
        #expect(Demuxer.isPlausibleIndexTimestamp(Int64.max - (1 << 49), timeBase: ts90k) == false)
        #expect(Demuxer.isPlausibleIndexTimestamp(Int64.min + 1, timeBase: ts90k) == false)
        #expect(Demuxer.isPlausibleIndexTimestamp(Int64.min, timeBase: ts90k) == false)
        // 2^61 ticks at 90 kHz is 2.56e13 s, far past the seconds limit.
        #expect(Demuxer.isPlausibleIndexTimestamp(1 << 61, timeBase: ts90k) == false)
        #expect(Demuxer.isPlausibleIndexTimestamp(1 << 62, timeBase: nanos) == false)
    }

    @Test("Real index entries, epoch-anchored ones included, stay plausible")
    func plausibleIndexEntries() {
        #expect(Demuxer.isPlausibleIndexTimestamp(0, timeBase: ts90k))
        #expect(Demuxer.isPlausibleIndexTimestamp(-3003, timeBase: ts90k))
        #expect(Demuxer.isPlausibleIndexTimestamp(Int64(7508.9 * 90_000), timeBase: ts90k))
        // Epoch nanoseconds in 2026 (1.79e18) and epoch at 10 MHz.
        #expect(Demuxer.isPlausibleIndexTimestamp(1_790_000_000_000_000_000, timeBase: nanos))
        #expect(Demuxer.isPlausibleIndexTimestamp(17_900_000_000_000_000, timeBase: AVRational(num: 1, den: 10_000_000)))
    }

    @Test("The multi-clip fold and the composition offset drop an entry that would overflow")
    func foldAndOffsetAreChecked() {
        // A disc playlist stating a shift of 2e14 s is 1.8e19 ticks at 90 kHz.
        #expect(Demuxer.foldedIndexTimestamp(90_000, subtractSeconds: 2e14, timeBase: ts90k) == nil)
        #expect(Demuxer.foldedIndexTimestamp(90_000, subtractSeconds: .nan, timeBase: ts90k) == nil)
        #expect(Demuxer.foldedIndexTimestamp(Int64.min + 5, subtractSeconds: 1, timeBase: ts90k) == nil)
        #expect(Demuxer.foldedIndexTimestamp(900_000, subtractSeconds: 1.5, timeBase: ts90k) == 765_000)
        #expect(Demuxer.foldedIndexTimestamp(900_000, subtractSeconds: 0, timeBase: ts90k) == 900_000)
        #expect(Demuxer.offsetIndexTimestamp(Int64.max - 10, by: 20) == nil)
        #expect(Demuxer.offsetIndexTimestamp(1000, by: -3003) == -2003)
        #expect(Demuxer.offsetIndexTimestamp(1000, by: nil) == 1000)
    }

    // MARK: - Builders

    @Test("The trust check survives an index spanning both Int64 extremes")
    func trustCheckSpread() {
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [Int64.max - (1 << 49), Int64.min + 1],
            videoTimeBase: ts90k, sourceDurationSeconds: 7200) == false)
    }

    @Test("A segmented plan over a manifest sum past Int64 ticks is empty instead of trapping")
    func segmentedPlanHugeDuration() {
        let plan = HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: [0, 4, 8], videoTimeBase: ts90k,
            sourceDurationSeconds: 2e14, startPts0: 0)
        #expect(plan.isEmpty)
        let hugeStart = HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: [0, 4, 2e14], videoTimeBase: ts90k,
            sourceDurationSeconds: 2e14 + 4, startPts0: 0)
        #expect(hugeStart.isEmpty)
    }

    @Test("A uniform plan over a huge duration stays bounded")
    func uniformPlanBounded() {
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 1e12)
        #expect(plan.count <= HLSVideoEngine.maxPlanSegments)
        #expect(plan.last.map { $0.startSeconds + $0.durationSeconds } == 1e12)
        #expect(HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: .infinity).isEmpty)
    }

    @Test("A uniform plan whose ticks leave Int64 is empty instead of trapping")
    func uniformPlanTickOverflow() {
        #expect(HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 1e14).isEmpty)
    }

    @Test("A keyframe plan whose final end leaves Int64 at a fine time base is empty instead of trapping")
    func keyframePlanTickOverflow() {
        #expect(HLSVideoEngine.buildKeyframeSegmentPlan(
            keyframes: [0, 4_000_000_000, 8_000_000_000], videoTimeBase: nanos,
            sourceDurationSeconds: 1e10).isEmpty)
    }

    @Test("A week-long uniform plan at the target stride is unchanged by the cap")
    func weekLongPlanUnchanged() {
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 604_800)
        #expect(plan.count == 151_200)
        #expect(plan[1].startSeconds == 4)
        #expect(plan.last.map { $0.startSeconds + $0.durationSeconds } == 604_800)
    }
}
