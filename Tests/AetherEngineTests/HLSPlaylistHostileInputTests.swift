import Testing
import Foundation
@testable import AetherEngine

/// Audit NET-105 / NAT-102 / NET-106: `HLSPlaylistParser.attribute` recounted the quotes from the line
/// start for every `KEY=` it met (a 64 KiB line took 9.6 s, 4x per doubling), and every
/// EXT-X-PROGRAM-DATE-TIME line built two `ISO8601DateFormatter`s.
struct HLSPlaylistHostileInputTests {

    /// The implementation `attribute` had before the single pass, kept as the oracle.
    private func legacyAttribute(_ key: String, in line: String) -> String? {
        let needle = "\(key)="
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            searchStart = range.upperBound
            if range.lowerBound != line.startIndex {
                let before = line[line.index(before: range.lowerBound)]
                guard before == ":" || before == "," else { continue }
            }
            let quotesBefore = line[line.startIndex..<range.lowerBound]
                .reduce(0) { $1 == "\"" ? $0 + 1 : $0 }
            guard quotesBefore % 2 == 0 else { continue }
            let rest = line[range.upperBound...]
            if rest.hasPrefix("\"") {
                let afterQuote = rest.dropFirst()
                guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
                return String(afterQuote[..<end])
            }
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
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

    private static let keys = ["BANDWIDTH", "AVERAGE-BANDWIDTH", "URI", "TYPE", "GROUP-ID", "NAME", "DEFAULT",
                               "SUBTITLES", "AUDIO", "METHOD", "IV", "LANGUAGE", "FORCED"]

    private static let ordinaryLines = [
        "#EXT-X-STREAM-INF:BANDWIDTH=2000000,AVERAGE-BANDWIDTH=1500000,AUDIO=\"aud\",SUBTITLES=\"subs\"",
        "#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1500000,BANDWIDTH=2000000",
        "#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1500000",
        "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"Deutsch, SDH\",LANGUAGE=\"de\",DEFAULT=YES,URI=\"de.m3u8\"",
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"TYPE=VIDEO\",URI=\"a.m3u8\"",
        "#EXT-X-KEY:METHOD=AES-128,URI=\"https://k.example/key?a=1,b=2\",IV=0x00000000000000000000000000000001",
        "#EXT-X-KEY:METHOD=NONE",
        "#EXT-X-MEDIA:NAME=\"unterminated,TYPE=AUDIO",
        "#EXT-X-MEDIA:URI=\"",
        "#EXT-X-MEDIA:URI=",
        "URI=first,TYPE=x",
        "xURI=nope,URI=yes",
        "",
        "=",
        "#EXT-X-MEDIA:NAME=\"caf\u{00E9} \u{4E2D}\u{6587}\",URI=\"\u{1F600}.m3u8\"",
    ]

    @Test("the single pass matches the old scan on ordinary tag lines")
    func matchesOldScanOnOrdinaryLines() {
        for line in Self.ordinaryLines {
            for key in Self.keys {
                #expect(HLSPlaylistParser.attribute(key, in: line) == legacyAttribute(key, in: line),
                        "key \(key) line \(line.debugDescription)")
            }
        }
    }

