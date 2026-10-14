import Testing
import Foundation
@testable import AetherEngine

/// Audit SUB-101 / SUB-110: `cleanASSBody` stripped override blocks with `\{[^}]*\}`, which is
/// quadratic on a cue made of unclosed `{` (20k braces took 2.6 s, doubling costs 4x) and ran on the
/// pump thread under the subtitle tap lock. `edgeTrimmed` shifted the run array once per leading
/// blank run. Both are one pass now.
struct ASSOverrideBlockScanTests {

    /// The implementation `cleanASSBody` had before the forward scan, kept as the oracle.
    private func legacyCleanASSBody(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = s.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    private static let normalLines: [String] = [
        "plain text",
        "",
        "   ",
        "{\\an8}Top of the screen",
        "{\\an8}{\\b1}Top{\\b0}\\Nline two",
        "{\\pos(192,240)}Positioned{\\i1} italic{\\i0}",
        "{\\1c&H00FF00&}green{\\r} back",
        "{a}{b}{c}adjacent blocks",
        "{a}{b}",
        "{}empty block",
        "x{}y{}z",
        "{a{b}c}nested open brace",
        "{{a}b",
        "{a}{b",
        "a{b",
        "{",
        "}",
        "}{",
        "a}b{c}d",
        "{\\k20}ka{\\k25}ra{\\k30}o{\\k15}ke",
        "line one\\Nline two\\nline three\\hspaced",
        "{\\fnArial\\fs32\\b1}\\NLeading break",
        "trailing {\\i1}",
        "  {\\an2}  padded  ",
        "multi\nline {\\b1}text\r\nwith {\\i1}CRLF",
        "{multi\nline\nblock}after",
        "\u{00E9}\u{00E8} {\\i1}caf\u{00E9}{\\i0} \u{4E2D}\u{6587} \u{1F600} end",
        "{\u{4E2D}\u{6587}}\u{1F600}",
        "e\u{0301}{\\b1}x",
        "{\u{0301}}x",
        "{\\N}x",
        "\\N{\\N}\\N",
        "{\\b1}{\\i1}{\\u1}{\\s1}",
    ]

    @Test("the forward scan matches the old regex on ordinary lines")
    func matchesRegexOnOrdinaryLines() {
        for line in Self.normalLines {
            #expect(SubtitleRectText.cleanASSBody(line) == legacyCleanASSBody(line), "line: \(line.debugDescription)")
        }
    }

    @Test("the forward scan matches the old regex on generated lines full of braces")
    func matchesRegexOnGeneratedLines() {
        let alphabet: [String] = ["{", "}", "{", "}", "\\", "N", "n", "h", "a", "b", " ", "\n", "\u{00E9}",
                                  "\u{1F600}", "\u{0301}", "\\N", "{\\b1}", ","]
        var rng = SplitMix64(state: 0xA55_0C1E)
        for _ in 0..<6000 {
            let length = Int.random(in: 0...40, using: &rng)
            var line = ""
            for _ in 0..<length { line += alphabet.randomElement(using: &rng)! }
            #expect(SubtitleRectText.cleanASSBody(line) == legacyCleanASSBody(line), "line: \(line.debugDescription)")
        }
    }

    @Test("an ASS event line keeps its semantics through plainText(fromASSEventLine:)")
    func eventLineSemanticsHold() {
        #expect(SubtitleRectText.plainText(fromASSEventLine: "0,0,Default,,0,0,0,,{\\an8}Hello\\Nthere, friend")
                == "Hello\nthere, friend")
        #expect(SubtitleRectText.plainText(fromASSEventLine: "{a}b{c}") == "b")
        #expect(SubtitleRectText.plainText(fromASSEventLine: "{{a}b") == "b")
        #expect(SubtitleRectText.plainText(fromASSEventLine: "a{b") == "a{b")
        #expect(SubtitleRectText.plainText(fromASSEventLine: "{a}{b") == "{b")
    }

