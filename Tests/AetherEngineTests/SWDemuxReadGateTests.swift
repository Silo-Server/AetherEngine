import Testing
@testable import AetherEngine

/// `SoftwarePlaybackHost.shouldHoldDemuxRead`: when the combined SW demux loop stops pulling
/// packets so the renderer can drain the parked video FIFO. The lead is the pacing rule and the
/// packet cap is only a memory backstop - pacing on the cap alone makes the effective audio lead
/// a function of frame rate (256 packets is ~10 s at 25 fps and ~5 s at 50 fps).
@Suite("SW demux read gate")
struct SWDemuxReadGateTests {

    private let cap = 256

    @Test("audio at its target lead holds the read")
    func holdsAtTargetLead() {
        let clock = 100.0
        let atTarget = clock + AudioLookaheadPolicy.targetLeadSeconds
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: atTarget, clockSeconds: clock) == true)
    }

    @Test("audio below its target lead keeps reading, however deep the FIFO is under the cap")
    func readsBelowTargetLead() {
        let clock = 100.0
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 200, parkedCap: cap, clockArmed: true,
            lastAudioPts: clock + 1.0, clockSeconds: clock) == false)
    }

    @Test("the packet cap holds the read on its own")
    func capIsTheBackstop() {
        let clock = 100.0
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: cap, parkedCap: cap, clockArmed: true,
            lastAudioPts: clock + 0.1, clockSeconds: clock) == true)
    }

    /// #337: before the clock is armed the lead is meaningless and the loop is the only reader.
    /// Holding here parks forever - the clock waits for an audio buffer that only a further read
    /// can produce. Only the cap may hold, and the parked-video arming exit runs at that point.
    @Test("an unarmed clock never holds on the lead, only on the cap")
    func unarmedClockKeepsReading() {
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 10, parkedCap: cap, clockArmed: false,
            lastAudioPts: 1_000, clockSeconds: 0) == false)
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: cap, parkedCap: cap, clockArmed: false,
            lastAudioPts: 1_000, clockSeconds: 0) == true)
    }

    @Test("no audio enqueued yet and an unreadable clock both keep reading")
    func nonFiniteInputsKeepReading() {
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: .nan, clockSeconds: 100) == false)
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: 104, clockSeconds: .nan) == false)
    }

    // MARK: - Parked wait (audit PERF-110)

    @Test("a lead just over the target wakes when the gate opens, not before the floor")
    func waitFollowsTheGateOpening() {
        let clock = 100.0
        let target = AudioLookaheadPolicy.targetLeadSeconds
        #expect(abs(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: clock + target + 0.012, clockSeconds: clock, rate: 1) - 0.012) < 1e-9)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: clock + target + 0.001, clockSeconds: clock, rate: 1) == 0.005)
    }

    @Test("a lead far over the target is capped at 20 ms so parked video keeps reaching the decoder")
    func waitIsCapped() {
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 110, clockSeconds: 100, rate: 1) == 0.020)
    }

    @Test("a gate that is already open, an unarmed clock and unreadable inputs poll at the 5 ms floor")
    func waitFloor() {
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 101, clockSeconds: 100, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: false, lastAudioPts: 110, clockSeconds: 100, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: .nan, clockSeconds: 100, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 110, clockSeconds: .nan, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: .infinity, clockSeconds: 100, rate: 1) == 0.005)
    }

    @Test("a stopped clock under a paused picture waits like the paused loops instead of polling")
    func stoppedClockWaitsHalfASecond() {
        // The lead cannot shrink at rate 0, so only play, stop or a seek (each broadcasts) opens the gate.
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 110, clockSeconds: 100, rate: 0) == 0.5)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: .nan, clockSeconds: 100, rate: 0) == 0.5)
        // Unarmed, the loop still has to reach the parked-video arming exit at the floor.
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: false, lastAudioPts: 110, clockSeconds: 100, rate: 0) == 0.005)
    }

    @Test("the rate shortens the wait the same way it shortens the time to the gate")
    func waitScalesWithRate() {
        let target = AudioLookaheadPolicy.targetLeadSeconds
        let excess = 0.016
        #expect(abs(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 100 + target + excess, clockSeconds: 100, rate: 2) - 0.008) < 1e-9)
    }

    @Test("whatever the inputs, the wait stays between 5 and 20 ms")
    func waitIsAlwaysBounded() {
        for lead in stride(from: -2.0, through: 12.0, by: 0.37) {
            for rate: Float in [0.25, 0.5, 1, 1.5, 2, 4, 8] {
                let w = SoftwarePlaybackHost.parkedRendererWaitSeconds(
                    clockArmed: true, lastAudioPts: 100 + lead, clockSeconds: 100, rate: rate)
                #expect(w >= 0.005 && w <= 0.020)
            }
        }
    }
}
