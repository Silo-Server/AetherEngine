import Foundation

/// Decides which caller-supplied headers may be replayed onto a redirected request (#126).
/// Credential headers are replayed only to a trustworthy destination: same host with no
/// TLS downgrade. A cross-host redirect target (presigned object storage, CDN) must not
/// see the media-server token; replaying it both discloses the credential and can break
/// the request outright when the target authenticates via the URL itself and rejects
/// conflicting auth mechanisms with 400. Non-credential headers are replayed
/// unconditionally so header-dependent proxies keep working (#8).
///
/// Headers from `HTTPRequestAuthorization` are different: the engine asks the provider about the
/// source only, so it cannot tell which of the answer's headers are credentials. Every one of them
/// is treated as one, and an untrusted destination gets what it would without a provider.
enum RedirectHeaderPolicy {
    private static let credentialHeaders: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "x-emby-token",
        "x-emby-authorization",
        "x-mediabrowser-token",
    ]

    /// The headers one request chain may carry, split by where they may go. `credentialed` reaches
    /// only a hop the chain's origin may share credentials with; every other hop gets `anonymous`.
    struct Headers: Sendable, Equatable {
        let credentialed: [String: String]
        let anonymous: [String: String]

        private init(credentialed: [String: String], anonymous: [String: String]) {
            self.credentialed = credentialed
            self.anonymous = anonymous
        }

        /// Static headers: all of them to a trusted hop, all but the named credentials elsewhere.
        init(static headers: [String: String]) {
            self.init(credentialed: headers, anonymous: withoutCredentials(headers))
        }

        /// A provider's answer for the source. None of it goes to an untrusted hop, which gets the
        /// static headers that are not credentials instead.
        init(authorized answer: [String: String], static headers: [String: String]) {
            self.init(credentialed: answer, anonymous: withoutCredentials(headers))
        }

        func toReplay(from original: URL?, to destination: URL?) -> [String: String] {
            credentialsAllowed(from: original, to: destination) ? credentialed : anonymous
        }

        /// These headers for a request built against `target` on behalf of `source`. A target the
        /// source's credentials may not reach, such as one pinned from a cross-origin redirect,
        /// carries `anonymous` on its own redirects too.
        func scoped(source: URL, target: URL) -> Headers {
            credentialsAllowed(from: source, to: target)
                ? self : Headers(credentialed: anonymous, anonymous: anonymous)
        }
    }

    static func headersToReplay(
        extraHeaders: [String: String],
        originalURL: URL?,
        redirectURL: URL?
    ) -> [String: String] {
        Headers(static: extraHeaders).toReplay(from: originalURL, to: redirectURL)
    }

    static func withoutCredentials(_ headers: [String: String]) -> [String: String] {
        headers.filter { !credentialHeaders.contains($0.key.lowercased()) }
    }

    /// Builds the request actually handed back to URLSession on redirect: re-applies the
    /// original Range (URLSession drops custom headers on cross-host redirect, and
    /// Range-dependent proxies 400 without it), replays the policy-filtered extra
    /// headers, and scrubs any credential header URLSession itself carried over when
    /// the target is not credential-worthy.
    static func redirectRequest(
        _ request: URLRequest,
        originalURL: URL?,
        originalRange: String?,
        extraHeaders: [String: String]
    ) -> URLRequest {
        redirectRequest(request, originalURL: originalURL, originalRange: originalRange,
                        headers: Headers(static: extraHeaders))
    }

    /// The same, for a chain whose headers are already split. An untrusted hop loses every
    /// `credentialed` header URLSession carried over, not only the named credentials.
    static func redirectRequest(
        _ request: URLRequest,
        originalURL: URL?,
        originalRange: String?,
        headers: Headers
    ) -> URLRequest {
        var updated = request
        if let originalRange {
            updated.setValue(originalRange, forHTTPHeaderField: "Range")
        }
        let trusted = credentialsAllowed(from: originalURL, to: request.url)
        if !trusted {
            for name in credentialHeaders.union(headers.credentialed.keys) {
                updated.setValue(nil, forHTTPHeaderField: name)
            }
        }
        for (name, value) in trusted ? headers.credentialed : headers.anonymous {
            updated.setValue(value, forHTTPHeaderField: name)
        }
        return updated
    }

    /// Same host and no TLS downgrade. Ports may differ only across an http -> https
    /// upgrade (Emby-style 8096 -> 8920); within the same scheme a port change is a
    /// different origin.
    private static func credentialsAllowed(from original: URL?, to redirect: URL?) -> Bool {
        guard let original, let redirect,
              let fromHost = original.host?.lowercased(),
              let toHost = redirect.host?.lowercased(),
              fromHost == toHost,
              let fromScheme = original.scheme?.lowercased(),
              let toScheme = redirect.scheme?.lowercased()
        else { return false }
        if fromScheme == toScheme {
            return effectivePort(original, scheme: fromScheme)
                == effectivePort(redirect, scheme: toScheme)
        }
        return fromScheme == "http" && toScheme == "https"
    }

    private static func effectivePort(_ url: URL, scheme: String) -> Int {
        url.port ?? (scheme == "https" ? 443 : 80)
    }
}
