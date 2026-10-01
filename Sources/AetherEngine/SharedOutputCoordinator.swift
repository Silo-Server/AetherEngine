import Foundation

/// The outputs every `AetherEngine` in a process shares, and who is still using them (Sodalite#175).
///
/// The audio session, its channel preference and the panel's display criteria are process-wide, and
/// each engine used to act on them as if it were alone. Measured on an Apple TV with two live tiles:
/// every stop that released the session paused the OTHER engine within 10 ms, picture and all, 4 of 4.
/// Engines join here when a load starts and leave on a final teardown; the decisions below are the
/// ones that need to know whether anybody is left.
@MainActor
final class SharedOutputCoordinator {
    static let shared = SharedOutputCoordinator()

    struct Member: Equatable {
        var role: SharedOutputRole
        var tag: String?
        var sourceChannels: Int?
    }

    enum LeaveOutcome: Equatable, Sendable {
        case notMember
        case othersRemain(Int)
        case lastOut(releaseSession: Bool)
    }

    private var members: [ObjectIdentifier: Member] = [:]
    /// Set by any leaver that asked for the session to be released, paid by the last one out. Without
    /// it, the engine that opted in could leave first and the one that did not would close the round.
    private var releaseOwed = false
    /// Criteria writers that stopped while others still played. Keyed by engine, so one that loads
    /// again drops its own reset instead of having it wipe the criteria it has just written.
    private var deferredCriteriaResets: [ObjectIdentifier: @MainActor () -> Void] = [:]
    private var lastTransition: Task<Void, Never>?

    init() {}

    var isEmpty: Bool { members.isEmpty }

    var preferredSourceChannels: Int? { members.values.compactMap(\.sourceChannels).max() }

    func join(_ id: ObjectIdentifier, role: SharedOutputRole, tag: String?) {
        let channels = members[id]?.sourceChannels
        members[id] = Member(role: role, tag: tag, sourceChannels: channels)
        deferredCriteriaResets[id] = nil
    }

    func noteSourceChannels(_ channels: Int?, for id: ObjectIdentifier) {
        guard members[id] != nil else { return }
        members[id]?.sourceChannels = channels
    }

    func leave(_ id: ObjectIdentifier, releasesSession: Bool) -> LeaveOutcome {
        guard members.removeValue(forKey: id) != nil else { return .notMember }
        if releasesSession { releaseOwed = true }
        guard members.isEmpty else { return .othersRemain(members.count) }
        let release = releaseOwed
        releaseOwed = false
        let resets = deferredCriteriaResets.values
        deferredCriteriaResets.removeAll()
        resets.forEach { $0() }
        return .lastOut(releaseSession: release)
    }

    func othersActive(besides id: ObjectIdentifier) -> Bool {
        members.keys.contains { $0 != id }
    }

    /// Defers a criteria reset to run when the last engine leaves, unless nobody else is playing now.
    /// If `id` is alone or not a member, the reset runs immediately.
    func deferCriteriaReset(for id: ObjectIdentifier, _ body: @escaping @MainActor () -> Void) {
        guard othersActive(besides: id) else { body(); return }
        deferredCriteriaResets[id] = body
    }

    /// One queue for every engine's activation and release. AE#538 ordered them per engine; with two
    /// engines the release of one and the activation of the other had no order between them.
    func enqueueTransition(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = lastTransition
        let transition = Task.detached(priority: .userInitiated) {
            await previous?.value
            await body()
        }
        lastTransition = transition
        return transition
    }

    /// Log label for an engine: its host-given tag, or the identifier's hash when there is none.
    func label(for id: ObjectIdentifier) -> String {
        members[id]?.tag ?? "engine-\(UInt(bitPattern: id.hashValue) % 10_000)"
    }
}
