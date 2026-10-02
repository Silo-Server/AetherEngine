// Sources/AetherEngine/Video/IFrameRendition.swift
import Foundation

/// What the segment provider needs from an I-frame rendition (AE#682).
protocol IFrameSegmentSource: AnyObject, Sendable {
    func initSegment() -> Data?
    func fragment(at index: Int) -> Data?
}

/// AE#682: answers `iframe_init.mp4` and `iframe{N}.mp4`. One request at a time: there is one side
/// demuxer, and AVKit asks for up to five keyframes at once.
final class IFrameRendition: IFrameSegmentSource, @unchecked Sendable {
    struct Entry {
        let startPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
    }

    private let entries: [Entry]
    private let cache: IFramePayloadCache
    private let readPayload: (Entry) -> Data?
    private let buildFragment: (Data, Int, Entry) -> IFrameFragmentBuilder.Output?
    private let waitForLink: () -> Void
    private let interruptReads: () -> Void
    private let closeReader: () -> Void

    private let queue = DispatchQueue(label: "aether.iframe-rendition")
    private let stateLock = NSLock()
    private var isShutDown = false
    private var capturedInit: Data?

    init(entries: [Entry],
         cache: IFramePayloadCache,
         readPayload: @escaping (Entry) -> Data?,
         buildFragment: @escaping (Data, Int, Entry) -> IFrameFragmentBuilder.Output?,
         waitForLink: @escaping () -> Void = {},
         interruptReads: @escaping () -> Void = {},
         closeReader: @escaping () -> Void = {}) {
        self.entries = entries
        self.cache = cache
        self.readPayload = readPayload
        self.buildFragment = buildFragment
        self.waitForLink = waitForLink
        self.interruptReads = interruptReads
        self.closeReader = closeReader
    }

    private var shutDown: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isShutDown
    }

    func initSegment() -> Data? {
        queue.sync {
            guard !shutDown else { return nil }
            if capturedInit == nil { _ = buildLocked(at: 0) }
            return capturedInit
        }
    }

    func fragment(at index: Int) -> Data? {
        queue.sync {
            guard !shutDown else { return nil }
            return buildLocked(at: index)
        }
    }

    private func buildLocked(at index: Int) -> Data? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        var payload = cache.payload(for: index)
        if payload == nil {
            waitForLink()
            guard !shutDown else { return nil }
            let started = DispatchTime.now()
            if let read = readPayload(entry) {
                cache.store(read, for: index)
                payload = read
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                EngineLog.emit("[IFrameRendition] read idx=\(index) bytes=\(read.count) "
                               + "ms=\(String(format: "%.0f", ms))", category: .session, level: .verbose)
            } else if let neighbour = cache.nearestIndex(to: index),
                      let substitute = cache.payload(for: neighbour) {
                // AVKit keeps the last good picture for a keyframe it cannot fetch, and rate trick
                // play wedges on a 404, so a near keyframe at the right time beats no answer.
                payload = substitute
                EngineLog.emit("[IFrameRendition] read failed idx=\(index), serving idx=\(neighbour) in its place",
                               category: .session)
            } else {
                EngineLog.emit("[IFrameRendition] read failed idx=\(index) with nothing cached to stand in",
                               category: .session)
                return nil
            }
        }
        guard let payload, let output = buildFragment(payload, index, entry) else { return nil }
        if capturedInit == nil { capturedInit = output.initSegment }
        return output.fragment
    }

    /// Idempotent. Aborts a read in flight, waits for the request that owns it to return, then
    /// closes the reader and drops the cache.
    func shutdown() {
        stateLock.lock()
        let already = isShutDown
        isShutDown = true
        stateLock.unlock()
        guard !already else { return }
        interruptReads()
        queue.sync {
            closeReader()
            cache.removeAll()
        }
    }
}