    @Test("a cue of unclosed braces cleans in linear time")
    func unclosedBracesAreLinear() {
        let hostile = String(repeating: "{", count: 50_000)
        let started = ContinuousClock.now
        let cleaned = SubtitleRectText.cleanASSBody(hostile)
        let elapsed = ContinuousClock.now - started
        #expect(cleaned == hostile)
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    @Test("a cue of unclosed braces with an unclosed tail is linear through the plain path too")
    func plainPathIsLinear() {
        let hostile = "0,0,Default,,0,0,0,," + String(repeating: "{a", count: 25_000)
        let started = ContinuousClock.now
        _ = SubtitleRectText.plainText(fromASSEventLine: hostile)
        _ = SubtitleRectText.styledRuns(fromASSEventLine: hostile)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("leading blank runs of alternating style trim away through the parser")
    func alternatingBlankRunsTrimAway() {
        var line = "0,0,Default,,0,0,0,,"
        for _ in 0..<5_000 { line += "{\\b1} {\\b0} " }
        line += "visible"
        #expect(line.utf8.count < SubtitleRectText.maxCueBytes)
        let parsed = SubtitleRectText.styledRuns(fromASSEventLine: line)
        #expect(parsed?.runs.map(\.text).joined() == "visible")
    }

    @Test("edgeTrimmed drops 100k leading blank runs in linear time")
    func edgeTrimmedIsLinear() {
        var runs: [SubtitleTextRun] = []
        for index in 0..<100_000 {
            runs.append(SubtitleTextRun(text: " ", color: nil, isBold: index % 2 == 0))
        }
        runs.append(SubtitleTextRun(text: "  visible  ", color: nil))
        let started = ContinuousClock.now
        let trimmed = SubtitleRectText.edgeTrimmed(runs)
        let elapsed = ContinuousClock.now - started
        #expect(trimmed?.map(\.text) == ["visible"])
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    @Test("edge trimming still drops leading blank runs and keeps the styled text after them")
    func edgeTrimKeepsStyledText() {
        let parsed = SubtitleRectText.styledRuns(fromASSEventLine: "0,0,Default,,0,0,0,,{\\b1} {\\b0}\\N{\\i1} {\\i0}  {\\b1}bold {\\i1}it  ")
        #expect(parsed?.runs.map(\.text) == ["bold ", "it"])
        #expect(parsed?.runs.first?.isBold == true)
        #expect(SubtitleRectText.styledRuns(fromASSEventLine: "0,0,Default,,0,0,0,,{\\b1} {\\b0}\\N ") == nil)
    }

    @Test("a cue past 64 KiB is cut before any per-cue pass")
    func oversizedCueIsCapped() {
        let big = String(repeating: "abcdefgh", count: 200_000)
        let cleaned = SubtitleRectText.cleanASSBody(big)
        #expect(cleaned?.utf8.count == 64 * 1024)
        let plain = SubtitleRectText.plainText(fromASSEventLine: "0,0,Default,,0,0,0,," + big)
        #expect((plain?.utf8.count ?? .max) <= 64 * 1024)
        let runs = SubtitleRectText.styledRuns(fromASSEventLine: "0,0,Default,,0,0,0,," + big)?.runs
        #expect((runs?.map(\.text.utf8.count).reduce(0, +) ?? .max) <= 64 * 1024)
    }

    @Test("the cap never splits a scalar")
    func capKeepsScalarsWhole() {
        let emoji = String(repeating: "\u{1F600}", count: 40_000)
        let cleaned = SubtitleRectText.cleanASSBody(emoji)
        #expect(cleaned != nil)
        #expect(cleaned?.unicodeScalars.contains("\u{FFFD}") == false)
        #expect((cleaned?.utf8.count ?? .max) <= 64 * 1024)
        #expect(cleaned?.unicodeScalars.allSatisfy { $0 == "\u{1F600}" } == true)
    }

    @Test("MovTextSampleBuilder shares the same scan")
    func movTextSanitizeMatches() {
        #expect(MovTextSampleBuilder.sanitize("{a}b{c}") == "b")
        #expect(MovTextSampleBuilder.sanitize("{{a}b") == "b")
        #expect(MovTextSampleBuilder.sanitize("a{b") == "a{b")
        #expect(MovTextSampleBuilder.sanitize("{a}{b") == "{b")
        let hostile = String(repeating: "{", count: 50_000)
        let started = ContinuousClock.now
        #expect(MovTextSampleBuilder.sanitize(hostile) == hostile)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
