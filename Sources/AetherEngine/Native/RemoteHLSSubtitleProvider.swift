import Foundation

/// #316: serves the sidecar renditions the remote-HLS subtitle proxy injects into the origin master.
///
/// It is an `HLSSegmentProvider` that owns no media at all. The A/V variants in the rewritten master
/// point straight at the origin, so AVPlayer never asks this server for a segment; only `/master.m3u8`
/// (verbatim, via `staticMasterPlaylistBody`), `/subs_{n}.m3u8` and `/subs_{n}_0.vtt` are ever fetched.
/// The single reported segment exists so `buildSubtitleMediaPlaylistText`'s whole-program shape can read
/// the program duration off the usual `segmentDuration(at:)` path (Sodalite#32) without a special case.
final class RemoteHLSSubtitleProvider: HLSSegmentProvider, @unchecked Sendable {

    /// One declared sidecar, tied back to the engine-side external track id it was registered under.
    struct Track: Sendable {
        let externalID: Int
        let source: ExternalSubtitleTrack
    }

    let tracks: [Track]

    /// Settable because the relay can only rewrite this once the server it is mounted on has a
    /// port and a token, which is after the provider exists. Written once during build, before
    /// the server has answered anything.
    private(set) var staticMasterPlaylistBody: String?

    /// Total program seconds, summed from the origin's own variant playlist. TARGETDURATION and the
    /// single EXTINF of every subtitle rendition are built from it.
    private let programDuration: Double
    private let stores: [NativeSubtitleCueStore]
    private let defaultHeaders: [String: String]
    /// Guards `fillTask` alone: the fill is started from the proxy's build (off the main actor) and
    /// cancelled from the engine's teardown (on it), so the handle is genuinely shared.
    private let fillLock = NSLock()
    private var fillTask: Task<Void, Never>?

    /// Where cue time 0 sits on the origin's media timestamps (`RemoteHLSTimestampAnchor`). Unprobed
    /// and failed probes both serve the plain body; a running probe holds the `.vtt` answer inside the
    /// same wait as an unfinished store, because AVPlayer keeps the first answer for the session.
    private enum TimestampAnchor {
        case unprobed
        case probing
        case resolved(Double?)
    }
    /// Guards `timestampAnchor` and `anchorTask`: resolved on the probe's task, read on the server's
    /// connection thread, cancelled from the engine's teardown.
    private let anchorLock = NSLock()
    private var timestampAnchor = TimestampAnchor.unprobed
    private var anchorTask: Task<Void, Never>?

    /// How long a `.vtt` fetch waits for its store to finish. AVPlayer fetches a whole-program VOD
    /// subtitle segment ONCE and never re-fetches it, so serving early means serving truncated for the
    /// rest of the session; the fill normally completes long before the rendition is ever selected.
    /// Mirrors the loopback path's budget.
    static let defaultVTTFillWaitSeconds: TimeInterval = 30
    private let vttFillWaitSeconds: TimeInterval

    init(tracks: [Track], masterBody: String, programDuration: Double,
         defaultHeaders: [String: String],
         vttFillWaitSeconds: TimeInterval = defaultVTTFillWaitSeconds) {
        self.tracks = tracks
        self.staticMasterPlaylistBody = masterBody
        self.programDuration = max(1, programDuration)
        self.defaultHeaders = defaultHeaders
        self.vttFillWaitSeconds = vttFillWaitSeconds
        self.stores = tracks.map { _ in NativeSubtitleCueStore() }
    }

    /// Replaces the served master. Only the relay calls this, to send the origin's variants back
    /// through the engine once the server's address is known.
    func setMasterPlaylistBody(_ body: String) {
        staticMasterPlaylistBody = body
    }

