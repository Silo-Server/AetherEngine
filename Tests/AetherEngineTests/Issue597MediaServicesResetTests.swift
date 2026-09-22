import Testing
@testable import AetherEngine

/// AE#597: when mediaserverd resets or is lost, every audio and video object the process holds is
/// invalid and has to be rebuilt. The engine keeps its `AVPlayer` across a load on purpose
/// (Sodalite#149: a preserved host keeps the Now Playing registration alive), which after a reset
/// means reusing the one object the platform has already invalidated, on every recovery rung.
///
/// The rule this pins is the narrow one: a reset outranks every reason to keep the host.
@Suite("A media services reset outranks host preservation (#597)")
struct Issue597MediaServicesResetTests {

    @Test("without a reset the preservation rule is unchanged")
    func preservationIsUnchangedWithoutAReset() {
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .native, nativeHostSurvives: false, mediaServicesWereReset: false))
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .software, nativeHostSurvives: true, mediaServicesWereReset: false))
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .software, nativeHostSurvives: false, mediaServicesWereReset: false))
    }

    @Test("a reset forbids preserving the host whatever else argues for it")
    func resetForbidsPreservation() {
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .native, nativeHostSurvives: true, mediaServicesWereReset: true))
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .native, nativeHostSurvives: false, mediaServicesWereReset: true))
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .software, nativeHostSurvives: true, mediaServicesWereReset: true))
    }
}
