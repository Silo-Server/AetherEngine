// A sidecar download that ends early must read as incomplete, never as the whole file: the overlay
// used to keep the cues that arrived before the cut for the rest of the session. The origins here
// are subprocesses, which exist on macOS only.
#if os(macOS)
import Foundation
import Testing
@testable import AetherEngine

@Suite("Sidecar subtitle download cut short", .timeLimit(.minutes(3)))
struct SidecarTruncationTests {

    @Test("A body that stalls mid-file throws truncated with the cues read before it", arguments: [false, true])
    func cutBodyIsTruncated(relayed: Bool) async throws {
        let origin = try await SubtitleAuthorizationOrigin()
        defer { origin.stop() }
        let bearer = ["Authorization": "Bearer old"]
        do {
            let result = try await SubtitleDecoder.decodeFile(
                url: origin.url("/cut.srt"), httpHeaders: relayed ? [:] : bearer,
                httpRequestAuthorization: relayed ? HTTPRequestAuthorization { _, _ in bearer } : nil,
                idleTimeout: 1)
            Issue.record("Published \(result.cues.count) cues from a body cut short as complete")
        } catch SubtitleDecoderError.truncated(let partial, _) {
            let lines = try #require(partial.first).cues.compactMap(\.text)
            // The relay closes the reader once it sees the origin fail, which can drop bytes still
            // in flight on loopback; the cues it keeps are a prefix either way.
            #expect(!lines.isEmpty)
            #expect(lines == (1...lines.count).map { "Line \($0)" })
            #expect(lines.count <= 20)
            if !relayed { #expect(lines.count == 20) }
        }
    }

    @Test("The relay reports an origin that breaks off a body, not a consumer that left")
    func relayReportsOriginFailureOnly() async throws {
        // One slice, then twenty seconds of nothing: past the relay's idle timeout.
        let origin = try #require(await TricklingOrigin(slices: 2, pauseSeconds: 20, declaresLength: false))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/sidecar.srt")!
        for consumerLeaves in [false, true] {
            let reported = ReportedFailure()
            let relay = HLSOriginRelay(authorization: HTTPRequestAuthorization { _, _ in [:] },
                                       idleTimeout: 1, rawResources: true,
                                       onRequestFailure: { reported.set() })
            let server = HLSLocalServer(relay: relay)
            try server.start()
            defer { relay.stop(); server.stop() }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (bytes, _) = try await session.bytes(from: try #require(server.relayURL(for: url)))
            var iterator = bytes.makeAsyncIterator()
            #expect(try await iterator.next() == 0x47)
            if consumerLeaves {
                session.invalidateAndCancel()
                #expect(try await !waitFor(upTo: .seconds(3)) { reported.value })
            } else {
                try await waitFor { reported.value }
            }
        }
    }

    @Test("A cut download is refetched, keeps its largest partial set, and ends on a clean decode")
    func retryPolicy() async throws {
        let cut = { (count: Int) in
            SubtitleDecoderError.truncated(partial: [Self.result(cues: count)], code: FFmpegErr.eio)
        }
        // Cut at 3 cues, cut again at 1 (not shown: fewer), refused outright, then complete.
        let script = Script([.failure(cut(3)), .failure(cut(1)), .failure(URLError(.badServerResponse)),
                             .success(Self.result(cues: 7))])
        let shown = Shown()
        let outcome = try await AetherEngine.decodeSidecarRetryingTruncation(
            label: "test", delays: [0, 0, 0, 0], decode: { try await script.next() },
            showPartial: { await shown.append($0.cues.count) })
        #expect(outcome.complete)
        #expect(outcome.result.cues.count == 7)
        #expect(await shown.counts == [3])

        // Retries spent: the largest partial stays, marked incomplete.
        let spent = Script([.failure(cut(2)), .failure(cut(5)), .failure(cut(4))])
        let kept = try await AetherEngine.decodeSidecarRetryingTruncation(
            label: "test", delays: [0, 0], decode: { try await spent.next() }, showPartial: { _ in })
        #expect(!kept.complete)
        #expect(kept.result.cues.count == 5)

        // A cut that delivered no cues still ends incomplete, not failed.
        let empty = Script([.failure(cut(0)), .failure(cut(0))])
        let emptyShown = Shown()
        let none = try await AetherEngine.decodeSidecarRetryingTruncation(
            label: "test", delays: [0], decode: { try await empty.next() },
            showPartial: { await emptyShown.append($0.cues.count) })
        #expect(!none.complete)
        #expect(none.result.cues.isEmpty)
        #expect(await emptyShown.counts == [0])

        // A first fetch that fails outright is not retried.
        let refused = Script([.failure(URLError(.badServerResponse)), .success(Self.result(cues: 1))])
        await #expect(throws: URLError.self) {
            _ = try await AetherEngine.decodeSidecarRetryingTruncation(
                label: "test", delays: [0], decode: { try await refused.next() }, showPartial: { _ in })
        }
    }

    private static func result(cues count: Int) -> SidecarDecodeResult {
        SidecarDecodeResult(cues: (0..<count).map {
            SubtitleCue(id: $0, startTime: Double($0), endTime: Double($0) + 1, body: .text("cue \($0)"))
        }, assHeader: nil)
    }
}

private final class ReportedFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false
    func set() { lock.lock(); reported = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return reported }
}

private actor Script {
    private var steps: [Result<SidecarDecodeResult, any Error>]
    init(_ steps: [Result<SidecarDecodeResult, any Error>]) { self.steps = steps }
    func next() throws -> SidecarDecodeResult { try steps.removeFirst().get() }
}

private actor Shown {
    var counts: [Int] = []
    func append(_ count: Int) { counts.append(count) }
}
#endif
