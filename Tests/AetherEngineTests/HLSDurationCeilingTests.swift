import Testing
@testable import AetherEngine

/// Audit NET-101, FEA-102, HLS-102: `Double(_:)` accepts `inf`, `nan` and any magnitude, and the playlist
/// parser stored the result unchecked. The live join log traps on `Int(inf)`, the live subtitle poll on
/// `UInt64(inf * 1e9)`, and the VOD ingest's EXTINF sum reaches the segment-plan builders unbounded.
@Suite("HLS durations stay inside the one-week program ceiling")
struct HLSDurationCeilingTests {

    private func media(targetDuration: String = "6", extinf: String) -> String {
        """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(targetDuration)
        #EXTINF:\(extinf),
        seg0.ts
        #EXT-X-ENDLIST
        """
    }

    private func isPlaylistInvalid(_ text: String) -> Bool {
        do {
            _ = try HLSPlaylistParser.parse(text)
            return false
        } catch HLSIngestError.playlistInvalid {
            return true
        } catch {
            return false
        }
    }

    @Test("A non-finite or absurd EXTINF is refused", arguments: [
        "inf", "infinity", "nan", "1e300", "604801", "200000000000000",
    ])
    func rejectsHostileExtinf(value: String) {
        #expect(isPlaylistInvalid(media(extinf: value)))
    }

    @Test("A non-finite or absurd TARGETDURATION is refused", arguments: ["inf", "nan", "1e300", "20000000000"])
    func rejectsHostileTargetDuration(value: String) {
        #expect(isPlaylistInvalid(media(targetDuration: value, extinf: "6")))
    }

    @Test("A whole program in one EXTINF, up to a week, still parses")
    func weekLongEntryParses() throws {
        guard case .media(let playlist) = try HLSPlaylistParser.parse(media(extinf: "604800")) else {
            Issue.record("expected a media playlist")
            return
        }
        #expect(playlist.segments.first?.duration == 604_800)
    }

    @Test("The subtitle proxy's program ceiling is the parser's")
    func proxySharesTheCeiling() {
        #expect(RemoteHLSSubtitleProxy.maxProgramDurationSeconds == MediaDurationCeiling.seconds)
        #expect(MediaDurationCeiling.seconds == 604_800)
    }

    private func segments(_ durations: [Double]) -> [HLSMediaSegment] {
        durations.enumerated().map { HLSMediaSegment(uri: "s\($0.offset).ts", duration: $0.element,
                                                    discontinuityBefore: false) }
    }

    @Test("A VOD playlist summing past a week is refused, however small its entries")
    func vodTotalCeiling() {
        // Each entry passes the parser's per-entry ceiling; the sum does not.
        #expect(throws: HLSIngestError.self) {
            _ = try HLSVODIngestReader.segmentTimeline(segments([604_800, 604_800]))
        }
        // The Double-sum vanish case: a tiny entry after a large sum does not move the total, so the
        // starts stop being monotonic and the plan falls back to a uniform grid over the whole sum.
        #expect(throws: HLSIngestError.self) {
            _ = try HLSVODIngestReader.segmentTimeline(segments(Array(repeating: 604_800, count: 1000) + [1e-9]))
        }
    }

    @Test("An ordinary VOD playlist keeps its starts and total")
    func vodTimelineUnchanged() throws {
        let timeline = try HLSVODIngestReader.segmentTimeline(segments([6, 6, 4.5]))
        #expect(timeline.starts == [0, 6, 12])
        #expect(timeline.duration == 16.5)
        #expect(throws: HLSIngestError.self) {
            _ = try HLSVODIngestReader.segmentTimeline(segments([6, 0, 6]))
        }
    }

    @Test("The live subtitle poll interval stays between one and thirty seconds", arguments: [
        (6.0, 6.0), (0.2, 1.0), (604_800.0, 30.0), (Double.infinity, 30.0), (Double.nan, 1.0), (-5.0, 1.0),
    ])
    func liveSubtitlePollInterval(targetDuration: Double, expected: Double) {
        #expect(AetherEngine.liveSubtitlePollInterval(targetDuration: targetDuration) == expected)
    }
}