    @Test("the single pass matches the old scan on generated quote and comma soup")
    func matchesOldScanOnGeneratedLines() {
        let pieces = ["\"", "\"", ",", ",", ":", "=", "#EXT-X-MEDIA:", "URI=", "TYPE=", "BANDWIDTH=", "AVERAGE-",
                      "NAME=", "a", "b", " ", "x=y", "GROUP-ID=", "\u{00E9}"]
        var rng = SplitMix64(state: 0x1105_0105)
        for _ in 0..<4000 {
            var line = ""
            for _ in 0..<Int.random(in: 0...24, using: &rng) { line += pieces.randomElement(using: &rng)! }
            for key in ["URI", "TYPE", "BANDWIDTH", "NAME", "GROUP-ID"] {
                #expect(HLSPlaylistParser.attribute(key, in: line) == legacyAttribute(key, in: line),
                        "key \(key) line \(line.debugDescription)")
            }
        }
    }

    @Test("an unclosed quote followed by thousands of attributes scans in linear time")
    func unclosedQuoteIsLinear() {
        let line = "#EXT-X-MEDIA:NAME=\"" + String(repeating: ",TYPE=", count: 8_000)
        #expect(line.utf8.count < 64 * 1024)
        let started = ContinuousClock.now
        #expect(HLSPlaylistParser.attribute("TYPE", in: line) == nil)
        #expect(HLSPlaylistParser.attribute("URI", in: line) == nil)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    @Test("a master playlist with a 1 MiB tag line is refused quickly")
    func oversizedLineIsRefused() {
        let hostile = "#EXT-X-MEDIA:NAME=\"" + String(repeating: ",TYPE=", count: 200_000)
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n\(hostile)\n"
        let started = ContinuousClock.now
        #expect(throws: HLSIngestError.self) { _ = try HLSPlaylistParser.parse(text) }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("a long but plausible tag line still parses")
    func longPlausibleLineParses() throws {
        let scte = String(repeating: "FC302500", count: 1_000)
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-DATERANGE:ID="ad",START-DATE="2026-09-30T10:00:00Z",SCTE35-OUT=0x\(scte)
        #EXTINF:6.0,
        seg0.ts
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            Issue.record("not a media playlist"); return
        }
        #expect(media.segments.count == 1)
    }

    @Test("EXTINF reads its duration from the first non-empty comma field")
    func extinfDurationField() throws {
        func duration(_ tag: String) throws -> Double? {
            let text = "#EXTM3U\n#EXT-X-TARGETDURATION:9\n\(tag)\nseg.ts\n"
            guard case .media(let media) = try HLSPlaylistParser.parse(text) else { return nil }
            return media.segments.first?.duration
        }
        #expect(try duration("#EXTINF:6.5,Title, with, commas") == 6.5)
        #expect(try duration("#EXTINF:6.5") == 6.5)
        #expect(try duration("#EXTINF:,7,x") == 7)
        #expect(try duration("#EXTINF:,") == 9)
        #expect(try duration("#EXTINF:abc,x") == 9)
    }

    // MARK: - EXT-X-PROGRAM-DATE-TIME

    private func legacyProgramDateTime(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private func firstSegmentDate(_ pdt: String) throws -> Date? {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-PROGRAM-DATE-TIME:\(pdt)\n#EXTINF:6.0,\nseg.ts\n"
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else { return nil }
        return media.segments.first?.programDateTime
    }

    @Test("fractional and plain program dates parse as the ISO8601DateFormatters did")
    func programDatesMatchTheOldFormatters() throws {
        let shapes = ["2026-09-30T10:00:00.000Z", "2026-09-30T10:00:00Z", "2026-09-30T10:00:00.123Z",
                      "2026-09-30T10:00:00.123456Z", "2026-09-30T10:00:00.000+00:00", "2026-09-30T10:00:00.000+0000",
                      "2026-09-30T12:00:00+02:00", "2026-09-30T12:00:00.250+02:00", "2026-09-30T10:00:00.5Z",
                      "  2026-09-30T10:00:00.000Z  ", "2026-09-30 10:00:00Z", "garbage", "", "2026-13-45T99:00:00Z"]
        for shape in shapes {
            let expected = legacyProgramDateTime(shape)
            let actual = try firstSegmentDate(shape)
            switch (expected, actual) {
            case (nil, nil): break
            case let (expected?, actual?):
                #expect(abs(expected.timeIntervalSince(actual)) < 0.001, "shape \(shape.debugDescription)")
            default:
                Issue.record("shape \(shape.debugDescription): old \(String(describing: expected)) new \(String(describing: actual))")
            }
        }
    }

    @Test("a playlist with a program date on every segment parses in linear time")
    func programDatePerSegmentIsLinear() throws {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:1\n"
        for index in 0..<7_200 {
            let second = index * 2
            let stamp = String(format: "2026-09-30T%02d:%02d:%02d.000Z", (second / 3600) % 24, (second / 60) % 60, second % 60)
            text += "#EXT-X-PROGRAM-DATE-TIME:\(stamp)\n#EXTINF:2.0,\nseg\(index).ts\n"
        }
        let started = ContinuousClock.now
        let parsed = try HLSPlaylistParser.parse(text)
        let elapsed = ContinuousClock.now - started
        guard case .media(let media) = parsed else { Issue.record("not a media playlist"); return }
        #expect(media.segments.count == 7_200)
        #expect(media.segments.allSatisfy { $0.programDateTime != nil })
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }
}
