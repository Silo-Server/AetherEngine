import Testing
import Foundation
@testable import AetherEngine

/// TrueHD Atmos objects are rendered into a speaker bed by the engine, because Apple TV never
/// bitstreams and the receiver only ever sees what tvOS sends it as Dolby MAT. These pin the two
/// properties a renderer cannot get wrong without the room hearing it: an object at a speaker
/// comes out of that speaker alone, and moving an object never changes its loudness.
@Suite("Object audio renders into a speaker bed")
struct SpatialObjectRenderingTests {

    private func power(_ g: [Float]) -> Float { g.reduce(0) { $0 + $1 * $1 } }

    @Test("an object at a speaker's position plays from that speaker alone", arguments: SpatialSpeakerLayout.allCases)
    func objectAtSpeakerIsDiscrete(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        for (channel, speaker) in layout.speakers.enumerated() where !speaker.isLFE {
            panner.pointGains(speaker.position, into: &gains)
            #expect(abs(gains[channel] - 1) < 1e-5, "\(layout.rawValue) \(speaker)")
            #expect(abs(power(gains) - 1) < 1e-5)
        }
    }

    @Test("panning keeps unit power everywhere in the room and never feeds LFE", arguments: SpatialSpeakerLayout.allCases)
    func unitPower(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        let steps: [Float] = [0, 0.13, 0.25, 0.5, 0.61, 0.9, 1]
        for x in steps { for y in steps { for z in steps {
            panner.pointGains(SIMD3(x, y, z), into: &gains)
            #expect(abs(power(gains) - 1) < 1e-4, "\(layout.rawValue) at \(x),\(y),\(z)")
            #expect(gains[layout.lfeIndex] == 0)
        } } }
    }

    @Test("an overhead object in the middle of the room splits evenly across the four tops")
    func overheadCentre() {
        let layout = SpatialSpeakerLayout.l714
        var gains: [Float] = []
        AllocentricPanner(layout: layout).pointGains(SIMD3(0.5, 0.5, 1), into: &gains)
        for (channel, speaker) in layout.speakers.enumerated() {
            #expect(abs(gains[channel] - (speaker.isHeight ? 0.5 : 0)) < 1e-5, "\(speaker)")
        }
    }

    @Test("height content with no ceiling to go to folds onto the floor")
    func heightFoldsWithoutTops() {
        let layout = SpatialSpeakerLayout.l714
        let tops = Set(layout.speakers.filter(\.isHeight))
        var gains: [Float] = []
        AllocentricPanner(layout: layout, excluded: tops).pointGains(SIMD3(0, 0, 1), into: &gains)
        #expect(abs(gains[layout.speakers.firstIndex(of: .left)!] - 1) < 1e-5)
        #expect(abs(power(gains) - 1) < 1e-5)
    }

    @Test("snap routes to the nearest speaker; size spreads with unit power")
    func snapAndSize() {
        let layout = SpatialSpeakerLayout.l916
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        panner.objectGains(position: SIMD3(0.05, 0.3, 0.1), size: 0, snap: true, into: &gains)
        #expect(gains[layout.speakers.firstIndex(of: .wideLeft)!] == 1)
        #expect(abs(power(gains) - 1) < 1e-6)

        panner.objectGains(position: SIMD3(0.5, 0.5, 0.5), size: 0.6, snap: false, into: &gains)
        #expect(abs(power(gains) - 1) < 1e-4)
        #expect(gains.filter { $0 > 0.01 }.count >= 10, "a large object reaches most of the room")
        #expect(gains[layout.lfeIndex] == 0)
    }

    // MARK: - Renderer

    private func render(
        _ renderer: ObjectAudioRenderer, inputs: [[Float]], frames: Int, updates: [ObjectAudioMetadataUpdate]
    ) -> [[Float]] {
        var outputs = [[Float]](repeating: [Float](repeating: 0, count: frames), count: renderer.layout.channelCount)
        let inPtrs = inputs.map { buf -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(from: buf, count: frames)
            return p
        }
        let outPtrs = outputs.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        renderer.render(inputs: inPtrs.map { UnsafePointer($0) }, frameCount: frames, updates: updates, outputs: outPtrs)
        for c in outputs.indices { outputs[c] = Array(UnsafeBufferPointer(start: outPtrs[c], count: frames)) }
        (inPtrs + outPtrs).forEach { $0.deallocate() }
        return outputs
    }

