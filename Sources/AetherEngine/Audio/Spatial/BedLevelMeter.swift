import Accelerate
import Foundation

/// Per-channel levels of the rendered bed, for the session log.
///
/// A report that the heights or the LFE are missing can only be placed if the log says what the
/// engine handed AVPlayer. Level here means the encoder was given that channel's sound, so a height
/// heard from the floor speakers lost it after this point. Silence here is a lead, not a verdict: the
/// object counts come from the metadata (gain and position), and an elevated object can still be
/// silent or snap to a floor speaker.
///
/// Measured on the planes the encoder is fed, gap-fill silence included, because that is what was
/// sent. The first window after a start or a seek closes after `firstWindowSeconds`, so a short test
/// session still logs one; later windows close every `windowSeconds`. Channels are named with
/// CoreAudio's labels, as on the route line.
struct BedLevelMeter {

    static let firstWindowSeconds = 5
    static let windowSeconds = 30

    private static let heightSpeakers = Set(SpatialSpeaker.allCases.filter(\.isHeight))

    let layout: SpatialSpeakerLayout
    let sampleRate: Int

    private var sumSquares: [Double]
    private var peaks: [Float]
    private var frames = 0
    private var windowsClosed = 0
    /// Where the window's first frame sits on the output timeline, in seconds, when the caller knows.
    private var windowStart: Double?

    /// Latest metadata per element, since an update restates only the elements that changed.
    private var elementStates: [ObjectAudioElementState?] = []
    /// Object counts as of the latest update, which hold until the next one: a window with no update
    /// at all still reports what is playing.
    private var activeObjects = 0
    private var elevatedObjects = 0
    private var maxActiveObjects = 0
    private var maxElevatedObjects = 0

    init(layout: SpatialSpeakerLayout, sampleRate: Int) {
        self.layout = layout
        self.sampleRate = sampleRate
        sumSquares = Array(repeating: 0, count: layout.channelCount)
        peaks = Array(repeating: 0, count: layout.channelCount)
    }

    /// Count the objects the metadata has playing, and how many of them sit above ear level with
    /// elevation allowed. A new object configuration forgets the old elements' states; its first
    /// update restates every element.
    mutating func observe(roles: [ObjectAudioRole], updates: [ObjectAudioMetadataUpdate],
                          configurationChanged: Bool = false) {
        if configurationChanged || elementStates.count != roles.count {
            elementStates = Array(repeating: nil, count: roles.count)
        }
        for update in updates {
            for (index, state) in update.states.enumerated() where index < elementStates.count {
                if let state { elementStates[index] = state }
            }
            activeObjects = 0
            elevatedObjects = 0
            for (index, role) in roles.enumerated() where role == .object {
                guard let state = elementStates[index], state.gain > 0 else { continue }
                activeObjects += 1
                if state.position.z > 0, !Self.heightSpeakers.isSubset(of: state.excluded) { elevatedObjects += 1 }
            }
            maxActiveObjects = max(maxActiveObjects, activeObjects)
            maxElevatedObjects = max(maxElevatedObjects, elevatedObjects)
        }
    }

    /// Measure `frameCount` frames of the bed (one plane per layout channel) starting at `startSeconds`
    /// on the output timeline. Returns the log line when this closes a window.
    mutating func add(_ planes: [UnsafePointer<Float>], frameCount: Int, startSeconds: Double? = nil) -> String? {
        guard frameCount > 0 else { return nil }
        if frames == 0 { windowStart = startSeconds }
        let n = vDSP_Length(frameCount)
        for c in 0..<min(planes.count, sumSquares.count) {
            var squares: Float = 0
            vDSP_svesq(planes[c], 1, &squares, n)
            sumSquares[c] += Double(squares)
            var peak: Float = 0
            vDSP_maxmgv(planes[c], 1, &peak, n)
            peaks[c] = max(peaks[c], peak)
        }
        frames += frameCount
        let due = (windowsClosed == 0 ? Self.firstWindowSeconds : Self.windowSeconds) * sampleRate
        return frames >= due ? closeWindow() : nil
    }

    /// The open window, if it holds at least a second, for a seek, end of stream or teardown. The
    /// next window is a first window again, and the objects start over with the next update.
    mutating func restart() -> String? {
        let line = frames >= sampleRate ? closeWindow() : nil
        elementStates = []
        activeObjects = 0
        elevatedObjects = 0
        clearWindow()
        windowsClosed = 0
        return line
    }

    /// `bed levels 7.1.4 at 3725.4 s over 30.0 s, rms/peak dBFS: L -22.4/-3.1, …; objects: up to 12
    /// active, 5 elevated`
    private mutating func closeWindow() -> String {
        let channels = layout.speakers.enumerated().map { c, speaker in
            let rms = (sumSquares[c] / Double(max(frames, 1))).squareRoot()
            return "\(AudioRouteDescription.labelName(speaker.channelLabel)) "
                + "\(Self.dBFS(rms))/\(Self.dBFS(Double(peaks[c])))"
        }
        let at = windowStart.map { String(format: " at %.1f s", $0) } ?? ""
        let seconds = String(format: "%.1f", Double(frames) / Double(sampleRate))
        let line = "bed levels \(layout.rawValue)\(at) over \(seconds) s, rms/peak dBFS: "
            + channels.joined(separator: ", ")
            + "; objects: up to \(maxActiveObjects) active, \(maxElevatedObjects) elevated"
        windowsClosed += 1
        clearWindow()
        return line
    }

    private mutating func clearWindow() {
        for c in sumSquares.indices { sumSquares[c] = 0; peaks[c] = 0 }
        frames = 0
        windowStart = nil
        maxActiveObjects = activeObjects
        maxElevatedObjects = elevatedObjects
    }

    static func dBFS(_ amplitude: Double) -> String {
        amplitude > 0 ? String(format: "%.1f", 20 * log10(amplitude)) : "-inf"
    }
}
