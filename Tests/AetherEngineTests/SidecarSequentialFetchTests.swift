import Testing
import Foundation
@testable import AetherEngine

/// A text sidecar costs one request. The origin here answers like a server that compresses its
/// subtitle responses: 200 to every request, Range ignored, no Content-Length. The ranged open
/// asked it for a tail, a range and a range check before the GET it decoded, and each of those
/// made the origin send the whole file.
@Suite("sidecar sequential fetch")
struct SidecarSequentialFetchTests {
    private static let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n\n00:00:03.000 --> 00:00:04.000\nWorld\n"

    private func lengthlessOrigin() throws -> ProbeHTTPTestOrigin {
        let body = Data(Self.vtt.utf8)
        return try ProbeHTTPTestOrigin(data: body, response: { _, _ in
            Data("HTTP/1.1 200 OK\r\nContent-Type: text/vtt\r\nConnection: close\r\n\r\n".utf8) + body
        })
    }

    private func url(_ origin: ProbeHTTPTestOrigin) -> URL {
        URL(string: "http://127.0.0.1:\(origin.port)/subtitles/0")!
    }

    @Test("a text sidecar is one unranged request")
    func textSidecarIsOneRequest() async throws {
        let origin = try lengthlessOrigin()
        defer { origin.stop() }

        let result = try await SubtitleDecoder.decodeFile(url: url(origin), sequentialSource: true)

        #expect(result.cues.compactMap(\.text) == ["Hello", "World"])
        #expect(origin.requests.count == 1)
        #expect(origin.requests.first?.range == nil)
    }

    @Test("the ranged open asks this origin more than once")
    func rangedOpenAsksMoreThanOnce() async throws {
        let origin = try lengthlessOrigin()
        defer { origin.stop() }

        let result = try await SubtitleDecoder.decodeFile(url: url(origin))

        #expect(result.cues.compactMap(\.text) == ["Hello", "World"])
        #expect(origin.requests.count > 1)
    }

    @Test("a fill job reads sequentially only when every track it fills is text")
    func fillJobsReadSequentiallyOnlyForText() {
        let text = URL(string: "https://example.test/subtitles/0")!
        let container = URL(string: "https://example.test/movie.mkv")!
        let unknown = URL(string: "https://example.test/subtitles/1")!
        let registry: [Int: ExternalSubtitleTrack] = [
            100_000: ExternalSubtitleTrack(url: text, formatHint: "subrip"),
            100_001: ExternalSubtitleTrack(url: container, sourceStreamIndex: 2),
            100_002: ExternalSubtitleTrack(url: unknown),
        ]
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000, language: "eng"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_001, language: "spa"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_002, language: "fra"),
        ]
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore(), NativeSubtitleCueStore()]

        let jobs = AetherEngine.externalSubtitleFillJobs(
            table: table, registry: registry, stores: stores, defaultHeaders: [:], mediaURL: nil)

        #expect(jobs.map(\.url) == [text, container, unknown])
        #expect(jobs.map(\.sequentialSource) == [true, false, false])
    }
}
