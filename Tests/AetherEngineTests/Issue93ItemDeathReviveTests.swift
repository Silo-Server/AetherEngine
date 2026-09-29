import Testing
import Foundation
@testable import AetherEngine

/// #93 round 3: accumulated -12889 media timeouts kill the AVPlayerItem
/// (failedToPlayToEndTime, rate 0, tcs .paused). Every recovery layer then
/// misreads the dead item as a user pause and disarms, making the session
/// terminal. These tests cover the pure decisions of the escalation path:
/// counting the death on the loopback path, bypassing the pause guard for
/// this one trigger, and bounding the reload storm.
struct Issue93ItemDeathReviveTests {

    // MARK: - ItemDeathReviveGate

    @Test("admits reloads up to the cap at a frozen position")
    func admitsWithinCap() {
        var gate = ItemDeathReviveGate(maxAttempts: 3)
        let admitted = (0..<3).map { _ in gate.admit(position: 354.8) }
        #expect(admitted == [true, true, true])
    }

    @Test("exhausts after the cap when the position never advances")
    func exhaustsAtCap() {
        var gate = ItemDeathReviveGate(maxAttempts: 3)
        _ = gate.admit(position: 354.8)
        _ = gate.admit(position: 354.8)
        _ = gate.admit(position: 354.8)
        let fourth = gate.admit(position: 354.8)
        let wiggle = gate.admit(position: 354.9)   // sub-epsilon wiggle is not progress
        #expect(!fourth)
        #expect(!wiggle)
    }

    @Test("playback progress since the last death resets the budget")
    func progressResets() {
        var gate = ItemDeathReviveGate(maxAttempts: 2)
        _ = gate.admit(position: 100.0)
        _ = gate.admit(position: 100.0)
        let exhausted = gate.admit(position: 100.0)
        // The reload finally lands and plays for a while before dying again:
        // a fresh episode, full budget.
        let freshEpisode = gate.admit(position: 130.0)
        #expect(!exhausted)
        #expect(freshEpisode)
    }

    @Test("a user seek to a different position is a fresh episode too")
    func seekAwayResets() {
        var gate = ItemDeathReviveGate(maxAttempts: 2)
        _ = gate.admit(position: 500.0)
        _ = gate.admit(position: 500.0)
        let exhausted = gate.admit(position: 500.0)
        // Backward jump (user scrubbed away from the dead window).
        let scrubbedAway = gate.admit(position: 320.0)
        #expect(!exhausted)
        #expect(scrubbedAway)
    }

    // MARK: - Pause-guard bypass

    @Test("recovery guard keeps refusing a genuinely paused consumer")
    func guardRefusesPausedConsumer() {
        #expect(!AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: true, allowPausedConsumer: false))
    }

    @Test("item-death trigger may recover a consumer that LOOKS paused")
    func guardAllowsItemDeathTrigger() {
        // failedToPlayToEndTime parks tcs at .paused; that pause is the
        // failure itself, not user intent.
        #expect(AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: true, allowPausedConsumer: true))
    }

    @Test("a playing consumer is always recoverable")
    func guardAllowsPlayingConsumer() {
        #expect(AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: false, allowPausedConsumer: false))
    }

    // MARK: - Viewer pause before the death

    private static let second: UInt64 = 1_000_000_000

    @Test("an item that died under a viewer's pause is reloaded paused")
    func deathUnderViewerPause() {
        // The field report: paused on an Apple TV, the item died minutes later and the reload
        // started playback with nobody touching the remote.
        #expect(NativeAVPlayerHost.transportPausedBeforeFailure(
            pausedSinceUptime: 10 * Self.second, failureUptime: 460 * Self.second))
    }

    @Test("an item that died while rolling is reloaded playing")
    func deathWhileRolling() {
        #expect(!NativeAVPlayerHost.transportPausedBeforeFailure(
            pausedSinceUptime: nil, failureUptime: 460 * Self.second))
    }

    @Test("the dead item's own pause, landing just before the notification, is not the viewer's")
    func deathParksItsOwnPause() {
        #expect(!NativeAVPlayerHost.transportPausedBeforeFailure(
            pausedSinceUptime: 460 * Self.second - Self.second / 20,
            failureUptime: 460 * Self.second))
    }

    @Test("a pause stamped after the notification is not the viewer's")
    func pauseAfterNotification() {
        #expect(!NativeAVPlayerHost.transportPausedBeforeFailure(
            pausedSinceUptime: 461 * Self.second, failureUptime: 460 * Self.second))
    }

    @Test("with no press since the death, the transport it died in decides")
    func reloadFollowsTransportAtDeath() {
        #expect(!NativeAVPlayerHost.itemDeathReloadResumesPlaying(
            diedUnderPause: true, commandSinceFailure: nil, transportRolling: false))
        #expect(NativeAVPlayerHost.itemDeathReloadResumesPlaying(
            diedUnderPause: false, commandSinceFailure: nil, transportRolling: false))
    }

    @Test("a Play or Pause pressed while the death is confirmed outranks the transport it died in")
    func pressDuringConfirmationDecides() {
        #expect(NativeAVPlayerHost.itemDeathReloadResumesPlaying(
            diedUnderPause: true, commandSinceFailure: true, transportRolling: false))
        #expect(!NativeAVPlayerHost.itemDeathReloadResumesPlaying(
            diedUnderPause: false, commandSinceFailure: false, transportRolling: true))
    }

    @Test("a Play from outside the engine after a paused death resumes the reload")
    func externalPlayAfterPausedDeath() {
        #expect(NativeAVPlayerHost.itemDeathReloadResumesPlaying(
            diedUnderPause: true, commandSinceFailure: nil, transportRolling: true))
    }

    // MARK: - Host-side counting decision

    @Test("loopback path counts an end failure after playback was established")
    func countsLoopbackDeath() {
        #expect(NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: false, hasEverPlayed: true))
    }

    @Test("lean remote-live path keeps its own deferred-failure contract")
    func leanLivePathDoesNotDoubleHandle() {
        #expect(!NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: true, hasEverPlayed: true))
    }

    @Test("startup death before the first frame stays with the startup watchdogs")
    func startupDeathNotCounted() {
        #expect(!NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: false, hasEverPlayed: false))
    }
}
