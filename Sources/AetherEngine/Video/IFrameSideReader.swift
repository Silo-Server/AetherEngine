// Sources/AetherEngine/Video/IFrameSideReader.swift
import Foundation
import AetherLibavcodec

/// AE#682: reads the keyframe that opens a plan segment, on a demuxer of its own. Only the bytes
/// are used; the fragment is stamped from the plan, so this demuxer's timestamp ladder (DTS on mp4,
/// PTS on Matroska, the #409 shift) never has to agree with the session's.
final class IFrameSideReader: @unchecked Sendable {
    private let openDemuxer: () throws -> Demuxer
    private let convertP7ToProfile81: Bool
    private let nalFraming: VideoNALFraming
    private let readDeadlineSeconds: TimeInterval

    private let lock = NSLock()
    private var demuxer: Demuxer?
    private var videoIndex: Int32 = -1
    private var openFailed = false
    private var interrupted = false

    /// A keyframe sits at the seek target or right behind it; this bounds a source that claims an
    /// index entry no keyframe backs.
    private static let maxPacketsPerRead = 256

    init(openDemuxer: @escaping () throws -> Demuxer,
         convertP7ToProfile81: Bool = false,
         nalFraming: VideoNALFraming = .lengthPrefixed(size: 4),
         readDeadlineSeconds: TimeInterval = 8) {
        self.openDemuxer = openDemuxer
        self.convertP7ToProfile81 = convertP7ToProfile81
        self.nalFraming = nalFraming
        self.readDeadlineSeconds = readDeadlineSeconds
    }

    private func readyDemuxer() -> Demuxer? {
        lock.lock()
        if interrupted || openFailed { lock.unlock(); return nil }
        if let demuxer { lock.unlock(); return demuxer }
        lock.unlock()

        let started = DispatchTime.now()
        let opened: Demuxer
        do {
            opened = try openDemuxer()
        } catch {
            lock.lock(); openFailed = true; lock.unlock()
            EngineLog.emit("[IFrameSideReader] open failed: \(error)", category: .session)
            return nil
        }
        let index = opened.videoStreamIndex
        guard index >= 0 else {
            opened.close()
            lock.lock(); openFailed = true; lock.unlock()
            EngineLog.emit("[IFrameSideReader] open failed: no video stream", category: .session)
            return nil
        }
        opened.discardAllStreamsExcept([index])
        lock.lock()
        if interrupted {
            lock.unlock()
            opened.close()
            return nil
        }
        demuxer = opened
        videoIndex = index
        lock.unlock()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[IFrameSideReader] opened in \(String(format: "%.0f", ms))ms", category: .session)
        return opened
    }

    func payload(startPts: Int64) -> Data? {
        guard let dem = readyDemuxer() else { return nil }
        dem.beginReadDeadline(secondsFromNow: readDeadlineSeconds)
        defer { dem.endReadDeadline() }
        if dem.isDiscSource || !dem.seek(to: startPts, streamIndex: videoIndex) {
            guard let stream = dem.stream(at: videoIndex) else { return nil }
            let tb = stream.pointee.time_base
            guard tb.den > 0, dem.seek(to: Double(startPts) * Double(tb.num) / Double(tb.den)) else {
                return nil
            }
        }
        for _ in 0..<Self.maxPacketsPerRead {
            lock.lock(); let stop = interrupted; lock.unlock()
            if stop { return nil }
            guard let packet = try? dem.readPacket() else { return nil }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            guard packet.pointee.stream_index == videoIndex,
                  (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 else { continue }
            if convertP7ToProfile81 {
                _ = DoviRpuConverter.convertPacketToProfile81(packet, framing: nalFraming)
            }
            guard let bytes = packet.pointee.data, packet.pointee.size > 0 else { return nil }
            return Data(bytes: bytes, count: Int(packet.pointee.size))
        }
        return nil
    }

    func interrupt() {
        lock.lock()
        interrupted = true
        let dem = demuxer
        lock.unlock()
        dem?.markClosed()
    }

    func close() {
        lock.lock()
        let dem = demuxer
        demuxer = nil
        lock.unlock()
        dem?.close()
    }
}
