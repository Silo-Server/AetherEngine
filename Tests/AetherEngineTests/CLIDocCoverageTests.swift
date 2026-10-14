import Testing
import Foundation

/// `docs/cli.md` is the only place a flag of `aetherctl` is explained, and three of them (`--assert-dv`,
/// `--max-concurrent-requests`, `--no-blocking-reload`) lived in the parser for a long time before
/// anyone noticed the page never mentioned them (audit OPS-111). Every quoted `"--flag"` literal in
/// `Sources/aetherctl` is a flag the CLI accepts, so each one has to appear in the page.
///
/// aetherctl is an executable target that no test target can link, so this reads the sources as text.
@Suite("aetherctl flags are documented")
struct CLIDocCoverageTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static var checkoutPresent: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/cli.md").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/aetherctl").path)
    }

    /// `--help` is the one literal that is a command, not a flag of a subcommand, and the usage text
    /// already documents it.
    private static let notFlags: Set<String> = ["--help"]

    @Test("every --flag literal in aetherctl appears in docs/cli.md",
          .enabled(if: CLIDocCoverageTests.checkoutPresent, "needs a source checkout"))
    func everyFlagIsDocumented() throws {
        let sourcesDir = Self.root.appendingPathComponent("Sources/aetherctl")
        let files = try FileManager.default.contentsOfDirectory(atPath: sourcesDir.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)

        let literal = try NSRegularExpression(pattern: #""(--[a-z0-9][a-z0-9-]*)""#)
        var flags = Set<String>()
        for file in files {
            let text = try String(contentsOf: sourcesDir.appendingPathComponent(file), encoding: .utf8)
            let whole = NSRange(text.startIndex..., in: text)
            for match in literal.matches(in: text, range: whole) {
                if let range = Range(match.range(at: 1), in: text) { flags.insert(String(text[range])) }
            }
        }
        // A parser that stopped matching would pass vacuously.
        #expect(flags.count > 50, "found only \(flags.count) flag literals, the pattern has drifted")

        let doc = try String(contentsOf: Self.root.appendingPathComponent("docs/cli.md"), encoding: .utf8)
        let missing = flags.subtracting(Self.notFlags).filter { !Self.mentions(doc, flag: $0) }.sorted()
        #expect(missing.isEmpty, "docs/cli.md does not mention: \(missing.joined(separator: ", "))")
    }

    /// A whole-flag match, so `--sw` is not satisfied by `--sweep` or `--sw-escalation`.
    private static func mentions(_ doc: String, flag: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        guard let pattern = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9-])\(escaped)(?![A-Za-z0-9-])")
        else { return false }
        return pattern.firstMatch(in: doc, range: NSRange(doc.startIndex..., in: doc)) != nil
    }
}
