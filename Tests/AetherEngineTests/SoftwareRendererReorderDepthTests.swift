import Foundation
import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import AetherEngine

/// Audit PERF-104: the software renderer held four frames for every decoder, which is 75 MB of
/// IOSurface at 4K P010 that libavcodec and dav1d (presentation order) never needed. Only the
/// VideoToolbox HEVC decoder emits B-frames out of order. The depth follows the decoder, and a frame
/// that arrives after a later one was handed over is dropped and raises the depth instead of reaching
/// the layer out of order.
@Suite("Software renderer reorder depth")
struct SoftwareRendererReorderDepthTests {

    private final class Handed: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        var seconds: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ t: SoftwareVideoFrameTime) { lock.lock(); storage.append(t.presentation.seconds); lock.unlock() }
    }

    private static func makePixelBuffer(width: Int = 16, height: Int = 16,
                                        format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    private static func time(_ ticks: Int) -> CMTime { CMTime(value: Int64(ticks), timescale: 1000) }

    @MainActor
    private func feed(_ renderer: SampleBufferRenderer, _ ticks: [Int], drain: Bool = true) -> Handed {
        let handed = Handed()
        renderer.setFrameEnqueuedObserver { handed.append($0) }
        let pixels = Self.makePixelBuffer()
        for t in ticks { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        if drain { renderer.drainReorderBuffer() }
        return handed
    }

    @Test("The depth follows the decoder: VideoToolbox keeps four, the presentation-order decoders hold one")
    func depthPerDecoder() {
        #expect(SampleBufferRenderer.reorderDepth(forHardwareDecoder: true) == 4)
        #expect(SampleBufferRenderer.reorderDepth(forHardwareDecoder: false) == 1)
    }

    @Test("In-order input at depth one is handed over with one frame of latency")
    @MainActor
    func inOrderInputHoldsOneFrame() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(forHardwareDecoder: false))
        let handed = Handed()
        renderer.setFrameEnqueuedObserver { handed.append($0) }
        let pixels = Self.makePixelBuffer()
        for (i, t) in stride(from: 0, to: 400, by: 40).enumerated() {
            renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t))
            #expect(handed.seconds.count == i, "frame \(i) waits for its successor and nothing more")
            #expect(renderer.heldFrameCount == min(i + 1, 1))
        }
        renderer.drainReorderBuffer()
        #expect(handed.seconds == stride(from: 0, to: 400, by: 40).map { Double($0) / 1000 })
        #expect(renderer.outOfOrderFramesDropped == 0)
    }

    @Test("A renderer nobody configured keeps holding four frames and sorts a B pyramid")
    @MainActor
    func defaultDepthStillSortsABPyramid() {
        let renderer = SampleBufferRenderer()
        // Decode order I0 P4 B2 b1 b3, two pyramids.
        let handed = feed(renderer, [0, 160, 80, 40, 120, 320, 240, 200, 280])
        #expect(handed.seconds == [0, 40, 80, 120, 160, 200, 240, 280, 320].map { Double($0) / 1000 })
        #expect(renderer.outOfOrderFramesDropped == 0)
    }

    @Test("A VideoToolbox-configured renderer sorts a three deep B pyramid")
    @MainActor
    func hardwareDepthSortsAThreeDeepPyramid() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(forHardwareDecoder: true))
        // Decode order: I0 P4 B2 b1 b3, each gap one frame.
        let handed = feed(renderer, [0, 4, 2, 1, 3, 8, 6, 5, 7].map { $0 * 40 })
        #expect(handed.seconds == (0...8).map { Double($0 * 40) / 1000 })
        #expect(renderer.outOfOrderFramesDropped == 0)
    }

    @Test("At depth one one local inversion is still sorted")
    @MainActor
    func depthOneSortsASingleInversion() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(1)
        let handed = feed(renderer, [30, 10, 20])
        #expect(handed.seconds == [0.010, 0.020, 0.030])
        #expect(renderer.outOfOrderFramesDropped == 0)
    }

    @Test("A frame behind one already handed over is dropped once, counted, and raises the depth")
    @MainActor
    func outOfOrderFrameIsDroppedAndDepthRises() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(1)
        let handed = Handed()
        renderer.setFrameEnqueuedObserver { handed.append($0) }
        let pixels = Self.makePixelBuffer()
        // 0 4 2 1 3 at depth one: 0 and 2 are handed over, 1 then arrives behind 2.
        for t in [0, 4, 2, 1, 3] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t * 40)) }
        #expect(renderer.outOfOrderFramesDropped == 1)
        #expect(renderer.takeCadence().lostBeforeLayer == 1)
        renderer.drainReorderBuffer()
        #expect(handed.seconds == [0, 0.080, 0.120, 0.160], "the late frame never reached the layer")

        // The depth is now the hardware one: the same shape is sorted rather than dropped.
        for t in [10, 14, 12, 11, 13].map({ $0 * 40 }) { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        renderer.drainReorderBuffer()
        #expect(handed.seconds.suffix(5) == [0.400, 0.440, 0.480, 0.520, 0.560])
        #expect(renderer.outOfOrderFramesDropped == 1)
        #expect(zip(handed.seconds, handed.seconds.dropFirst()).allSatisfy { $0 <= $1 },
                "everything the layer was handed is in ascending order")
    }

    @Test("The guard also keeps an out of order frame off the layer at the hardware depth")
    @MainActor
    func guardAppliesAtTheHardwareDepthToo() {
        let renderer = SampleBufferRenderer()
        let handed = Handed()
        renderer.setFrameEnqueuedObserver { handed.append($0) }
        let pixels = Self.makePixelBuffer()
        for t in [100, 200, 300, 400, 500, 600] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        // 100 and 200 are out by now; 150 is five frames late.
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(150))
        renderer.drainReorderBuffer()
        #expect(renderer.outOfOrderFramesDropped == 1)
        #expect(handed.seconds == [0.100, 0.200, 0.300, 0.400, 0.500, 0.600])
    }

    /// Stands in for a second enqueuer (a drain, another decoder thread). The frame-enqueued observer
    /// runs with no lock held, after a frame reached the layer and before the renderer would have
    /// recorded it, which is exactly the window a real second thread lands in.
    private final class SecondEnqueuer: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = true
        var renderer: SampleBufferRenderer?
        let pixels: CVPixelBuffer
        let trigger: Double
        let lateTicks: Int
        init(pixels: CVPixelBuffer, trigger: Double, lateTicks: Int) {
            self.pixels = pixels
            self.trigger = trigger
            self.lateTicks = lateTicks
        }
        func frameReachedTheLayer(_ t: SoftwareVideoFrameTime) {
            lock.lock()
            let fire = armed && abs(t.presentation.seconds - trigger) < 1e-9
            if fire { armed = false }
            lock.unlock()
            if fire { renderer?.enqueue(pixelBuffer: pixels, pts: SoftwareRendererReorderDepthTests.time(lateTicks)) }
        }
    }

    @Test("A frame that arrives while another is on its way to the layer is judged against that frame")
    @MainActor
    func guardCoversAFrameInFlight() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(1)
        let handed = Handed()
        let second = SecondEnqueuer(pixels: Self.makePixelBuffer(), trigger: 0.040, lateTicks: 20)
        second.renderer = renderer
        renderer.setFrameEnqueuedObserver { t in
            handed.append(t)
            second.frameReachedTheLayer(t)
        }
        let pixels = Self.makePixelBuffer()
        // The frame at 40 ms leaves the buffer when 80 ms arrives. While it is on its way the second
        // enqueuer offers 20 ms, which is already behind it.
        for t in [0, 40, 80, 120] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        renderer.drainReorderBuffer()
        second.renderer = nil
        renderer.setFrameEnqueuedObserver(nil)

        #expect(renderer.outOfOrderFramesDropped == 1)
        #expect(handed.seconds == [0, 0.040, 0.080, 0.120], "the late frame never reached the layer")
    }

    @Test("A flush while a frame is on its way does not leave the guard standing for the new timeline")
    @MainActor
    func flushDuringHandoverDoesNotPoisonTheGuard() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(1)
        let handed = Handed()
        let pixels = Self.makePixelBuffer()
        // A seek lands (flush) while the frame at 5040 is being handed over.
        renderer.setFrameEnqueuedObserver { t in
            handed.append(t)
            if abs(t.presentation.seconds - 5.040) < 1e-9 { renderer.flush(removingDisplayedImage: false) }
        }
        for t in [5000, 5040, 5080] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        for t in [1000, 1040, 1080] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        renderer.drainReorderBuffer()
        renderer.setFrameEnqueuedObserver(nil)
        #expect(renderer.outOfOrderFramesDropped == 0, "the seek backwards is not out of order")
        #expect(handed.seconds == [5.000, 5.040, 1.000, 1.040, 1.080], "and the frames after it reach the layer")
    }

    @Test("A flush forgets what was handed over, so a seek backwards is not out of order")
    @MainActor
    func flushResetsTheGuard() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(1)
        let pixels = Self.makePixelBuffer()
        for t in [5000, 5040, 5080] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        renderer.flush(removingDisplayedImage: false)
        for t in [1000, 1040, 1080] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(t)) }
        renderer.drainReorderBuffer()
        #expect(renderer.outOfOrderFramesDropped == 0)
    }

    @Test("Three fewer held frames at 4K P010 is 75 MB of IOSurface")
    @MainActor
    func heldMemoryAtFourK() throws {
        let frame = Self.makePixelBuffer(width: 3840, height: 2160,
                                         format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let bytes = CVPixelBufferGetDataSize(frame)
        #expect(bytes > 24_000_000, "a 4K P010 frame is ~25 MB")

        func steadyStateHeld(depth: Int) -> Int {
            let renderer = SampleBufferRenderer()
            renderer.setReorderDepth(depth)
            let small = Self.makePixelBuffer()
            for i in 0..<12 { renderer.enqueue(pixelBuffer: small, pts: Self.time(i * 40)) }
            return renderer.heldFrameCount
        }
        let before = steadyStateHeld(depth: SampleBufferRenderer.reorderDepth(forHardwareDecoder: true))
        let after = steadyStateHeld(depth: SampleBufferRenderer.reorderDepth(forHardwareDecoder: false))
        #expect(before == 4)
        #expect(after == 1)
        #expect((before - after) * bytes > 70_000_000)
    }
}
