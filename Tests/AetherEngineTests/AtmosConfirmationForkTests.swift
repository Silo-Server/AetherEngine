import Testing
import Foundation
@testable import AetherEngine

/// Audit DEC-109: `startAtmosConfirmation` forked the host's custom reader only to test the fork for
/// nil and dropped it, and the `IOReader` contract says the engine owns and closes every independent
/// reader it is handed.
@Suite("Atmos confirmation reader probe (DEC-109)")
struct AtmosConfirmationForkTests {

    private final class Fork: IOReader, @unchecked Sendable {
        private let lock = NSLock()
        private var _closed = false
        var isClosed: Bool { lock.withLock { _closed } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { 0 }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() { lock.withLock { _closed = true } }
    }

    private final class Host: IOReader, @unchecked Sendable {
        private let lock = NSLock()
        private let forkable: Bool
        private var _forks: [Fork] = []
        var forks: [Fork] { lock.withLock { _forks } }
        init(forkable: Bool) { self.forkable = forkable }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { 0 }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        func makeIndependentReader() -> IOReader? {
            guard forkable else { return nil }
            let fork = Fork()
            lock.withLock { _forks.append(fork) }
            return fork
        }
    }

    @Test("the probe closes the fork it built")
    func probeClosesItsFork() {
        let host = Host(forkable: true)
        #expect(AetherEngine.canForkCustomReader(host))
        #expect(host.forks.count == 1)
        let allClosed = host.forks.allSatisfy { $0.isClosed }
        #expect(allClosed, "a fork built to be nil-tested must not outlive the test")
    }

    @Test("a one-shot reader, or none at all, cannot be forked")
    func unforkableReader() {
        #expect(!AetherEngine.canForkCustomReader(Host(forkable: false)))
        #expect(!AetherEngine.canForkCustomReader(nil))
    }
}
