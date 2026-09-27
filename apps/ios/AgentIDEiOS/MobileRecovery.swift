import AgentIDEProtocol
import Foundation

struct MobileRecoveryCache: Codable {
    var projects: [RemoteProject]
    var sessions: [String: [Session]]
    var sessionEvents: [String: [AgentEvent]]
    var pendingInteractions: [String: [AgentEvent]]? = nil
    var sessionProjects: [String: String]
    var workspaceNavigations: [String: WorkspaceNavigationState]?
    var fileBrowserNavigations: [String: FileBrowserRecoveryState]?
    var sessionDrafts: [String: String]? = nil
    var submittedInteractions: [String]?
    var resolvedInteractions: [String]?

    func trimmedForPersistence(activeSessionId: String?) -> MobileRecoveryCache {
        var cache = self
        let sessionsById = cache.sessions.values.flatMap { $0 }.reduce(into: [String: Session]()) { result, session in
            if let existing = result[session.id], existing.updatedAt >= session.updatedAt { return }
            result[session.id] = session
        }
        let activeProjectId = activeSessionId.flatMap { sessionId in
            cache.sessionProjects[sessionId] ?? sessionsById[sessionId]?.projectId
        }
        var orderedProjectIds = cache.projects.map(\.id)
        orderedProjectIds.append(contentsOf: cache.sessions.keys.sorted())
        orderedProjectIds.append(contentsOf: cache.sessionProjects.values.sorted())
        var seenProjectIds = Set<String>()
        var retainedProjectIds = MobileRecoveryRetention.retaining(
            orderedProjectIds.filter { seenProjectIds.insert($0).inserted },
            limit: MobileRecoveryLimits.projectCount,
            protectedId: activeProjectId
        )
        let pendingSessionIds = Set((cache.pendingInteractions ?? [:]).compactMap { $0.value.isEmpty ? nil : $0.key })
        retainedProjectIds.formUnion(pendingSessionIds.compactMap { cache.sessionProjects[$0] ?? sessionsById[$0]?.projectId })
        cache.projects = cache.projects.filter { retainedProjectIds.contains($0.id) }
        let listedSessionIdsBeforeTrim = Set(cache.sessions.values.flatMap { $0.map(\.id) })
        cache.sessions = cache.sessions.reduce(into: [:]) { result, item in
            guard retainedProjectIds.contains(item.key) else { return }
            let ordered = item.value.sorted { $0.updatedAt > $1.updatedAt }
            var retainedIds = MobileRecoveryRetention.retaining(
                ordered.map(\.id),
                limit: MobileRecoveryLimits.sessionsPerProject,
                protectedId: item.key == activeProjectId ? activeSessionId : nil
            )
            retainedIds.formUnion(ordered.compactMap { pendingSessionIds.contains($0.id) ? $0.id : nil })
            result[item.key] = ordered.filter { retainedIds.contains($0.id) }
        }
        let listedSessionIdsAfterTrim = Set(cache.sessions.values.flatMap { $0.map(\.id) })
        let evictedListedSessionIds = listedSessionIdsBeforeTrim.subtracting(listedSessionIdsAfterTrim)
        let sessionIdsInRetainedProjects = listedSessionIdsAfterTrim
            .union(cache.sessionProjects.compactMap { retainedProjectIds.contains($0.value) ? $0.key : nil })
            .subtracting(evictedListedSessionIds)
        var retainedSessionIds = cache.retainedSessionIds(activeSessionId: activeSessionId)
            .intersection(sessionIdsInRetainedProjects)
        retainedSessionIds.formUnion(pendingSessionIds)
        cache.sessionProjects = cache.sessionProjects.filter { retainedSessionIds.contains($0.key) }
        cache.sessionEvents = cache.sessionEvents.reduce(into: [:]) { result, item in
            guard retainedSessionIds.contains(item.key) else { return }
            result[item.key] = Array(item.value
                .filter { (try? JSONEncoder().encode($0).count) ?? Int.max <= MobileRecoveryLimits.maximumEventBytes }
                .suffix(MobileRecoveryLimits.eventsPerSession))
        }
        cache.pendingInteractions = cache.pendingInteractions?.filter { retainedSessionIds.contains($0.key) }
        cache.workspaceNavigations = cache.workspaceNavigations?.filter { retainedSessionIds.contains($0.key) }
        cache.sessionDrafts = cache.sessionDrafts?.filter { retainedSessionIds.contains($0.key) && !$0.value.isEmpty }
        cache.fileBrowserNavigations = cache.fileBrowserNavigations?.reduce(into: [:]) { result, item in
            guard retainedProjectIds.contains(item.key) else { return }
            result[item.key] = item.value.trimmed()
        }
        cache.submittedInteractions = cache.submittedInteractions?.filter { key in
            retainedSessionIds.contains { key.hasPrefix("\($0):") }
        }.sorted().prefix(MobileRecoveryLimits.interactionCount).map { $0 }
        cache.resolvedInteractions = cache.resolvedInteractions?.filter { key in
            retainedSessionIds.contains { key.hasPrefix("\($0):") }
        }.sorted().prefix(MobileRecoveryLimits.interactionCount).map { $0 }

        while let data = try? JSONEncoder().encode(cache), data.count > MobileRecoveryLimits.persistenceByteBudget {
            if let sessionId = cache.orderedSessionIds(activeSessionId: activeSessionId).reversed().first(where: {
                !(cache.sessionEvents[$0] ?? []).isEmpty
            }) {
                cache.sessionEvents[sessionId]?.removeFirst()
                continue
            }
            if let sessionId = cache.orderedSessionIds(activeSessionId: activeSessionId).reversed().first(where: {
                !pendingSessionIds.contains($0) && $0 != activeSessionId
            }) {
                cache.removeSession(sessionId)
                continue
            }
            if let sessionId = cache.workspaceNavigations?.keys.sorted().reversed().first(where: { $0 != activeSessionId }) {
                cache.workspaceNavigations?.removeValue(forKey: sessionId)
                continue
            }
            if let projectId = cache.fileBrowserNavigations?.keys.sorted().last {
                cache.fileBrowserNavigations?.removeValue(forKey: projectId)
                continue
            }
            if let sessionId = cache.sessionDrafts?.keys.sorted().reversed().first(where: { $0 != activeSessionId }) {
                cache.sessionDrafts?.removeValue(forKey: sessionId)
                continue
            }
            if let sessionId = cache.sessionDrafts?.keys.sorted().last {
                cache.sessionDrafts?.removeValue(forKey: sessionId)
                continue
            }
            if let key = cache.submittedInteractions?.sorted().last {
                cache.submittedInteractions?.removeAll { $0 == key }
                continue
            }
            if let key = cache.resolvedInteractions?.sorted().last {
                cache.resolvedInteractions?.removeAll { $0 == key }
                continue
            }
            break
        }
        return cache
    }

