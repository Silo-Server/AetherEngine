import Testing
@testable import AetherEngine

/// Audit NAT-104: `selectInjectedSubtitleRendition` took the first option whose playlist NAME or
/// localized display name equalled the sidecar's served NAME. AVFoundation derives the display name from
/// LANGUAGE, so the origin's own "English CC" rendition reads back as "English" and, sitting ahead of the
/// injected ones in the served master, won over the sidecar actually asked for.
@Suite("Injected rendition selection (NAT-104)")
struct InjectedRenditionSelectionTests {

    private func option(display: String, playlistName: String?) -> RemoteHLSMediaSelection.LegibleOption {
        RemoteHLSMediaSelection.LegibleOption(
            displayName: display, extendedLanguageTag: "en",
            isDefault: false, isForced: false, isSDH: false, playlistName: playlistName)
    }

    @Test("an origin rendition whose localized display name equals the sidecar's NAME does not win")
    func originDisplayNameDoesNotShadowTheInjectedRendition() {
        let group = [
            option(display: "English", playlistName: "English CC"),   // origin, NAME="English CC"
            option(display: "English", playlistName: "English"),      // injected sidecar
        ]
        #expect(RemoteHLSMediaSelection.injectedRenditionIndex(named: "English", in: group) == 1)
    }

    @Test("a rendition is found by its playlist NAME when the display name differs")
    func matchesByPlaylistName() {
        let group = [option(display: "Chinese", playlistName: "简体中文")]
        #expect(RemoteHLSMediaSelection.injectedRenditionIndex(named: "简体中文", in: group) == 0)
    }

    @Test("an OS that exposes no m3u8/NAME falls back to the display name")
    func fallsBackToDisplayName() {
        let group = [option(display: "German", playlistName: nil)]
        #expect(RemoteHLSMediaSelection.injectedRenditionIndex(named: "German", in: group) == 0)
    }

    @Test("a name that no option carries is a miss")
    func missIsNil() {
        let group = [option(display: "English", playlistName: "English CC")]
        #expect(RemoteHLSMediaSelection.injectedRenditionIndex(named: "English", in: group) == nil)
        #expect(RemoteHLSMediaSelection.injectedRenditionIndex(named: "English", in: []) == nil)
    }
}
