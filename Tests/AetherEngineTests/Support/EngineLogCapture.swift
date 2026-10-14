import Foundation
@testable import AetherEngine

/// Collects `EngineLog` lines for one test.
///
/// `EngineLog.handler` is one process-global closure and swift-testing runs suites in parallel. A
/// test that replaced it and later put back the value it had found could restore a stale closure
/// while another test was still listening, and that test then read an empty capture (three red CI
/// runs of the #450 witness, none of them reproducible on a Mac with cores to spare). So no test
/// assigns the handler any more: one forwarder is installed the first time a capture is made and
/// fans every line out to the captures alive at that moment.
///
/// Every capture therefore sees the lines of every test that logs at the same time. Filter by a
/// marker that belongs to the test, never count totals.
///
/// Create one, read `lines` / `matching(_:)`, and `end()` it in a `defer` (an XCTest case does so
/// in `tearDown`). Lines emitted after `end()` are not collected; the ones already collected stay
/// readable.
final class EngineLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    init() {
        Registry.shared.add(self)
    }

    func end() {
        Registry.shared.remove(self)
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func matching(_ needle: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.filter { $0.contains(needle) }
    }

    fileprivate func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }

    /// The handler stays installed for the rest of the process once the first capture exists, which
    /// is harmless: nothing in the engine branches on it being set, and with no capture registered
    /// the forwarder does nothing.
    private final class Registry: @unchecked Sendable {
        static let shared: Registry = {
            let registry = Registry()
            EngineLog.handler = { registry.forward($0) }
            return registry
        }()

        private let lock = NSLock()
        private var captures: [ObjectIdentifier: EngineLogCapture] = [:]

        func add(_ capture: EngineLogCapture) {
            lock.lock(); defer { lock.unlock() }
            captures[ObjectIdentifier(capture)] = capture
        }

        func remove(_ capture: EngineLogCapture) {
            lock.lock(); defer { lock.unlock() }
            captures[ObjectIdentifier(capture)] = nil
        }

        func forward(_ line: String) {
            lock.lock()
            let live = Array(captures.values)
            lock.unlock()
            for capture in live { capture.append(line) }
        }
    }
}
