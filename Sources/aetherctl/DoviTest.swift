import Foundation
import AetherEngine

// MARK: - dovitest

/// Validate DoviRpuConverter.convertPacketToProfile81 against dovi_tool ground truth. Walks the HEVC stream, converts DV P7 -> P8.1, writes Annex-B to `outputPath`, by default aetherctl-dovitest.hevc in the per-user private temporary directory (overwritten by the next run).
func runDoviTest(url: URL, outputPath: String? = nil) -> Int32 {
    let outputPath = outputPath ?? debugOutputPath("aetherctl-dovitest.hevc")
    let rpuPath = outputPath.hasSuffix(".hevc")
        ? String(outputPath.dropLast(".hevc".count)) + ".rpu"
        : outputPath + ".rpu"
    print(EngineLog.redacted("aetherctl dovitest: \(url.absoluteString)"))
    print("output: \(outputPath)")
    print("")

    let result: DoviConvertProbeResult
    do {
        result = try AetherEngine.doviConvertProbe(url: url, outputPath: outputPath)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    guard result.videoStreamFound else {
        print("VERDICT: dovitest FAIL: no video stream in source.")
        return 2
    }

    print("=== DOVI CONVERT RESULT ===")
    print("Packets processed:    \(result.packetsProcessed)")
    print("Conversions:          \(result.conversions)")
    print("Failures:             \(result.failures)")
    print("Enhancement layer:    \(result.enhancementLayerType ?? "n/a (not profile 7)")")
    print("Output (Annex-B):     \(result.outputPath)")
    print("===========================")
    print("")

    if result.failures > 0 {
        print("VERDICT: dovitest had \(result.failures) converter failure(s).")
        print("         Validate the surviving RPUs against dovi_tool, then debug:")
        print("           dovi_tool extract-rpu -i \(outputPath) -o \(rpuPath)")
        print("           dovi_tool info -i \(rpuPath) -f 0")
        return 3
    }

    print("VERDICT: converted \(result.conversions) packet(s) to Profile 8.1.")
    print("         Validate against dovi_tool ground truth:")
    print("           dovi_tool extract-rpu -i \(outputPath) -o \(rpuPath)")
    print("           dovi_tool info -i \(rpuPath) -f 0 | grep -iE 'dovi_profile|disable_residual|rpu_data_crc32'")
    return 0
}
