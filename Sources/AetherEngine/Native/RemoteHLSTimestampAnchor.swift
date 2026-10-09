import Foundation

/// Where the origin's media timestamps sit against its own playlist timeline, so the whole-program WebVTT
/// the #316 proxy injects lands on the picture.
///
/// A WebVTT segment without `X-TIMESTAMP-MAP` maps cue time 0 to MPEG-2 timestamp 0 (RFC 8216 §3.5), while
/// AVPlayer places the A/V on the playlist timeline from the segments' own timestamps. An origin whose
/// media does not start at timestamp 0 therefore shows every injected cue early by exactly that offset.
/// Measured on an ffmpeg MPEG-TS transcode cut with `-copyts -max_delay 5000000`: the muxer adds twice
/// `max_delay`, the video sits 10 s after source time, and the sidecar ran 10 s ahead of the speech.
/// Default muxer settings still leave 1.4 s.
///
/// The anchor is the first video timestamp of one media segment minus that segment's start on the
/// playlist timeline: the PES PTS for MPEG-TS, `tfdt` over the track's `mdhd` timescale for fMP4. It is
/// read once per session, off the load path, from the head of a single segment.
enum RemoteHLSTimestampAnchor {

    /// The one segment the probe reads, and where it sits on the playlist timeline.
    struct Target: Equatable, Sendable {
        let segmentURL: URL
        /// The `EXT-X-MAP` in force for that segment; nil for MPEG-TS.
        let initURL: URL?
        let segmentStart: Double
    }

    /// Anchors below this, negative ones included, keep the plain body. Well under what a viewer can
    /// see on a subtitle, and it absorbs a first frame's composition offset in an fMP4 origin that
    /// already carries source time.
    static let negligibleSeconds = 0.1

    /// The anchor the renditions are served with, given what the probe measured. Only a positive offset
    /// is one of the media timestamps: a muxer delay (ffmpeg MPEG-TS adds 1.4 s by default, 10 s with
    /// `-max_delay 5000000`) only ever moves them later. A segment whose media starts before its playlist
    /// slot is an origin that restarted its transcode at the keyframe before the slot (Jellyfin:
    /// `-noaccurate_seek -copyts`); its media timestamps are still source time, so the plain body
    /// already lands on the frames, and AE#616 measures the lead of item time off it. Mapping that gap
    /// would show every cue early by it and hide the lead from AE#616.
    static func renditionAnchor(measured: Double) -> Double? {
        measured < negligibleSeconds ? nil : measured
    }

    /// Whole-probe budget: one deadline across every request the probe makes (the segment head and,
    /// for fMP4, its init segment), on both the relay and the plain session path. Started when the
    /// proxy is built, so it covers the origin producing the segment AVPlayer is about to ask for
    /// anyway; it stays inside `RemoteHLSSubtitleProvider`'s `.vtt` wait so an answer is in before the
    /// once-per-session rendition fetch gives up on it.
    static let probeBudgetSeconds: TimeInterval = 20

    /// Bytes read from the head of the media segment: PAT, PMT and the first video PES, or the `moof`.
    static let segmentHeadBytes = 128 * 1024
    /// Ceiling for an fMP4 init segment, which carries the track timescales.
    static let initSegmentBytes = 256 * 1024

    // MARK: - Which segment

