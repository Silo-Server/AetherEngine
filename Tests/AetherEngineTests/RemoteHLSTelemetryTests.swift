import Foundation
import Testing
@testable import AetherEngine

/// On the `nativeRemoteHLS` bypass the sampler never ran, because its bitrate halves read the loopback's
/// demuxer counter, and so `liveTelemetry` stayed nil for the whole session. AVPlayer's own access log is
/// there on this route too; these pin how its session byte total becomes the same two bitrate fields.
@Suite("RemoteHLSTelemetry")
struct RemoteHLSTelemetryTests {

    @Test("the bypass meters AVPlayer's transfer, every other route the demuxer")
    func counterPerRoute() {
        #expect(LiveTelemetrySampler.bitrateCounter(for: .remoteBypass) == .consumerTransfer)
        #expect(LiveTelemetrySampler.bitrateCounter(for: .loopback) == .demuxer)
        #expect(LiveTelemetrySampler.bitrateCounter(for: .software) == .demuxer)
        #expect(LiveTelemetrySampler.bitrateCounter(for: .none) == .demuxer)
    }

    @Test("the loopback-only readings stay nil on the bypass")
    func loopbackOnlyReadings() {
        #expect(LiveTelemetrySampler.readsLoopbackPipeline(.remoteBypass) == false)
        #expect(LiveTelemetrySampler.readsLoopbackPipeline(.loopback))
    }

    @Test("instant is the ten-second window of per-tick deltas, like the demuxer meter")
    func instantOverWindow() {
        var meter = TransferRateMeter()
        meter.record(sessionBytes: 0)
        #expect(meter.instantMbps == nil)   // one sample spans no time
        meter.record(sessionBytes: 1_250_000)
        meter.record(sessionBytes: 2_500_000)
        // 2.5 MB over three one-second samples.
        let expected: Double = 2_500_000.0 * 8.0 / 3.0 / 1_000_000.0
        #expect(abs((meter.instantMbps ?? 0) - expected) < 0.0001)
    }

    @Test("the window forgets what is older than ten ticks")
    func windowRolls() {
        var meter = TransferRateMeter()
        meter.record(sessionBytes: 50_000_000)   // startup burst
        for i in 1...10 { meter.record(sessionBytes: 50_000_000 + Int64(i) * 125_000) }
        #expect(abs((meter.instantMbps ?? 0) - 1.0) < 0.0001)
    }

    @Test("a tick with no access log yet adds nothing and keeps the last total")
    func missingReadingIsNoDelta() {
        var meter = TransferRateMeter()
        meter.record(sessionBytes: 1_000_000)
        meter.record(sessionBytes: nil)
        meter.record(sessionBytes: 1_000_000)
        #expect(meter.lifetimeBytes == 1_000_000)
        meter.record(sessionBytes: 2_000_000)
        #expect(meter.lifetimeBytes == 2_000_000)
    }

    /// The folded total never falls (AE#443), but a counter that did must not make the next rise count twice.
    @Test("a total that falls back is not counted again when it recovers")
    func fallingTotalIsNotRecounted() {
        var meter = TransferRateMeter()
        meter.record(sessionBytes: 3_000_000)
        meter.record(sessionBytes: 1_000_000)
        meter.record(sessionBytes: 3_000_000)
        #expect(meter.lifetimeBytes == 3_000_000)
        #expect(meter.windowBytes == 3_000_000)
    }

    @Test("the average is the lifetime transfer over the active seconds, nil until both exist")
    func average() {
        var meter = TransferRateMeter()
        #expect(meter.averageMbps(activeSeconds: 10) == nil)
        meter.record(sessionBytes: 2_500_000)
        #expect(meter.averageMbps(activeSeconds: 0) == nil)
        #expect(abs((meter.averageMbps(activeSeconds: 10) ?? 0) - 2.0) < 0.0001)
    }

    @Test("reset starts a new session from zero")
    func reset() {
        var meter = TransferRateMeter()
        meter.record(sessionBytes: 5_000_000)
        meter.record(sessionBytes: 6_000_000)
        meter.reset()
        #expect(meter.lifetimeBytes == 0)
        #expect(meter.instantMbps == nil)
    }
}
