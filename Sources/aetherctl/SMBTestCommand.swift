import Foundation
import AetherEngineSMB

// MARK: - smbtest: sequential throughput + random-seek correctness harness

@MainActor
private func smbTestRun(_ args: [String]) async -> Int32 {
    guard let rawURL = args.first(where: { !$0.hasPrefix("--") }) else {
        FileHandle.standardError.write(Data("usage: aetherctl smbtest <smb-url> [--reads N]\n".utf8))
        return 2
    }
    let randomReads = smbParseIntFlag(args, "--reads") ?? 64

    do {
        let u = try SMBURL.parse(rawURL)
        let started = ProcessInfo.processInfo.systemUptime
        print("connecting to \(u.server.absoluteString) share=\(u.share) path=\(u.path) user=\(u.user.isEmpty ? "(guest/anonymous)" : u.user)")
        let connection = try await SMBConnection.connect(
            server: u.server, share: u.share, path: u.path,
            user: u.user, password: u.password
        )
        let reader = SMBIOReader(source: connection)
        let total = reader.seek(offset: 0, whence: 65536) // AVSEEK_SIZE
        print("connected: \(u.path) size=\(total) bytes")

        // The random-seek offsets are drawn first so the sequential pass can record the bytes that
        // belong at each of them: the seeked reads are then compared against what the file holds, not
        // against a second read of the same path (audit OPS-105).
        struct Probe { let offset: Int64; let length: Int; var reference: [UInt8] }
        var rng = SystemRandomNumberGenerator()
        var probes: [Probe] = []
        if total > 0 {
            for _ in 0..<randomReads {
                let off = Int64.random(in: 0..<max(1, total - 16), using: &rng)
                let length = Int(min(16, total - off))
                probes.append(Probe(offset: off, length: length, reference: [UInt8](repeating: 0, count: length)))
            }
        }

        // Probe indices by offset, walked with a cursor, so the timed pass below visits only the probes
        // near each chunk instead of every probe per chunk. `probes` keeps its random order for the
        // seek pass.
        let byOffset = probes.indices.sorted { probes[$0].offset < probes[$1].offset }
        var cursor = 0

        let chunk = 1 << 20 // 1 MiB sequential read
        var buf = [UInt8](repeating: 0, count: chunk)
        var readBytes: Int64 = 0
        _ = reader.seek(offset: 0, whence: Int32(SEEK_SET))
        let seqStart = ProcessInfo.processInfo.systemUptime
        while true {
            let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(chunk)) }
            if n <= 0 { break }
            let chunkEnd = readBytes + Int64(n)
            // Skip probes that ended before this chunk; one that crosses into it stays for its tail.
            while cursor < byOffset.count {
                let probe = probes[byOffset[cursor]]
                guard probe.offset + Int64(probe.length) <= readBytes else { break }
                cursor += 1
            }
            for i in byOffset[cursor...] {
                if probes[i].offset >= chunkEnd { break }
                let lo = max(probes[i].offset, readBytes)
                let hi = min(probes[i].offset + Int64(probes[i].length), chunkEnd)
                guard lo < hi else { continue }
                for position in lo..<hi {
                    probes[i].reference[Int(position - probes[i].offset)] = buf[Int(position - readBytes)]
                }
            }
            readBytes = chunkEnd
        }
        let seqElapsed = ProcessInfo.processInfo.systemUptime - seqStart
        let mibps = seqElapsed > 0 ? Double(readBytes) / 1_048_576.0 / seqElapsed : 0
        print(String(format: "sequential: %lld bytes in %.2fs = %.1f MiB/s", readBytes, seqElapsed, mibps))

        guard readBytes == total else {
            print("FAIL: sequential read \(readBytes) != size \(total)")
            return 1
        }

        // Random-seek correctness: each seeked read must come back whole and equal to the bytes the
        // sequential pass saw at that offset. A failed read is 0 or -1 bytes, which used to compare
        // equal to another failed read.
        for probe in probes {
            for attempt in 1...2 {
                let got = smbReadAt(reader, probe.offset, probe.length)
                guard got.count == probe.length else {
                    print("FAIL: random read \(attempt) at \(probe.offset) returned \(got.count) of \(probe.length) bytes")
                    return 1
                }
                guard [UInt8](got) == probe.reference else {
                    print("FAIL: random read \(attempt) at \(probe.offset) differs from the sequential pass")
                    return 1
                }
            }
        }
        print("random-seek: \(probes.count) offsets match the sequential pass")

        reader.close()
        let wall = ProcessInfo.processInfo.systemUptime - started
        print(String(format: "OK in %.2fs", wall))
        return 0
    } catch {
        FileHandle.standardError.write(Data("smbtest error: \(error)\n".utf8))
        return 1
    }
}

/// Reads until `length` bytes arrived, so a legitimate short read is not taken for a failure; a read that
/// returns 0 (EOF) or -1 (error) ends it short, and the caller sees the shortfall.
private func smbReadAt(_ reader: SMBIOReader, _ offset: Int64, _ length: Int) -> Data {
    _ = reader.seek(offset: offset, whence: Int32(SEEK_SET))
    var out = Data()
    var buf = [UInt8](repeating: 0, count: length)
    while out.count < length {
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(length - out.count)) }
        if n <= 0 { break }
        out.append(contentsOf: buf.prefix(Int(n)))
    }
    return out
}

private func smbParseIntFlag(_ args: [String], _ flag: String) -> Int? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return Int(args[i + 1])
}

func runSMBTest(_ args: [String]) -> Int32 {
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await smbTestRun(args)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}