    private func retainedSessionIds(activeSessionId: String?) -> Set<String> {
        return MobileRecoveryRetention.retaining(
            orderedSessionIds(activeSessionId: activeSessionId),
            limit: MobileRecoveryLimits.sessionCount,
            protectedId: activeSessionId
        )
    }

    private func orderedSessionIds(activeSessionId: String?) -> [String] {
        let sessionsById = sessions.values.flatMap { $0 }.reduce(into: [String: Session]()) { result, session in
            if let existing = result[session.id], existing.updatedAt >= session.updatedAt { return }
            result[session.id] = session
        }
        let ids = Set(sessionsById.keys).union(sessionProjects.keys).union(sessionEvents.keys)
            .union(sessionDrafts?.keys.map { $0 } ?? [])
        let ordered = ids.sorted { lhs, rhs in
            let lhsUpdatedAt = sessionsById[lhs]?.updatedAt ?? ""
            let rhsUpdatedAt = sessionsById[rhs]?.updatedAt ?? ""
            if lhsUpdatedAt != rhsUpdatedAt { return lhsUpdatedAt > rhsUpdatedAt }
            return lhs < rhs
        }
        guard let activeSessionId, ordered.contains(activeSessionId) else { return ordered }
        return [activeSessionId] + ordered.filter { $0 != activeSessionId }
    }

    mutating func removeSession(_ sessionId: String) {
        sessionProjects.removeValue(forKey: sessionId)
        sessionEvents.removeValue(forKey: sessionId)
        pendingInteractions?.removeValue(forKey: sessionId)
        workspaceNavigations?.removeValue(forKey: sessionId)
        sessionDrafts?.removeValue(forKey: sessionId)
        for projectId in Array(sessions.keys) {
            sessions[projectId]?.removeAll { $0.id == sessionId }
            if sessions[projectId]?.isEmpty == true { sessions.removeValue(forKey: projectId) }
        }
        submittedInteractions = submittedInteractions?.filter { !$0.hasPrefix("\(sessionId):") }
        resolvedInteractions = resolvedInteractions?.filter { !$0.hasPrefix("\(sessionId):") }
    }
}

