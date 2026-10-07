import Testing
@testable import AetherEngine

/// Audit SUB-112 item 4: `aetherctl pktdump` (the public `PacketTimingProbe.run`) subtracted packet
/// timestamps from the probed file unchecked, so dts on opposite sides near 2^62 trapped the probe.
@Suite("Packet timing probe dts deltas")
struct PacketTimingDeltaTests {

    @Test("A delta no Int64 can hold is nil instead of a trap")
    func overflowingDelta() {
        #expect(PacketTimingProbe.dtsDelta(Int64.max - 1, after: -(1 << 62)) == nil)
        #expect(PacketTimingProbe.dtsDelta(-(1 << 62) - 10, after: Int64.max - 1) == nil)
    }

    @Test("Ordinary deltas are unchanged, backward ones included")
    func ordinaryDelta() {
        #expect(PacketTimingProbe.dtsDelta(4004, after: 3003) == 1001)
        #expect(PacketTimingProbe.dtsDelta(3003, after: 4004) == -1001)
    }
}
