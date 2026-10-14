import Foundation

/// One picture may decode under a paused transport after a load or seek.
/// Owned by SoftwarePlaybackHost's flags lock: stale/preroll frames must not
/// consume the request that lets the winning seek's loops run.
struct PausedFrameGate {
    private var request: (generation: UInt64, minimumPTS: Double?)?

    var isPending: Bool { request != nil }

    mutating func arm(generation: UInt64, minimumPTS: Double? = nil) {
        request = (generation, minimumPTS)
    }

    mutating func cancel() {
        request = nil
    }

    mutating func consume(generation: UInt64, pts: Double) -> Bool {
        guard let request, request.generation == generation, pts.isFinite,
              request.minimumPTS.map({ pts >= $0 }) ?? true else { return false }
        self.request = nil
        return true
    }
}

/// End of media read while a paused seek waits for its picture. The viewer is
/// still paused, so `play()` delivers the end; a newer seek discards it.
struct HeldEndOfMedia {
    private var generation: UInt64?

    mutating func hold(generation: UInt64) {
        self.generation = generation
    }

    /// Clears the hold and says whether it belongs to the current seek.
    mutating func release(currentGeneration: UInt64) -> Bool {
        defer { generation = nil }
        return generation == currentGeneration
    }
}
