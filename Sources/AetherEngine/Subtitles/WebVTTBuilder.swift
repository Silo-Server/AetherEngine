import Foundation

/// Builds a WebVTT body from decoded cue tuples on the AVPlayer timeline (#15). Text is sanitized
/// (ASS markup stripped) via MovTextSampleBuilder. Plain cues only; no positioning/styling. Served as a
/// separate HLS SUBTITLES rendition so AVKit renders subtitles in the PiP window (the on-frame overlay is not
/// in the PiP layer); muxing timed text into the A/V fMP4 is non-conformant for HLS (see #55).
enum WebVTTBuilder {
    /// `WEBVTT` header followed by one cue block per non-empty cue: `HH:MM:SS.mmm --> HH:MM:SS.mmm` + text.
    ///
    /// `timestampAnchorSeconds` is where cue time 0 sits on the origin's media timestamps (the remote-HLS
    /// proxy's whole-program renditions, #316). Without it the header carries no `X-TIMESTAMP-MAP`, and
    /// RFC 8216 then pins cue time 0 to timestamp 0. Cue times are written unchanged either way.
    static func body(cues: [(start: Double, end: Double, text: String)],
                     timestampAnchorSeconds: Double? = nil) -> String {
        var out = "WEBVTT\n"
        if let anchor = timestampAnchorSeconds {
            out += timestampMap(anchorSeconds: anchor) + "\n"
        }
        out += "\n"
        for cue in cues {
            let text = MovTextSampleBuilder.sanitize(cue.text)
            if text.isEmpty { continue }
            out += "\(timestamp(cue.start)) --> \(timestamp(max(cue.start, cue.end)))\n\(text)\n\n"
        }
        return out
    }

    /// WebVTT *segment* body for an HLS SUBTITLES rendition (#15). Same cue formatting as `body(cues:)`
    /// plus the segment header AVPlayer needs to anchor cue times to the fMP4 media timeline.
    ///
    /// We emit an IDENTITY timestamp map (`X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000`) and write cues
    /// with ABSOLUTE media-timeline times (the values `cuesInWindow` returns are already on the
    /// AVPlayer/output timeline). This absolute + identity-map choice is the ONE thing to verify on-device:
    /// if PiP subtitles appear shifted by the segment's start offset, flip `relativeToStart` to true at the
    /// single provider call site (`VideoSegmentProvider.nativeSubtitleVTT(ordinal:segmentIndex:)`); that
    /// rebases every cue to LOCAL time relative to `segmentStart` while keeping MPEGTS:0.
    static func segment(cues: [(start: Double, end: Double, text: String)],
                        segmentStart: Double = 0,
                        relativeToStart: Bool = false) -> String {
        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        let offset = relativeToStart ? segmentStart : 0
        for cue in cues {
            let text = MovTextSampleBuilder.sanitize(cue.text)
            if text.isEmpty { continue }
            let s = max(0, cue.start - offset)
            let e = max(s, cue.end - offset)
            out += "\(timestamp(s)) --> \(timestamp(e))\n\(text)\n\n"
        }
        return out
    }

    /// `X-TIMESTAMP-MAP` placing cue time 0 at `anchorSeconds` of the origin's media timestamps. A positive
    /// anchor is the MPEG-2 value itself, wrapped to its 33 bits. A negative one would need a value below
    /// zero, so it moves to the cue side instead (cue time |anchor| at timestamp 0), which says the same
    /// thing without leaning on the player's rollover handling.
    static func timestampMap(anchorSeconds: Double) -> String {
        guard anchorSeconds >= 0 else {
            return "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:\(timestamp(-anchorSeconds))"
        }
        let ticks = Int64((anchorSeconds * 90_000).rounded()) & ((Int64(1) << 33) - 1)
        return "X-TIMESTAMP-MAP=MPEGTS:\(ticks),LOCAL:00:00:00.000"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        let ms = min(999, Int((total - Double(whole)) * 1000.0 + 0.5))
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
