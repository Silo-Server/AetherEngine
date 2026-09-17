import CoreGraphics
import Foundation

extension AetherEngine {
    /// The fullscreen host consumes raw primary ASS events. Software PiP still
    /// uses the engine's text compositor, with the same runs and placement that
    /// the decoder produces when markup preservation is disabled.
    func softwarePiPSubtitleCues(primary: [SubtitleCue], secondary: [SubtitleCue]) -> [SubtitleCue] {
        guard pictureInPictureActive, loadedOptions.preserveASSMarkup,
              let track = subtitleTracks.first(where: { $0.id == activeSubtitleTrackIndex }),
              ["ass", "ssa"].contains(track.codec.lowercased()) else {
            return primary + secondary
        }
        let header = track.isExternal ? sidecarASSHeader : track.assHeader
        let playRes = header.flatMap(SubtitleRectText.playRes(fromASSHeader:))
            ?? SubtitleRectText.defaultASSPlayRes
        return SubtitleRectText.normalizedASSCues(primary, playRes: playRes, isExternal: track.isExternal) + secondary
    }
}

extension SubtitleRectText {
    /// Raw cues can contain several rects joined by newlines. Reconstruct the
    /// decoder's body grouping and order: embedded rich bodies precede the
    /// merged plain body; sidecars place that plain body first. These private
    /// compositor cues retain their source ID for its active-cue cache.
    static func normalizedASSCues(_ cues: [SubtitleCue], playRes: CGSize, isExternal: Bool) -> [SubtitleCue] {
        cues.flatMap { cue -> [SubtitleCue] in
            guard case .text(let raw) = cue.body else { return [cue] }
            var lines: [String] = []
            var bodies: [SubtitleCue.Body] = []
            var placement = cue.placement
            for line in raw.split(separator: "\n") {
                if let parsed = styledBody(fromASSEventLine: String(line), playRes: playRes) {
                    placement = placement ?? parsed.placement
                    if case .text(let text) = parsed.body {
                        lines.append(text)
                    } else {
                        bodies.append(parsed.body)
                    }
                } else if let text = plainText(fromASSEventLine: String(line)) {
                    lines.append(text)
                }
            }
            let plain = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                if isExternal { bodies.insert(.text(plain), at: 0) }
                else { bodies.append(.text(plain)) }
            }
            return bodies.map { body in
                SubtitleCue(id: cue.id, startTime: cue.startTime, endTime: cue.endTime,
                            body: body, placement: placement)
            }
        }
    }
}
