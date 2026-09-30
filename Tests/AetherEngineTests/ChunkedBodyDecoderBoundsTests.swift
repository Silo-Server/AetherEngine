import Testing
import Foundation
@testable import AetherEngine

/// Audit DMX-111: the held connection's chunked decoder waited for a CRLF it would never be sent.
/// A size or trailer line with no end made `takeLine` return nil forever, so the caller kept feeding
/// it, the buffer grew at wire rate and every call rescanned all of it. The blank-line and trailer
/// states consumed forever without producing a byte. A line and the framing around a body are
/// bounded now, and a chunk's own body is not.
@Suite("Chunked decoder bounds")
struct ChunkedBodyDecoderBoundsTests {

    private let maxLine = ChunkedBodyDecoder.maxLineBytes
    private let maxFraming = ChunkedBodyDecoder.maxFramingBytes

    /// Feeds `wire` in `piece`-sized steps, taking after every step, until `take` throws or the wire
    /// is spent. Returns the error, if any, how many bytes had been fed when it came, and the body.
    private func run(_ decoder: ChunkedBodyDecoder, _ wire: Data, piece: Int = 1024)
        -> (error: ChunkedBodyDecoder.ChunkedError?, fed: Int, body: Data) {
        var fed = 0
        var body = Data()
        while fed < wire.count {
            let end = min(fed + piece, wire.count)
            decoder.feed(wire.subdata(in: fed..<end))
            fed = end
            do {
                while let out = try decoder.take(upTo: 1 << 20) { body.append(out) }
            } catch let error as ChunkedBodyDecoder.ChunkedError {
                return (error, fed, body)
            } catch {
                Issue.record("unexpected error \(error)")
                return (nil, fed, body)
            }
        }
        return (nil, fed, body)
    }

    @Test("a size line that never ends is refused once it is longer than a line can be")
    func unterminatedSizeLine() {
        let wire = Data(repeating: UInt8(ascii: "a"), count: 1024 * 1024)
        let result = run(ChunkedBodyDecoder(), wire)
        #expect(result.error == .lineTooLong)
        #expect(result.fed <= maxLine + 2 + 1024, "took \(result.fed) bytes before refusing the line")
    }

    @Test("a trailer line that never ends is refused the same way")
    func unterminatedTrailerLine() {
        let wire = Data("0\r\n".utf8) + Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024)
        let result = run(ChunkedBodyDecoder(), wire)
        #expect(result.error == .lineTooLong)
        #expect(result.fed <= 3 + maxLine + 2 + 1024, "took \(result.fed) bytes before refusing the line")
    }

    @Test("a chunk terminator that is not a line end is refused at the same bound")
    func unterminatedChunkTerminator() {
        let wire = Data("3\r\nabc".utf8) + Data(repeating: UInt8(ascii: "z"), count: 1024 * 1024)
        let result = run(ChunkedBodyDecoder(), wire)
        #expect(result.error == .lineTooLong)
        #expect(String(decoding: result.body, as: UTF8.self) == "abc")
    }

    @Test("endless trailer fields are refused by their total size")
    func endlessTrailerFields() {
        var wire = Data("0\r\n".utf8)
        let field = Data("X-Padding: 0123456789abcdef0123456789abcdef\r\n".utf8)
        for _ in 0..<(4 * maxFraming / field.count) { wire.append(field) }
        let result = run(ChunkedBodyDecoder(), wire)
        #expect(result.error == .framingTooLong)
        #expect(result.fed < 2 * maxFraming, "took \(result.fed) bytes before refusing the trailer")
    }

    @Test("a run of blank lines where a chunk size belongs is refused")
    func endlessBlankLines() {
        let wire = Data(String(repeating: "\r\n", count: 2 * maxFraming).utf8)
        let result = run(ChunkedBodyDecoder(), wire)
        #expect(result.error == .framingTooLong)
        #expect(result.fed < 2 * maxFraming, "took \(result.fed) bytes before refusing the run")
    }

    @Test("a size line at the limit is fine, one byte past it is not, however the wire is cut")
    func lineLimitIsExact() {
        // A size line is `<hex>;<extension>`, so the extension pads it to the length under test.
        func wire(lineBytes: Int) -> Data {
            let head = "5;"
            let padding = String(repeating: "e", count: lineBytes - head.count)
            return Data((head + padding + "\r\nhello\r\n0\r\n\r\n").utf8)
        }
        for piece in [1, 7, 1024, 1 << 20] {
            let ok = run(ChunkedBodyDecoder(), wire(lineBytes: maxLine), piece: piece)
            #expect(ok.error == nil, "a line of \(maxLine) bytes in pieces of \(piece)")
            #expect(String(decoding: ok.body, as: UTF8.self) == "hello")

            let tooLong = run(ChunkedBodyDecoder(), wire(lineBytes: maxLine + 1), piece: piece)
            #expect(tooLong.error == .lineTooLong, "a line of \(maxLine + 1) bytes in pieces of \(piece)")
        }
    }

    @Test("the bounds are on framing, not on the body a chunk carries")
    func bodyIsNotBounded() {
        let payload = Data(repeating: 0x42, count: 3 * 1024 * 1024)
        let wire = Data("300000\r\n".utf8) + payload + Data("\r\n0\r\n\r\n".utf8)
        let decoder = ChunkedBodyDecoder()
        let result = run(decoder, wire, piece: 64 * 1024)
        #expect(result.error == nil)
        #expect(result.body == payload)
        #expect(decoder.isComplete)
    }

    @Test("framing that adds up past the bound across many small chunks is fine, because body resets it")
    func manySmallChunks() {
        let chunkCount = 4 * maxFraming / 6
        var wire = Data()
        for _ in 0..<chunkCount { wire.append(Data("1\r\nx\r\n".utf8)) }
        wire.append(Data("0\r\n\r\n".utf8))
        #expect(wire.count > 2 * maxFraming)
        let decoder = ChunkedBodyDecoder()
        let result = run(decoder, wire)
        #expect(result.error == nil)
        #expect(result.body.count == chunkCount)
        #expect(decoder.isComplete)
    }

    @Test("a realistic trailer still ends the body")
    func realisticTrailer() {
        let trailer = (0..<8).map { "X-Field-\($0): value-\($0)\r\n" }.joined()
        let wire = Data(("5\r\nhello\r\n0\r\n" + trailer + "\r\n").utf8)
        let decoder = ChunkedBodyDecoder()
        let result = run(decoder, wire)
        #expect(result.error == nil)
        #expect(String(decoding: result.body, as: UTF8.self) == "hello")
        #expect(decoder.isComplete)
    }
}
