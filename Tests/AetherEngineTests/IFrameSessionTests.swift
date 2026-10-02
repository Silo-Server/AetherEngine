// Tests/AetherEngineTests/IFrameSessionTests.swift
import Foundation
import Testing
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
}
private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

@Suite("I-frame rendition on a real session", .serialized)
struct IFrameSessionTests {
    private static let fixture = "restart-witness-av.mp4"

    @Test("a flagged VOD session lists the rendition and serves keyframes on the plan's timeline",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func servesRendition() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        let playbackURL = try engine.start()
        defer { engine.stop() }
        try #require(engine.planBoundariesClaimRandomAccess, "fixture must plan on its keyframe index")
        #expect(engine.iFrameRenditionVerdict == .served)
        #expect(playbackURL.lastPathComponent == "master.m3u8")
        let prov = try #require(engine.provider)
        #expect(prov.iFrameRenditionServed)
        try #require(prov.segmentCount >= 2)

        let initSegment = try #require(prov.iFrameInitSegment())
        let timescale = Double(try #require(IFrameTestBoxes.timescale(initSegment: initSegment)))
        // Deliberately out of order: the last entry first.
        for index in [prov.segmentCount - 1, 0, 1] {
            let fragment = try #require(prov.iFrameSegment(at: index))
            #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
            let tfdt = Double(try #require(IFrameTestBoxes.baseDecodeTime(fragment: fragment)))
            #expect(abs(tfdt / timescale - engine.segmentPlan[index].startSeconds) < 0.002,
                    "iframe\(index) sits at \(tfdt / timescale), plan says \(engine.segmentPlan[index].startSeconds)")
        }
        #expect(prov.iFrameSegment(at: prov.segmentCount) == nil)
    }

    @Test("the loopback server answers the three new paths",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func routes() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        let playbackURL = try engine.start()
        defer { engine.stop() }
        let base = playbackURL.deletingLastPathComponent()
        let master = try String(contentsOf: playbackURL, encoding: .utf8)
        #expect(master.contains("#EXT-X-I-FRAME-STREAM-INF:"))
        #expect(master.contains("URI=\"iframe.m3u8\""))
        let playlist = try String(contentsOf: base.appendingPathComponent("iframe.m3u8"), encoding: .utf8)
        #expect(playlist.contains("#EXT-X-I-FRAMES-ONLY"))
        #expect(playlist.contains("iframe1.mp4"))
        let initSegment = try Data(contentsOf: base.appendingPathComponent("iframe_init.mp4"))
        #expect(IFrameTestBoxes.topLevelTypes(initSegment) == ["ftyp", "moov"])
        let fragment = try Data(contentsOf: base.appendingPathComponent("iframe1.mp4"))
        #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
        #expect((try? Data(contentsOf: base.appendingPathComponent("iframe99999.mp4"))) == nil)
    }

    @Test("without the request the session is what it was: no tag, no route, no reader",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func flagOffLeavesMasterUntouched() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.iFrameRenditionVerdict == .absent(.notRequested))
        let prov = try #require(engine.provider)
        #expect(!prov.iFrameRenditionServed)
        #expect(prov.iFrameInitSegment() == nil)
        #expect(prov.iFrameSegment(at: 0) == nil)
        #expect(!HLSLocalServer.buildMasterPlaylistText(provider: prov).contains("I-FRAME"))
    }

    @Test("the fallback to the media playlist takes the rendition down with it",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func fallbackDropsRendition() throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)
        #expect(prov.iFrameSegment(at: 0) != nil)
        engine.markServingMediaAfterFallback()
        #expect(!prov.iFrameRenditionServed)
        #expect(prov.iFrameSegment(at: 0) == nil)
    }

    @Test("stopping while a keyframe request is in flight neither crashes nor hangs",
          .enabled(if: fixtureExists(fixture)), .timeLimit(.minutes(2)))
    func stopWithRenditionInFlightDoesNotCrash() async throws {
        let engine = HLSVideoEngine(url: fixtureURL(Self.fixture), dvModeAvailable: false)
        engine.requestIFramePlaylist()
        _ = try engine.start()
        let prov = try #require(engine.provider)
        let count = prov.segmentCount
        await withTaskGroup(of: Void.self) { group in
            for round in 0..<20 {
                group.addTask { _ = prov.iFrameSegment(at: round % count) }
            }
            group.addTask { engine.stop() }
        }
        #expect(prov.iFrameSegment(at: 0) == nil)
    }

    @Test("a live session is never a candidate, whatever else is true")
    func liveSessionServesNoRendition() {
        let verdict = IFrameRenditionEligibility.candidate(.init(
            requested: true, isLive: true, planBoundariesClaimRandomAccess: true,
            sequentialOrigin: false, heldSourceConnection: false, originIsSerial: false,
            isDiscSource: false, secondReaderAvailable: true))
        #expect(verdict == .absent(.live))
    }
}