    /// The segment that holds `startPosition`, which is the one AVPlayer fetches first for this load.
    /// That choice matters for an origin that transcodes on demand: the segment is being produced for
    /// the player anyway, where asking for any other one (the first, say, on a resumed load) can make
    /// such an origin restart its transcode there.
    ///
    /// Nil when the playlist gives no single trustworthy segment: a byte-range playlist (the URI then
    /// names the whole file, not the segment), an encrypted segment, or a URI with a variable this
    /// cannot resolve.
    static func target(mediaPlaylistBody: String, media: HLSMediaPlaylist, at url: URL,
                       startPosition: Double?) -> Target? {
        guard !media.segments.isEmpty, !media.hasUnsupportedEncryption,
              !mediaPlaylistBody.contains("#EXT-X-BYTERANGE") else { return nil }
        let position = max(0, startPosition ?? 0)
        var index = 0
        var start = 0.0
        var elapsed = 0.0
        for (offset, segment) in media.segments.enumerated() {
            if elapsed > position { break }
            index = offset
            start = elapsed
            elapsed += segment.duration
        }
        let segment = media.segments[index]
        guard segment.crypt == nil else { return nil }

        // The parser keeps neither EXT-X-DEFINE nor the EXT-X-MAP URI, so both come off the same lines
        // it reads, in the same order (a URI line is every non-tag line).
        let lines = mediaPlaylistBody
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var variables: [String: String] = [:]
        var map: String?
        var mapForSegment: String?
        var uriLines = 0
        for line in lines {
            if line.hasPrefix("#EXT-X-DEFINE:") {
                if let name = HLSPlaylistParser.attribute("NAME", in: line),
                   let value = HLSPlaylistParser.attribute("VALUE", in: line) {
                    variables[name] = value
                } else if let name = HLSPlaylistParser.attribute("QUERYPARAM", in: line),
                          let value = queryItems.first(where: { $0.name == name })?.value {
                    variables[name] = value
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                map = HLSPlaylistParser.attribute("URI", in: line)
            } else if !line.hasPrefix("#") {
                if uriLines == index { mapForSegment = map; break }
                uriLines += 1
            }
        }
        guard let segmentURL = resolve(segment.uri, variables: variables, against: url) else { return nil }
        var initURL: URL?
        if media.hasMap {
            guard let mapURI = mapForSegment,
                  let resolved = resolve(mapURI, variables: variables, against: url) else { return nil }
            initURL = resolved
        }
        return Target(segmentURL: segmentURL, initURL: initURL, segmentStart: start)
    }

    /// `{$name}` substitution (RFC 8216bis §4.3), then the usual relative resolution. A reference left
    /// unresolved (an IMPORT from the master, a missing query parameter) yields nil rather than a URL
    /// the origin would refuse.
    private static func resolve(_ uri: String, variables: [String: String], against url: URL) -> URL? {
        var substituted = uri
        for (name, value) in variables {
            substituted = substituted.replacingOccurrences(of: "{$\(name)}", with: value)
        }
        guard !substituted.contains("{$") else { return nil }
        return HLSPlaylistParser.resolve(uri: substituted, against: url)
    }

    // MARK: - Probe

    /// Reads the target's head (and its init segment for fMP4) and returns the anchor, or nil when it
    /// is negligible, negative (`renditionAnchor(measured:)`) or cannot be read. Nil means the plain WebVTT body, which is what the renditions
    /// served before the anchor existed. A refreshable authorizer goes through a relay of its own, with
    /// the same redirect and credential policy as the playlist preflight; anything else uses a session
    /// on `EngineTLS`'s delegate, like the playlist reads. `budget` bounds the whole probe, not each
    /// request: a URL session's timeouts apply per task, so two sequential reads against a stalled
    /// origin would otherwise take twice as long.
    static func probe(_ target: Target, credentials: CredentialScope,
                      authorization: HTTPRequestAuthorization?,
                      budget: TimeInterval = probeBudgetSeconds) async -> Double? {
        let deadline = Date().addingTimeInterval(budget)
        let relay = authorization.map {
            HLSOriginRelay(authorization: $0, authorizationTimeout: budget, resourceTimeout: budget,
                           deadline: deadline)
        }
        defer { relay?.stop() }
        let session = relay == nil ? makeSession(timeout: budget) : nil
        defer { session?.invalidateAndCancel() }

        @Sendable func head(_ url: URL, _ maximumBytes: Int) async throws -> Data {
            // Audit NAT-105: the segment and its init can sit on any host the playlist names, so the
            // host's credentials go only where the host sent them.
            let headers = credentials.headers(for: url)
            if let relay { return try await relay.fetchHead(url, headers: headers, maximumBytes: maximumBytes) }
            guard let session else { throw URLError(.cancelled) }
            return try await fetchHead(url, headers: headers, maximumBytes: maximumBytes, session: session)
        }

        do {
            let (segment, initSegment) = try await beforeDeadline(deadline) {
                let segment = try await head(target.segmentURL, segmentHeadBytes)
                guard let initURL = target.initURL, LiveSegmentFormat.classify(segment) != .mpegts else {
                    return (segment, nil as Data?)
                }
                return (segment, try await head(initURL, initSegmentBytes))
            }
            guard let anchor = anchorSeconds(segmentHead: segment, initSegment: initSegment,
                                             segmentStart: target.segmentStart) else {
                EngineLog.emit(
                    "[AetherEngine] #316: no media timestamp in the head of \(target.segmentURL.lastPathComponent), "
                    + "subtitle renditions keep cue time 0 at timestamp 0", category: .engine)
                return nil
            }
            EngineLog.emit(
                "[AetherEngine] #316: origin media sits \(String(format: "%.3f", anchor)) s from its playlist "
                + "timeline (\(target.segmentURL.lastPathComponent) at \(String(format: "%.3f", target.segmentStart)) s)",
                category: .engine)
            return renditionAnchor(measured: anchor)
        } catch {
            if !Task.isCancelled {
                EngineLog.emit(
                    "[AetherEngine] #316: timestamp probe of \(target.segmentURL.lastPathComponent) failed (\(error)), "
                    + "subtitle renditions keep cue time 0 at timestamp 0", category: .engine)
            }
            return nil
        }
    }

    /// Runs `work` until `deadline`, then cancels it and throws `URLError(.timedOut)`. Cancelling the
    /// task cancels the URL session task it is awaiting, and the relay stops on cancellation, so the
    /// probe returns at the deadline whichever request is outstanding.
    private static func beforeDeadline<T: Sendable>(
        _ deadline: Date, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw URLError(.timedOut) }
            return value
        }
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    /// Streams at most `maximumBytes` and abandons the rest, so an origin that ignores the range costs
    /// the same as one that honours it.
    private static func fetchHead(_ url: URL, headers: [String: String], maximumBytes: Int,
                                  session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=0-\(maximumBytes - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maximumBytes { break }
        }
        return data
    }