    /// The renditions as the rewriter needs to declare them, in `subs_{ordinal}` order.
    static func renditions(for tracks: [Track]) -> [RemoteHLSMasterRewrite.Rendition] {
        tracks.enumerated().map { ordinal, track in
            RemoteHLSMasterRewrite.Rendition(
                ordinal: ordinal,
                name: track.source.makeTrackInfo(id: track.externalID, fallbackNumber: ordinal + 1).name,
                language: track.source.language,
                isForced: track.source.isForced,
                isSDH: track.source.isHearingImpaired)
        }
    }

    /// Decode every sidecar into its store up front, off the main actor. Same one-pass-per-container
    /// machinery the loopback path uses (#266), so a container holding several subtitle streams is read
    /// once and a single bad stream index cannot blank its siblings.
    func startFill() {
        cancelDecode()
        let jobs = Self.fillJobs(tracks: tracks, stores: stores, defaultHeaders: defaultHeaders)
        guard !jobs.isEmpty else { return }
        let task = Task.detached(priority: .utility) { [jobs] in
            for job in jobs {
                if Task.isCancelled { return }
                await AetherEngine.runExternalSubtitleFill(job: job)
            }
        }
        fillLock.lock()
        fillTask = task
        fillLock.unlock()
    }

    /// Teardown: stops the decode and a timestamp probe still in flight.
    func cancelFill() {
        cancelDecode()
        anchorLock.lock()
        let probe = anchorTask
        anchorTask = nil
        anchorLock.unlock()
        probe?.cancel()
    }

    private func cancelDecode() {
        fillLock.lock()
        let task = fillTask
        fillTask = nil
        fillLock.unlock()
        task?.cancel()
    }

    /// Runs `probe` once, off the load path, and anchors every rendition this provider serves to its
    /// answer. The proxy starts it right after the build, so the segment it reads is the one the
    /// origin is producing for the player's first request anyway.
    func startTimestampAnchorProbe(_ probe: @escaping @Sendable () async -> Double?) {
        anchorLock.lock()
        timestampAnchor = .probing
        anchorLock.unlock()
        let task = Task.detached(priority: .utility) { [weak self] in
            let anchor = await probe()
            self?.resolveTimestampAnchor(anchor)
        }
        anchorLock.lock()
        anchorTask = task
        anchorLock.unlock()
    }

    private func resolveTimestampAnchor(_ anchor: Double?) {
        anchorLock.lock()
        timestampAnchor = .resolved(anchor)
        anchorLock.unlock()
    }

    /// Wait for the started probe, the `awaitFill` of the anchor: for tests, not for the session.
    func awaitTimestampAnchor() async {
        await currentAnchorTask()?.value
    }

    private func currentAnchorTask() -> Task<Void, Never>? {
        anchorLock.lock()
        defer { anchorLock.unlock() }
        return anchorTask
    }

    /// Nil while unprobed, still probing, or when the probe had no answer: all mean the plain body.
    private var anchorSnapshot: (pending: Bool, seconds: Double?) {
        anchorLock.lock()
        defer { anchorLock.unlock() }
        switch timestampAnchor {
        case .unprobed: return (false, nil)
        case .probing: return (true, nil)
        case .resolved(let seconds): return (false, seconds)
        }
    }

    /// Wait for the started fill to finish. Nothing in the session waits for it, the `.vtt` handler
    /// polls the store instead; this exists so a test can assert on a finished store without racing
    /// the wall clock. `nativeSubtitleVTT`'s wait is a budget, and a budget loses under a saturated
    /// cooperative pool, where the detached decode does not get a thread at all.
    func awaitFill() async {
        await currentFillTask()?.value
    }

    /// Reading the handle stays synchronous: `NSLock` is unavailable from an async context.
    private func currentFillTask() -> Task<Void, Never>? {
        fillLock.lock()
        defer { fillLock.unlock() }
        return fillTask
    }

