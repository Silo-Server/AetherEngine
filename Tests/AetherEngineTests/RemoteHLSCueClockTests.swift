import Testing
import Foundation
@testable import AetherEngine

/// AE#616: on `nativeRemoteHLS`, a Jellyfin transcode restarted at the keyframe before a slot makes
/// AVPlayer's item time lead the picture. The injected #316 renditions are placed by media timestamp,
/// so a line presented at item time T whose cue starts at S measures the lead T - S. Values are the
/// reporter's measurements (seg 494: slot 1483.482, keyframe 1482.272, lead 1.209).
struct RemoteHLSCueClockTests {

    private func clock(_ cues: [(Double, String)]) -> RemoteHLSCueClock {
        var clock = RemoteHLSCueClock()
        clock.setCues(cues.map { (start: $0.0, text: $0.1) })
        clock.noteTimeJump()
        // The landing delivery after the jump teaches nothing by design.
        _ = clock.observe(strings: [], itemTime: 0)
        return clock
    }

    @Test("A presented line measures item time minus its cue start")
    func measuresLead() throws {
        var c = clock([(1490.0, "Where were you?"), (1493.5, "Out.")])
        let measured = c.observe(strings: ["Where were you?"], itemTime: 1491.209)
        let lead = try #require(measured)
        #expect(abs(lead - 1.209) < 1e-9)
        #expect(c.offset == lead)
    }

    @Test("Each new line re-measures, so a seek that moved the anchor is corrected on the next line")
    func remeasuresAfterSeek() throws {
        var c = clock([(1490.0, "Where were you?"), (1800.0, "Run.")])
        _ = c.observe(strings: ["Where were you?"], itemTime: 1491.209)
        c.noteTimeJump()
        _ = c.observe(strings: [], itemTime: 1790.0)
        let measured = c.observe(strings: ["Run."], itemTime: 1803.086)
        let lead = try #require(measured)
        #expect(abs(lead - 3.086) < 1e-9)
    }

    @Test("The delivery at a seek landing is skipped: a line active there is stamped with the landing, not its start")
    func skipsLandingDelivery() {
        var c = RemoteHLSCueClock()
        c.setCues([(start: 100.0, text: "Long line")])
        c.noteTimeJump()
        let measured = c.observe(strings: ["Long line"], itemTime: 103.5)
        #expect(measured == nil)
        #expect(c.offset == nil)
    }

    @Test("A line ending measures nothing; the survivor was stamped when it appeared")
    func endingLineMeasuresNothing() {
        var c = clock([(10.0, "A"), (11.0, "B")])
        _ = c.observe(strings: ["A"], itemTime: 12.0)
        _ = c.observe(strings: ["A", "B"], itemTime: 13.0)
        let measured = c.observe(strings: ["B"], itemTime: 14.0)
        #expect(measured == nil)
        #expect(c.offset == 2.0)
    }

    @Test("Repeated text resolves to the start nearest the current lead")
    func repeatedTextPicksNearestToCurrentLead() throws {
        var c = clock([(20.0, "First"), (100.0, "Yeah."), (104.0, "Yeah.")])
        _ = c.observe(strings: ["First"], itemTime: 23.0)   // lead 3
        _ = c.observe(strings: [], itemTime: 24.0)
        // Candidates 107 - 100 = 7 and 107 - 104 = 3; the current lead is 3.
        let measured = c.observe(strings: ["Yeah."], itemTime: 107.0)
        let lead = try #require(measured)
        #expect(lead == 3.0)
    }

    @Test("A text with one plausible start wins over an ambiguous sibling in the same delivery")
    func uniqueCandidateWins() throws {
        var c = clock([(50.0, "Yeah."), (56.5, "Yeah."), (52.0, "Only once")])
        let measured = c.observe(strings: ["Yeah.", "Only once"], itemTime: 57.5)
        let lead = try #require(measured)
        #expect(lead == 5.5)
    }

    @Test("A match outside the plausible band is a different line, not a measurement")
    func implausibleMatchIgnored() {
        var c = clock([(10.0, "Hello")])
        let measured = c.observe(strings: ["Hello"], itemTime: 500.0)
        #expect(measured == nil)
        #expect(c.offset == nil)
    }

    @Test("Text AVPlayer hands back matches the sanitized cue the .vtt carried")
    func normalizationMatchesServedText() throws {
        var c = clock([(30.0, "{\\an8}Line one\\Nline  two")])
        let measured = c.observe(strings: ["<i>Line one</i>\nline two"], itemTime: 31.25)
        let lead = try #require(measured)
        #expect(lead == 1.25)
    }

    @Test("Unknown text measures nothing")
    func unknownText() {
        var c = clock([(30.0, "Known")])
        let measured = c.observe(strings: ["Origin's own rendition"], itemTime: 31.0)
        #expect(measured == nil)
    }

