import Foundation
import Testing
@testable import AetherEngine

/// On the `nativeRemoteHLS` bypass the sampler never ran, because its bitrate halves read the loopback's
/// demuxer counter, and so `liveTelemetry` stayed nil for the whole session. AVPlayer's own access log is
/// there on this route too; these pin how it fills the same two bitrate fields.
///
/// The fields name the stream's bitrate, so on the bypass they come from what the variant declares, not
/// from what AVPlayer transferred: a player filling its buffer after a start or a seek pulls at link
/// speed, and a transfer-based figure read 22.6 Mbps for a 3.7 Mbps Jellyfin transcode (device, 2026-09-28).
/// The transfer stays in the network fields, where it belongs.
@Suite("RemoteHLSTelemetry")
struct RemoteHLSTelemetryTests {

    @Test("the bypass reads the variant's declared bitrate, every other route the demuxer")
    func counterPerRoute() {
        #expect(LiveTelemetrySampler.bitrateCounter(for: .remoteBypass) == .declaredVariant)
        #expect(LiveTelemetrySampler.bitrateCounter(for: .loopback) == .demuxer)
        #expect(LiveTelemetrySampler.bitrateCounter(for: .software) == .demuxer)
        #expect(LiveTelemetrySampler.bitrateCounter(for: .none) == .demuxer)
    }

    @Test("the loopback-only readings stay nil on the bypass")
    func loopbackOnlyReadings() {
        #expect(LiveTelemetrySampler.readsLoopbackPipeline(.remoteBypass) == false)
        #expect(LiveTelemetrySampler.readsLoopbackPipeline(.loopback))
    }

    @Test("instant is BANDWIDTH, average is AVERAGE-BANDWIDTH")
    func bothDeclared() {
        let rates = LiveTelemetrySampler.declaredBitrates(indicated: 4_000_000, indicatedAverage: 3_700_000)
        #expect(rates.instant == 4.0)
        #expect(rates.average == 3.7)
    }

    /// AVERAGE-BANDWIDTH is optional in a master; without it the peak is the only declaration there is.
    @Test("a master without AVERAGE-BANDWIDTH reports the peak for both")
    func averageFallsBackToPeak() {
        let rates = LiveTelemetrySampler.declaredBitrates(indicated: 4_000_000, indicatedAverage: 0)
        #expect(rates.instant == 4.0)
        #expect(rates.average == 4.0)
    }

    /// The access log reports an unknown bitrate as a negative number or zero.
    @Test("nothing declared is nil, not a measured zero")
    func nothingDeclared() {
        let rates = LiveTelemetrySampler.declaredBitrates(indicated: -1, indicatedAverage: -1)
        #expect(rates.instant == nil)
        #expect(rates.average == nil)
        #expect(LiveTelemetrySampler.declaredBitrates(indicated: .nan, indicatedAverage: .infinity).instant == nil)
    }
}