    @Test("bed channels and LFE pass straight through to their speakers")
    func bedPassthrough() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.bed(.left), .lfe, .bed(.topMiddleLeft)])
        let frames = 64
        let a = (0..<frames).map { Float($0) / 64 }
        let b = (0..<frames).map { Float(-$0) / 64 }
        let c = [Float](repeating: 0.25, count: frames)
        let out = render(renderer, inputs: [a, b, c], frames: frames, updates: [])
        #expect(out[layout.speakers.firstIndex(of: .left)!] == a)
        #expect(out[layout.lfeIndex] == b)
        // 7.1.4 has no top-middle pair: the bed's Ltm becomes a phantom between Ltf and Ltr.
        let ltf = out[layout.speakers.firstIndex(of: .topFrontLeft)!]
        let ltr = out[layout.speakers.firstIndex(of: .topRearLeft)!]
        #expect(abs(ltf[0] - 0.25 * cos(Float.pi / 4)) < 1e-5)
        #expect(abs(ltr[0] - 0.25 * cos(Float.pi / 4)) < 1e-5)
    }

    @Test("an object is silent until its first metadata, then follows its ramps")
    func objectRamps() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 100)
        #expect(render(renderer, inputs: [ones], frames: 100, updates: []).allSatisfy { $0.allSatisfy { $0 == 0 } })

        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        var out = render(renderer, inputs: [ones], frames: 100,
                         updates: [.init(frameOffset: 10, rampFrames: 0, states: [left])])
        #expect(out[l][9] == 0 && out[l][10] == 1 && out[r][50] == 0)

        // A 100-frame ramp to the right, split across two blocks: halfway through, the gains are
        // halfway, and the ramp resumes where it left off in the next block.
        out = render(renderer, inputs: [ones], frames: 100,
                     updates: [.init(frameOffset: 50, rampFrames: 100, states: [right])])
        #expect(out[l][49] == 1)
        #expect(abs(out[l][99] - 0.5) < 0.02 && abs(out[r][99] - 0.5) < 0.02)
        out = render(renderer, inputs: [ones], frames: 100, updates: [])
        #expect(abs(out[l][49]) < 1e-5 && abs(out[r][49] - 1) < 1e-5)
        #expect(abs(out[r][99] - 1) < 1e-5)
    }

    @Test("an object's first metadata is a jump even when it asks for a ramp, so nothing fades in after a seek")
    func firstMetadataJumps() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 64)
        let l = layout.speakers.firstIndex(of: .left)!
        var out = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 1536, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        #expect(out[l][0] == 1)
        renderer.reset()
        out = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 1536, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        #expect(out[l][0] == 1, "reset forgets the position, so the next first update jumps again")
    }

    @Test("after a resync an object holds its place and jumps to its next position instead of sweeping there")
    func discontinuityJumps() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 64)
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        _ = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        renderer.markDiscontinuity()
        var out = render(renderer, inputs: [ones], frames: 64, updates: [])
        #expect(out[l][0] == 1, "holds its last position until metadata arrives")
        out = render(renderer, inputs: [ones], frames: 64, updates: [
            .init(frameOffset: 0, rampFrames: 1536, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0))])])
        #expect(out[r][0] == 1 && out[l][0] == 0)
    }

    @Test("an unchanged element in an update keeps its ramp running")
    func unchangedElementKeepsRamp() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object, .object])
        let ones = [Float](repeating: 1, count: 200)
        let r = layout.speakers.firstIndex(of: .right)!
        let left = ObjectAudioElementState(position: SIMD3(0, 0, 0))
        let right = ObjectAudioElementState(position: SIMD3(1, 0, 0))
        let out = render(renderer, inputs: [ones, [Float](repeating: 0, count: 200)], frames: 200, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [left, left]),
            .init(frameOffset: 0, rampFrames: 200, states: [right, nil]),
            // Element 0 restated as unchanged halfway: its ramp must not restart.
            .init(frameOffset: 100, rampFrames: 0, states: [nil, right]),
        ])
        #expect(abs(out[r][149] - 0.75) < 0.02)
        #expect(abs(out[r][199] - 1) < 1e-5)
    }

    @Test("a new target mid-ramp starts from where the ramp had got to")
    func retargetMidRamp() {
        let layout = SpatialSpeakerLayout.l714
        let renderer = ObjectAudioRenderer(layout: layout, roles: [.object])
        let ones = [Float](repeating: 1, count: 200)
        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        let out = render(renderer, inputs: [ones], frames: 200, updates: [
            .init(frameOffset: 0, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))]),
            .init(frameOffset: 0, rampFrames: 100, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0))]),
            .init(frameOffset: 50, rampFrames: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))]),
        ])
        #expect(abs(out[l][49] - 0.51) < 0.02 && out[r][49] > 0.4)
        #expect(out[l][50] == 1 && out[r][50] == 0)
    }
}