    @Test("A time jump marks the kept offset as unmeasured until the next matched line")
    func timeJumpClearsMeasuredUntilNextLine() {
        var c = clock([(1490.0, "Where were you?"), (1800.0, "Run.")])
        #expect(!c.isMeasuredSinceJump)
        _ = c.observe(strings: ["Where were you?"], itemTime: 1491.209)
        #expect(c.isMeasuredSinceJump)
        c.noteTimeJump()
        #expect(!c.isMeasuredSinceJump)
        #expect(c.offset.map { abs($0 - 1.209) < 1e-9 } == true)
        _ = c.observe(strings: [], itemTime: 1790.0)
        #expect(!c.isMeasuredSinceJump)
        _ = c.observe(strings: ["Run."], itemTime: 1803.086)
        #expect(c.isMeasuredSinceJump)
    }

    // MARK: - Markup stripping

    /// The `normalize` that removed one tag at a time, searching again from the start, kept as the oracle.
    private func legacyNormalize(_ text: String) -> String {
        var s = MovTextSampleBuilder.sanitize(text)
        while let open = s.firstIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
            s.removeSubrange(open...close)
        }
        s = s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        return s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let trickyLines: [String] = [
        "",
        "plain",
        "<i>Line one</i>\nline two",
        "<>x",
        "<><>",
        "a<>b<>c",
        "<a<b>c>",
        "<<a>>",
        "a<b",
        "a>b",
        "><",
        "a<b>c<d",
        "<b>x<",
        "<",
        ">",
        "<i>open only",
        "close only</i>",
        "<c.yellow><i>nested</i></c>",
        "&lt;i&gt;escaped&lt;/i&gt;",
        "&lt;<b>&gt;",
        "&amp;lt;",
        "&<i>lt;</i>",
        "a&nbsp;&nbsp;b",
        "&nbsp<b>;</b>",
        "<v Roger>Hi &amp; bye",
        "{\\an8}<i>top</i>\\Nnext",
        "{<b>}x",
        "<{b}>x",
        "<\u{0301}b>x",
        "<b\u{0600}>x>",
        "\u{0600}<b>x",
        "e\u{0301}<b>\u{0301}x",
        "x<b>\u{0301}y>",
        "\u{1F1FA}<b>\u{1F1F8}\u{1F1EC}<i>\u{1F1E7}",
        "\u{1F468}\u{200D}<b>\u{1F469}",
        "\u{1100}<b>\u{1161}",
        "\r<b>\nx",
        "\u{226E}b>x",
        "a<b>\u{00A0}<i>c",
        "  <b> spaced </b>  ",
    ]

    @Test("The forward strip matches the old tag-at-a-time strip on tricky lines")
    func stripMatchesLegacyOnTrickyLines() {
        for line in Self.trickyLines {
            let got = RemoteHLSCueClock.normalize(line)
            let want = legacyNormalize(line)
            #expect(got == want, "line: \(line.debugDescription)")
            #expect(Array(got.unicodeScalars) == Array(want.unicodeScalars), "line: \(line.debugDescription)")
        }
    }

    @Test("The forward strip matches the old tag-at-a-time strip on generated lines full of markup")
    func stripMatchesLegacyOnGeneratedLines() {
        let alphabet: [String] = ["<", ">", "<", ">", "<i>", "</i>", "<>", "&lt;", "&gt;", "&amp;", "&nbsp;",
                                  "&", "lt;", "a", " ", "\n", "\r", "{", "}", "\\N", "\u{0301}", "\u{0600}",
                                  "\u{200D}", "\u{1F468}", "\u{1F1FA}", "\u{1F1F8}", "\u{1100}", "\u{1161}",
                                  "\u{226E}", "\u{00E9}"]
        var rng = SplitMix64(state: 0x0616_C0E5)
        for _ in 0..<6000 {
            let length = Int.random(in: 0...30, using: &rng)
            var line = ""
            for _ in 0..<length { line += alphabet.randomElement(using: &rng)! }
            let got = RemoteHLSCueClock.normalize(line)
            let want = legacyNormalize(line)
            #expect(got == want && Array(got.unicodeScalars) == Array(want.unicodeScalars),
                    "line: \(line.debugDescription)")
        }
    }

    @Test("A 64 KiB cue made of tags normalizes in linear time")
    func tagHeavyCueIsLinear() {
        let hostile = String(repeating: "<i>a</i>", count: 8 * 1024)
        #expect(hostile.utf8.count == 64 * 1024)
        // The fastest of a few runs, so one preemption on a loaded machine is not read as the cost.
        // About 50 ms in a debug build here against 1.1 s for the rescanning strip; the bound leaves a
        // loaded CI runner room without letting a quadratic strip back in.
        var fastest = Duration.seconds(3600)
        for _ in 0..<3 where fastest >= .milliseconds(400) {
            let started = ContinuousClock.now
            let normalized = RemoteHLSCueClock.normalize(hostile)
            fastest = min(fastest, ContinuousClock.now - started)
            #expect(normalized == String(repeating: "a", count: 8 * 1024))
        }
        #expect(fastest < .milliseconds(400), "took \(fastest)")
    }
}