    // MARK: - Parsing

    /// First media timestamp of the segment, in seconds, minus the segment's playlist start. Nil when
    /// either side is not a finite number (a playlist whose EXTINFs sum to NaN), so the rendition keeps
    /// the plain body.
    static func anchorSeconds(segmentHead: Data, initSegment: Data?, segmentStart: Double) -> Double? {
        let timestamp: Double
        if let pts = firstPESTimestamp90k(in: segmentHead) {
            timestamp = Double(pts) / 90_000
        } else if let initSegment, let decodeTime = fragmentDecodeTimeSeconds(initSegment: initSegment,
                                                                              fragment: segmentHead) {
            timestamp = decodeTime
        } else {
            return nil
        }
        let anchor = timestamp - segmentStart
        return anchor.isFinite ? anchor : nil
    }

    /// PTS of the first video PES (stream_id 0xE0-0xEF) in an MPEG-TS head, or of the first audio PES
    /// (0xC0-0xDF) when no video PES starts within it. Keyed on the PES stream_id, so no PMT is needed.
    static func firstPESTimestamp90k(in data: Data) -> Int64? {
        let packetSize = 188
        let bytes = [UInt8](data)
        var audio: Int64?
        var packet = 0
        while packet + packetSize <= bytes.count {
            guard bytes[packet] == 0x47 else { return audio } // lost packet alignment
            defer { packet += packetSize }
            let end = packet + packetSize
            let adaptationControl = (bytes[packet + 3] >> 4) & 0x03
            guard bytes[packet + 1] & 0x40 != 0, // payload_unit_start
                  adaptationControl == 1 || adaptationControl == 3 else { continue }
            var pes = packet + 4
            if adaptationControl == 3 { pes += 1 + Int(bytes[pes]) }
            guard pes + 14 <= end,
                  bytes[pes] == 0, bytes[pes + 1] == 0, bytes[pes + 2] == 1,
                  bytes[pes + 6] & 0xC0 == 0x80, // '10' marker of the optional PES header
                  bytes[pes + 7] & 0x80 != 0 else { continue } // PTS present
            let p = pes + 9
            let pts = (Int64(bytes[p] >> 1) & 0x07) << 30
                | Int64(bytes[p + 1]) << 22
                | Int64(bytes[p + 2] >> 1) << 15
                | Int64(bytes[p + 3]) << 7
                | Int64(bytes[p + 4] >> 1)
            switch bytes[pes + 3] {
            case 0xE0...0xEF: return pts
            case 0xC0...0xDF where audio == nil: audio = pts
            default: break
            }
        }
        return audio
    }

