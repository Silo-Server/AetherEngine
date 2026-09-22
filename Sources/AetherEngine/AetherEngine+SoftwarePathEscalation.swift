import Foundation

/// AE#561: the rung under every native recovery, taken when AVPlayer refuses the media itself.
///
/// The recoveries above this one all answer the same bytes again: the #93 revive reloads the item at
/// the position that died, and the stage-2 chain refills the same segment. Against a transient that
/// is exactly right. Against a segment Apple's parser refuses on its merits it is a loop, and the
/// reporter's capture shows it ending the session with the replacement item dying 62 ms after the
/// first. `SoftwarePlaybackHost` decodes with libavcodec, which skips such a frame and plays on, and
/// it reads the demuxer directly rather than the loopback HLS, so it steps around a local-server
/// wedge too.
///
/// The rebuild is `reloadAtCurrentPosition(applying:)`, which keeps the session: same playhead, same
/// subtitle carryover, same external-track registry. Its own `decodePathRefusal` is what decides
/// whether the software path can serve this source at all, so a source it cannot serve costs a
/// refusal here rather than a second dead session.
extension AetherEngine {

    /// Rebuild this session on the software path, once, because the native one refused the media.
    @MainActor
    func escalateToSoftwarePath(_ request: SoftwarePathEscalation.Request) async {
        guard SoftwarePathEscalation.shouldEscalate(
            errorDomain: request.domain,
            availability: SoftwarePathEscalation.Availability(
                alreadyEscalated: softwarePathEscalationBudget.isSpent,
                preferredDecodePath: loadedOptions.preferredDecodePath,
                nativeRemoteHLS: loadedOptions.nativeRemoteHLS
            )
        ) else { return }
        // The host's probe read mount-time options and the #93 rung does not consult it at all, so
        // the decision is made again here, against what the session is actually running on.
        guard softwarePathEscalationBudget.take() else { return }

        EngineLog.emit(
            "[AetherEngine] #561 AVPlayer refused the media (\(request.domain)/\(request.code)) at "
            + "\(String(format: "%.2f", request.positionSeconds))s; rebuilding this session on the "
            + "software path, which decodes it with libavcodec instead: \(request.message)",
            category: .engine
        )

        do {
            try await reloadAtCurrentPosition { $0.preferredDecodePath = .software }
            EngineLog.emit(
                "[AetherEngine] #561 rebuilt on the software path", category: .engine)
        } catch {
            // The rung is gone and the failure was never surfaced, so it has to be surfaced here or
            // the session would sit on a picture that stopped with nothing said.
            EngineLog.emit(
                "[AetherEngine] #561 the software path cannot serve this session (\(error)); "
                + "surfacing the original failure",
                category: .engine
            )
            publishError(
                PlaybackErrorInfo(
                    kind: .nativeItemFailed,
                    message: request.message,
                    underlyingDomain: request.domain.isEmpty ? nil : request.domain,
                    underlyingCode: request.code == 0 ? nil : request.code
                )
            )
        }
    }
}