enum MobileRecoveryLimits {
    static let projectCount = 20
    static let sessionCount = 40
    static let sessionsPerProject = 20
    static let eventsPerSession = 200
    static let interactionCount = 100
    static let expandedPathsPerProject = 100
    static let maximumEventBytes = 16 * 1024
    static let persistenceByteBudget = 512 * 1024
}

enum MobileRecoveryRetention {
    static func retaining(_ ids: [String], limit: Int, protectedId: String?) -> Set<String> {
        guard let protectedId, ids.contains(protectedId) else { return Set(ids.prefix(limit)) }
        return Set(([protectedId] + ids.filter { $0 != protectedId }).prefix(limit))
    }
}

struct MobileSessionOwnership {
    var recoveryProjects: [String: String]
    var subscriptionProjects: [String: String]

    init(recoveryProjects: [String: String], subscriptionProjects: [String: String]) {
        self.recoveryProjects = recoveryProjects
        self.subscriptionProjects = subscriptionProjects
    }

    init(restoring recoveryProjects: [String: String], sessions: [String: [Session]], sessionEvents: [String: [AgentEvent]]) {
        self.recoveryProjects = recoveryProjects
        let statuses = sessions.values.flatMap { $0 }.reduce(into: [String: SessionStatus]()) { result, session in
            result[session.id] = session.status
        }
        let completedSessionIds = Set(sessionEvents.compactMap { sessionId, events in
            events.contains { event in
                if case .sessionCompleted = event { return true }
                return false
            } ? sessionId : nil
        })
        subscriptionProjects = recoveryProjects.filter { sessionId, _ in
            !completedSessionIds.contains(sessionId) && !isTerminal(statuses[sessionId] ?? .running)
        }
    }

    mutating func receive(_ event: AgentEvent, sessionId: String, projectId: String) {
        recoveryProjects[sessionId] = projectId
        if case .sessionCompleted = event {
            subscriptionProjects.removeValue(forKey: sessionId)
        } else {
            subscriptionProjects[sessionId] = projectId
        }
    }

    func subscriptionCandidates() -> [(sessionId: String, projectId: String)] {
        subscriptionProjects.keys.sorted().compactMap { sessionId in
            subscriptionProjects[sessionId].map { (sessionId, $0) }
        }
    }
}

enum MobilePendingInteractionRecovery {
    static func removing(_ values: [String: [AgentEvent]], sessionId: String, interactionId: String) -> [String: [AgentEvent]] {
        var values = values
        values[sessionId]?.removeAll { event in
            switch event {
            case let .approvalRequested(value): value.interactionId == interactionId
            case let .questionRequested(value): value.interactionId == interactionId
            default: false
            }
        }
        return values
    }

    static func clearing(_ values: [String: [AgentEvent]], sessionId: String) -> [String: [AgentEvent]] {
        var values = values
        values[sessionId] = []
        return values
    }
}

enum MobileRecoveryPersistence {
    static func pendingSessionIds(in cache: MobileRecoveryCache) -> Set<String> {
        Set((cache.pendingInteractions ?? [:]).compactMap { $0.value.isEmpty ? nil : $0.key })
    }

    static func exceedsBudget(_ cache: MobileRecoveryCache) -> Bool {
        guard let data = try? JSONEncoder().encode(cache) else { return true }
        return data.count > MobileRecoveryLimits.persistenceByteBudget
    }

    static func recoveryErrors(for cache: MobileRecoveryCache) -> [String: String] {
        Dictionary(uniqueKeysWithValues: pendingSessionIds(in: cache).map {
            ($0, "This session's pending interaction cannot be restored after restart")
        })
    }
}

enum MobileRecoveryErrorState {
    static func recording(_ errors: [String: String], cache: MobileRecoveryCache) -> [String: String] {
        var errors = errors
        errors.merge(MobileRecoveryPersistence.recoveryErrors(for: cache)) { _, new in new }
        return errors
    }

    static func clearing(_ errors: [String: String], sessionId: String) -> [String: String] {
        var errors = errors
        errors.removeValue(forKey: sessionId)
        return errors
    }

    static func clearingAll(_ errors: [String: String]) -> [String: String] { [:] }
}


func isTerminal(_ status: SessionStatus) -> Bool {
    status == .completed || status == .failed || status == .cancelled
}
