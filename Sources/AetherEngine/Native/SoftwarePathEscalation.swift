import Foundation

/// The last rung under a native session AVPlayer will not play: hand the source to the engine's own
/// decoder instead of ending the session (AE#561).
///
/// Every recovery above this one reloads the SAME item against the SAME bytes: the #93 revive
/// reloads at the position that died, and the stage-2 chain refills the same segment. That is the
/// right answer to a transient, and no answer at all to a segment AVPlayer refuses on its merits,
/// which is what a damaged source produces. The reporter's capture shows the shape exactly: the
/// item dies with `-19602`, the reload lands on the same segment, and the replacement item dies on
/// it 62 ms later.
///
/// `SoftwarePlaybackHost` decodes with libavcodec, which answers a sample Apple's parser rejects by
/// skipping one frame, and it reads the demuxer directly rather than the loopback HLS the native
/// path is served over, so it also steps around a local-server wedge. One escalation per session,
/// because a second one could only repeat the first.
enum SoftwarePathEscalation {

    /// What the host hands the engine when it would otherwise surface a terminal failure.
    struct Request: Equatable, Sendable {
        /// The failure that prompted it, carried so the engine's log names the real cause.
        let domain: String
        let code: Int
        let message: String
        /// Where the session was, so the rebuild lands where the viewer was watching.
        let positionSeconds: Double
    }

    /// One session's single escalation, shared with the mount-time closure the host reads.
    ///
    /// A reference type because the host's probe is `@Sendable` and the latch it has to see lives on
    /// the engine. `take()` is what spends it, so two failures arriving together cannot both rebuild.
    final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var spent = false

        var isSpent: Bool {
            lock.lock(); defer { lock.unlock() }
            return spent
        }

        /// True when this call took the escalation, false when it was already gone.
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if spent { return false }
            spent = true
            return true
        }
    }

    /// What the session can still offer, answered by the engine because the host owns none of it.
    struct Availability: Equatable, Sendable {
        /// This session has spent its one escalation already.
        let alreadyEscalated: Bool
        /// The path the session is running on.
        let preferredDecodePath: DecodePath
        /// The remote-HLS bypass, where the engine decodes nothing at all.
        let nativeRemoteHLS: Bool
    }

    /// The domain of a media failure, i.e. AVFoundation could not make sense of what it was served.
    static let mediaErrorDomain = "CoreMediaErrorDomain"

    /// Whether a failed native item is worth handing to the engine's own decoder.
    ///
    /// The domain is the discriminator. A CoreMedia failure is a verdict on the MEDIA, which is the
    /// one thing a second decoder can disagree with. A URL-loading failure is a verdict on the
    /// SOURCE, which both paths read through the same reader, so escalating one would only spend a
    /// rebuild to fail the same way a few seconds later. Nil availability means no engine answered,
    /// which is never a reason to swallow a failure.
    static func shouldEscalate(errorDomain: String?, availability: Availability?) -> Bool {
        guard let availability, !availability.alreadyEscalated else { return false }
        // Already there, or the host asked for a path this cannot improve on.
        guard availability.preferredDecodePath == .automatic else { return false }
        // The bypass has no local muxer and decodes nothing here, so #461 ignores the option anyway.
        guard !availability.nativeRemoteHLS else { return false }
        return errorDomain == mediaErrorDomain
    }
}