    /// One job per (url, headers, authorization identity) group, in first-appearance order. Mirrors
    /// `AetherEngine.externalSubtitleFillJobs`, which keys off the loopback's rendition table.
    static func fillJobs(tracks: [Track],
                         stores: [NativeSubtitleCueStore],
                         defaultHeaders: [String: String]) -> [AetherEngine.ExternalSubtitleFillJob] {
        struct Key: Hashable {
            let url: URL
            let headers: [String: String]
            let authorizationID: ObjectIdentifier?
        }
        var authorizationsByKey: [Key: HTTPRequestAuthorization] = [:]
        var order: [Key] = []
        var targetsByKey: [Key: [AetherEngine.ExternalSubtitleFillJob.Target]] = [:]
        for (ordinal, track) in tracks.enumerated() where ordinal < stores.count {
            stores[ordinal].setExternalTimelineOffsetSeconds(track.source.nativeTimelineOffsetSeconds)
            let key = Key(url: track.source.url, headers: track.source.httpHeaders ?? defaultHeaders,
                          authorizationID: track.source.httpRequestAuthorization.map(ObjectIdentifier.init))
            authorizationsByKey[key] = track.source.httpRequestAuthorization
            if targetsByKey[key] == nil { order.append(key) }
            targetsByKey[key, default: []].append(
                .init(streamIndex: track.source.sourceStreamIndex, store: stores[ordinal]))
        }
        return order.map {
            AetherEngine.ExternalSubtitleFillJob(url: $0.url, headers: $0.headers,
                                                 httpRequestAuthorization: authorizationsByKey[$0],
                                                 targets: targetsByKey[$0] ?? [])
        }
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? { nil }
    func mediaSegment(at index: Int) -> Data? { nil }

    /// This provider owns no media, and says so: a `/seg{N}.mp4` that reaches this origin is answered 404
    /// rather than "not yet, retry", because it never will exist. The served master's only variants are
    /// the origin's own.
    var segmentCount: Int { 0 }

    /// The subtitle playlist builder derives the whole-program TARGETDURATION and EXTINF from one visible
    /// segment (Sodalite#32). Reporting it here, instead of through `segmentCount`, keeps the duration
    /// math working without also claiming a media segment exists.
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        (visibleCount: 1, firstVisible: 0, refreshCounter: 0, endlistAdded: true, discontinuitySequence: 0)
    }

    func segmentDuration(at index: Int) -> Double { programDuration }
    var playlistType: HLSPlaylistType { .vod }
    var nativeSubtitleWholeProgram: Bool { true }

    /// Empty on purpose: `nativeSubtitleRenditions` only feeds the master BUILDER, and this provider
    /// serves a finished master instead. The EXT-X-MEDIA tags were written by `RemoteHLSMasterRewrite`.
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { [] }

    /// Whole-program WebVTT on the origin item's timeline. The host can declare
    /// an upstream reanchor offset; unfinished stores must not be served because
    /// AVPlayer caches this response for the rest of the session.
    ///
    /// The cues stay in source time; an `X-TIMESTAMP-MAP` ties cue time 0 to where the origin's media
    /// timestamps put it. A probe that has not answered inside the wait serves the plain body, which
    /// is what this returned before the anchor existed.
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> NativeSubtitleVTTResponse {
        guard tracks.indices.contains(ordinal), segmentIndex == 0 else { return .missing }
        let store = stores[ordinal]
        let deadline = Date().addingTimeInterval(vttFillWaitSeconds)
        while !store.isFinished || anchorSnapshot.pending, Date() < deadline {
            usleep(100_000)
        }
        guard store.isFinished else { return .pending }
        let anchor = anchorSnapshot
        if anchor.pending {
            EngineLog.emit(
                "[AetherEngine] #316: subs_\(ordinal) served before the timestamp probe answered, "
                + "cue time 0 stays at timestamp 0", category: .engine)
        }
        let cues = store.allCues()
        return .ready(WebVTTBuilder.body(cues: cues, timestampAnchorSeconds: anchor.seconds))
    }
}
