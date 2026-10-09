# Security Policy

## Supported versions

AetherEngine ships fixes on the latest released minor line. Security fixes land there first; older lines are not back-patched. Host apps pin the engine by commit SHA, so picking up a fix means bumping the pin to the patched release.

| Version | Supported |
| ------- | --------- |
| The minor line of the [latest release](https://github.com/superuser404notfound/AetherEngine/releases/latest) | :white_check_mark: |
| Every earlier minor line | :x: |

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue or pull request.

Use GitHub's private reporting: [Security → Report a vulnerability](https://github.com/superuser404notfound/AetherEngine/security/advisories/new). That opens a private advisory visible only to you and the maintainers.

Helpful things to include:

- The affected version or commit SHA, and the platform (tvOS / iOS / macOS).
- A description of the issue and its impact.
- Steps or a proof of concept that reproduce it. For a malformed-media issue, a sample file or `ffprobe` output is ideal.

You can expect an initial acknowledgement within a few days. Once a fix is ready it ships in a new release and the advisory is published with credit, unless you prefer to remain anonymous.

## Scope

AetherEngine plays media from servers and local sources and parses untrusted container and codec data. Areas most relevant to security:

- **Media parsing.** Demuxing and decoding of untrusted containers and bitstreams (the FFmpeg / dav1d surface).
- **Network handling.** The engine's HTTP range reading and its local HTTP server used to bridge sources into AVPlayer. The server listens on all interfaces, not only loopback, so that an AirPlay receiver can fetch the stream over the LAN, on an ephemeral port and for the current stream only. Every path it answers starts with a per-session 128-bit random token, and a request without it is answered 404 before it reaches any route. A peer that is not loopback may hold at most 24 of the server's 32 connection slots (the rest stay free for the local player), and a connection that has not presented the token has 10 seconds from accept to deliver a whole request head. The token is also kept out of the diagnostic log. Beyond that listener nothing is exposed off the device, and there is no external analytics or session reporting.
- **Memory safety.** Crashes or out-of-bounds behavior triggered by crafted input.

Out of scope: vulnerabilities in a host app's own UI or networking (report those on the host app's tracker), and issues in upstream FFmpeg / dav1d themselves (report those upstream, though we are glad to know if a bundled build is affected).