    /// `tfdt` of the fragment's video track (or its first track) over that track's `mdhd` timescale.
    static func fragmentDecodeTimeSeconds(initSegment: Data, fragment: Data) -> Double? {
        let initBytes = [UInt8](initSegment)
        var tracks: [UInt32: (timescale: UInt32, isVideo: Bool)] = [:]
        guard let moov = boxes(initBytes, in: 0..<initBytes.count).first(where: { $0.type == "moov" })
        else { return nil }
        for trak in boxes(initBytes, in: moov.payload) where trak.type == "trak" {
            let trakBoxes = boxes(initBytes, in: trak.payload)
            guard let tkhd = trakBoxes.first(where: { $0.type == "tkhd" }),
                  let trackID = fullBoxField32(initBytes, tkhd.payload, v0: 12, v1: 20),
                  let mdia = trakBoxes.first(where: { $0.type == "mdia" }) else { continue }
            let mdiaBoxes = boxes(initBytes, in: mdia.payload)
            guard let mdhd = mdiaBoxes.first(where: { $0.type == "mdhd" }),
                  let timescale = fullBoxField32(initBytes, mdhd.payload, v0: 12, v1: 20),
                  timescale > 0 else { continue }
            let hdlr = mdiaBoxes.first(where: { $0.type == "hdlr" })
            let isVideo = hdlr.map { $0.payload.count >= 12 && fourCC(initBytes, $0.payload.lowerBound + 8) == "vide" }
                ?? false
            tracks[trackID] = (timescale, isVideo)
        }

        let bytes = [UInt8](fragment)
        guard let moof = boxes(bytes, in: 0..<bytes.count).first(where: { $0.type == "moof" }) else { return nil }
        var first: Double?
        for traf in boxes(bytes, in: moof.payload) where traf.type == "traf" {
            let trafBoxes = boxes(bytes, in: traf.payload)
            guard let tfhd = trafBoxes.first(where: { $0.type == "tfhd" }), tfhd.payload.count >= 8,
                  let tfdt = trafBoxes.first(where: { $0.type == "tfdt" }), tfdt.payload.count >= 8,
                  let track = tracks[uint32(bytes, tfhd.payload.lowerBound + 4)] else { continue }
            let decodeTime = bytes[tfdt.payload.lowerBound] == 1 && tfdt.payload.count >= 12
                ? uint64(bytes, tfdt.payload.lowerBound + 4)
                : UInt64(uint32(bytes, tfdt.payload.lowerBound + 4))
            let seconds = Double(decodeTime) / Double(track.timescale)
            if track.isVideo { return seconds }
            if first == nil { first = seconds }
        }
        return first
    }

    /// The complete boxes inside `range`; a box running past it (a truncated `mdat`) ends the walk. The
    /// size is checked against the bytes left rather than added to the offset: an origin's 64-bit size
    /// can be anything up to `Int.max`, and the sum would trap.
    private static func boxes(_ bytes: [UInt8], in range: Range<Int>) -> [(type: String, payload: Range<Int>)] {
        var found: [(type: String, payload: Range<Int>)] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(uint32(bytes, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                let large = uint64(bytes, offset + 8)
                guard large <= UInt64(Int.max) else { break }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, size <= range.upperBound - offset else { break }
            found.append((fourCC(bytes, offset + 4), (offset + header)..<(offset + size)))
            offset += size
        }
        return found
    }

    /// A version-dependent 32-bit field of a full box: at `v0` for version 0, at `v1` for version 1.
    private static func fullBoxField32(_ bytes: [UInt8], _ payload: Range<Int>, v0: Int, v1: Int) -> UInt32? {
        guard !payload.isEmpty else { return nil }
        let at = bytes[payload.lowerBound] == 1 ? v1 : v0
        guard payload.count >= at + 4 else { return nil }
        return uint32(bytes, payload.lowerBound + at)
    }

    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func uint64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
