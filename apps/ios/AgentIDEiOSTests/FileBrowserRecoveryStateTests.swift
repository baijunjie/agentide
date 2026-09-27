import XCTest
import AgentIDEProtocol
@testable import AgentIDEiOS

final class FileBrowserRecoveryStateTests: XCTestCase {
    func testReturningToSessionClearsPresentedFile() {
        let selection = try! JSONDecoder().decode(TextFileSelection.self, from: Data("""
        {"projectId":"project-one","name":"README.md","relativePath":"README.md","isMarkdown":true}
        """.utf8))
        var navigation = WorkspaceNavigationState(level: .browser)
        navigation.prepareFile(selection)
        navigation.activatePreparedFile()

        navigation.returnToSession()

        XCTAssertEqual(navigation.level, .session)
        XCTAssertNil(navigation.presentedFile)
    }

    func testCollapseRemovesDescendantExpansionAndColdRestoreCanFinish() {
        let restored = FileBrowserRecoveryState(
            expandedPaths: ["src", "src/foo"],
            scrollPosition: "src/foo/file.swift"
        ).trimmed()

        XCTAssertEqual(restored.expandedPaths, ["src", "src/foo"])

        let collapsed = FileBrowserRecoveryState(
            expandedPaths: FileBrowserRecoveryState.collapsing("src", in: restored.expandedPaths),
            scrollPosition: restored.scrollPosition
        ).trimmed()

        XCTAssertTrue(collapsed.expandedPaths.isEmpty)
        XCTAssertNil(collapsed.scrollPosition)
    }

    func testColdRestoreDropsOrphanedExpandedDescendant() {
        let restored = FileBrowserRecoveryState(
            expandedPaths: ["src/foo"],
            scrollPosition: "src/foo/file.swift"
        ).trimmed()

        XCTAssertTrue(restored.expandedPaths.isEmpty)
        XCTAssertNil(restored.scrollPosition)
    }

    func testActiveProjectAndSessionSurviveTwentyItemCutoffs() {
        let projectIds = (1...21).map { "project-\($0)" }
        let sessionIds = (1...21).map { "session-\($0)" }

        let retainedProjects = MobileRecoveryRetention.retaining(
            projectIds,
            limit: MobileRecoveryLimits.projectCount,
            protectedId: "project-21"
        )
        let retainedSessions = MobileRecoveryRetention.retaining(
            sessionIds,
            limit: MobileRecoveryLimits.sessionsPerProject,
            protectedId: "session-21"
        )

        XCTAssertEqual(retainedProjects.count, MobileRecoveryLimits.projectCount)
        XCTAssertEqual(retainedSessions.count, MobileRecoveryLimits.sessionsPerProject)
        XCTAssertTrue(retainedProjects.contains("project-21"))
        XCTAssertTrue(retainedSessions.contains("session-21"))
        XCTAssertFalse(retainedProjects.contains("project-20"))
        XCTAssertFalse(retainedSessions.contains("session-20"))

        let retainedState = retainedSessions.reduce(into: [String: String]()) { $0[$1] = "state" }
        XCTAssertNotNil(retainedState["session-21"])

        let session = try! JSONDecoder().decode(Session.self, from: Data("""
        {"id":"session-21","projectId":"project-21","agentType":"codex","title":"Active","status":"idle","createdAt":"2026-09-27T00:00:00Z","updatedAt":"2026-09-27T00:00:00Z"}
        """.utf8))
        let cache = MobileRecoveryCache(
            projects: [RemoteProject(id: "project-21", name: "Active", createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true)],
            sessions: ["project-21": [session]],
            sessionEvents: [:],
            sessionProjects: ["session-21": "project-21"],
            workspaceNavigations: ["session-21": WorkspaceNavigationState()],
            fileBrowserNavigations: ["project-21": FileBrowserRecoveryState(expandedPaths: ["src"], scrollPosition: "src")],
            submittedInteractions: ["session-21:interaction"],
            resolvedInteractions: []
        )
        XCTAssertLessThanOrEqual(try! JSONEncoder().encode(cache).count, MobileRecoveryLimits.persistenceByteBudget)
    }

    func testMissingDirectoryRemovesDescendantsAndAdvancesRecoveryQueue() {
        let restored = FileBrowserRestorationState(
            expandedPaths: ["src", "src/deleted", "src/deleted/nested"],
            pendingScrollPosition: "src/deleted/nested/file.swift",
            restorationQueue: ["src/deleted", "src/deleted/nested"]
        )

        let recovered = restored.removingUnavailable("src/deleted")

        XCTAssertEqual(recovered.expandedPaths, ["src"])
        XCTAssertNil(recovered.pendingScrollPosition)
        XCTAssertTrue(recovered.restorationQueue.isEmpty)
    }

    func testCompletedActiveSessionSurvivesCountAndByteEviction() throws {
        let projectIds = (1...21).map { "project-\($0)" }
        let activeProjectId = "project-21"
        let activeSessionId = "session-21"
        var ownership = MobileSessionOwnership(
            recoveryProjects: Dictionary(uniqueKeysWithValues: projectIds.map { projectId in
                let number = String(projectId.dropFirst("project-".count))
                return ("session-\(number)", projectId)
            }),
            subscriptionProjects: Dictionary(uniqueKeysWithValues: projectIds.map { projectId in
                let number = String(projectId.dropFirst("project-".count))
                return ("session-\(number)", projectId)
            })
        )
        ownership.receive(completed(sessionId: activeSessionId), sessionId: activeSessionId, projectId: activeProjectId)

        let projects = projectIds.map {
            RemoteProject(id: $0, name: $0, createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true)
        }
        let sessions = Dictionary(uniqueKeysWithValues: projectIds.map { projectId in
            let number = String(projectId.dropFirst("project-".count))
            return (projectId, [session(id: "session-\(number)", projectId: projectId)])
        })
        let payload = String(repeating: "x", count: 15_000)
        var events = Dictionary(uniqueKeysWithValues: projectIds.dropLast(1).map { projectId in
            let number = String(projectId.dropFirst("project-".count))
            let sessionId = "session-\(number)"
            return (sessionId, [message(sessionId: sessionId, sequence: 1, content: payload), message(sessionId: sessionId, sequence: 2, content: payload)])
        })
        events[activeSessionId] = [message(sessionId: activeSessionId, sequence: 1, content: "active")]

        let cache = MobileRecoveryCache(
            projects: projects,
            sessions: sessions,
            sessionEvents: events,
            sessionProjects: Dictionary(uniqueKeysWithValues: projectIds.map { projectId in
                let number = String(projectId.dropFirst("project-".count))
                return ("session-\(number)", projectId)
            }),
            workspaceNavigations: [activeSessionId: WorkspaceNavigationState()],
            fileBrowserNavigations: [activeProjectId: FileBrowserRecoveryState(expandedPaths: ["src"], scrollPosition: "src")],
            submittedInteractions: [],
            resolvedInteractions: []
        ).trimmedForPersistence(activeSessionId: activeSessionId)

        XCTAssertNil(ownership.subscriptionProjects[activeSessionId])
        XCTAssertEqual(ownership.recoveryProjects[activeSessionId], activeProjectId)
        XCTAssertEqual(cache.projects.count, MobileRecoveryLimits.projectCount)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(cache).count, MobileRecoveryLimits.persistenceByteBudget)
        XCTAssertTrue(cache.projects.contains { $0.id == activeProjectId })
        XCTAssertTrue(cache.sessions[activeProjectId]?.contains { $0.id == activeSessionId } == true)
        XCTAssertNotNil(cache.sessionEvents[activeSessionId])
        XCTAssertNotNil(cache.workspaceNavigations?[activeSessionId])
        XCTAssertEqual(cache.sessionProjects[activeSessionId], activeProjectId)
    }

    func testLegacyOnlyRecoveryMapRestoresSubscriptionCandidates() {
        let ownership = MobileSessionOwnership(
            restoring: ["session-legacy": "project-legacy"],
            sessions: [:],
            sessionEvents: [:]
        )

        XCTAssertEqual(ownership.subscriptionProjects, ["session-legacy": "project-legacy"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: ownership.subscriptionCandidates()), ["session-legacy": "project-legacy"])
    }

    func testRecoveryOnlySessionsExcludeTrustedTerminalEventsFromSubscriptionCandidates() {
        let ownership = MobileSessionOwnership(
            restoring: [
                "session-live": "project-live",
                "session-terminal": "project-terminal",
                "session-terminal-status": "project-terminal-status",
            ],
            sessions: ["project-terminal-status": [session(
                id: "session-terminal-status",
                projectId: "project-terminal-status",
                status: "completed"
            )]],
            sessionEvents: ["session-terminal": [completed(sessionId: "session-terminal")]]
        )

        XCTAssertEqual(ownership.subscriptionProjects, ["session-live": "project-live"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: ownership.subscriptionCandidates()), ["session-live": "project-live"])
        XCTAssertEqual(ownership.recoveryProjects["session-terminal"], "project-terminal")
    }

    func testOversizedPendingInteractionIsRetainedOutsideEventHistory() throws {
        let pending = approval(sessionId: "session-pending", sequence: 1, interactionId: "approval-1", description: String(repeating: "x", count: 20_000))
        let cache = MobileRecoveryCache(
            projects: [RemoteProject(id: "project-pending", name: "Pending", createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true)],
            sessions: ["project-pending": [session(id: "session-pending", projectId: "project-pending")]],
            sessionEvents: [:],
            pendingInteractions: ["session-pending": [pending]],
            sessionProjects: ["session-pending": "project-pending"],
            workspaceNavigations: nil,
            fileBrowserNavigations: nil,
            submittedInteractions: [],
            resolvedInteractions: []
        ).trimmedForPersistence(activeSessionId: "session-pending")

        XCTAssertTrue(cache.sessionEvents["session-pending"]?.isEmpty ?? true)
        XCTAssertEqual(cache.pendingInteractions?["session-pending"]?.count, 1)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(cache).count, MobileRecoveryLimits.persistenceByteBudget)
    }

    func testPendingInteractionSurvivesHistoryBudgetEviction() throws {
        let projectId = "project-pending"
        let sessionId = "session-pending"
        let history = (1...40).map { message(sessionId: sessionId, sequence: $0, content: String(repeating: "x", count: 15_000)) }
        let pending = approval(sessionId: sessionId, sequence: 41, interactionId: "approval-1", description: "Approve")
        let cache = MobileRecoveryCache(
            projects: [RemoteProject(id: projectId, name: "Pending", createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true)],
            sessions: [projectId: [session(id: sessionId, projectId: projectId)]],
            sessionEvents: [sessionId: history],
            pendingInteractions: [sessionId: [pending]],
            sessionProjects: [sessionId: projectId],
            workspaceNavigations: [sessionId: WorkspaceNavigationState()],
            fileBrowserNavigations: nil,
            submittedInteractions: [],
            resolvedInteractions: []
        ).trimmedForPersistence(activeSessionId: sessionId)

        XCTAssertLessThanOrEqual(try JSONEncoder().encode(cache).count, MobileRecoveryLimits.persistenceByteBudget)
        XCTAssertEqual(cache.pendingInteractions?[sessionId]?.count, 1)
        XCTAssertLessThan(cache.sessionEvents[sessionId]?.count ?? 0, history.count)
    }

    func testPendingInteractionRestoresAndClearsAfterResponseOrTerminalState() throws {
        let pending = approval(sessionId: "session-pending", sequence: 1, interactionId: "approval-1", description: "Approve")
        let cache = MobileRecoveryCache(
            projects: [], sessions: [:], sessionEvents: [:], pendingInteractions: ["session-pending": [pending]],
            sessionProjects: ["session-pending": "project-pending"], workspaceNavigations: nil,
            fileBrowserNavigations: nil, submittedInteractions: [], resolvedInteractions: []
        )
        let restored = try JSONDecoder().decode(MobileRecoveryCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(restored.pendingInteractions?["session-pending"]?.count, 1)

        let afterResponse = MobilePendingInteractionRecovery.removing(
            restored.pendingInteractions ?? [:], sessionId: "session-pending", interactionId: "approval-1"
        )
        XCTAssertTrue(afterResponse["session-pending"]?.isEmpty ?? false)
        let afterTerminal = MobilePendingInteractionRecovery.clearing(
            restored.pendingInteractions ?? [:], sessionId: "session-pending"
        )
        XCTAssertTrue(afterTerminal["session-pending"]?.isEmpty ?? false)
    }

    func testNonActivePendingSessionSurvivesBudgetEvictionAndFeedsInteraction() throws {
        let history = (1...40).map { message(sessionId: "session-history", sequence: $0, content: String(repeating: "x", count: 15_000)) }
        let pending = approval(sessionId: "session-pending", sequence: 1, interactionId: "approval-1", description: "Approve")
        let cache = MobileRecoveryCache(
            projects: [
                RemoteProject(id: "project-history", name: "History", createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true),
                RemoteProject(id: "project-pending", name: "Pending", createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true),
            ],
            sessions: [
                "project-history": [session(id: "session-history", projectId: "project-history")],
                "project-pending": [session(id: "session-pending", projectId: "project-pending")],
            ],
            sessionEvents: ["session-history": history], pendingInteractions: ["session-pending": [pending]],
            sessionProjects: ["session-history": "project-history", "session-pending": "project-pending"],
            workspaceNavigations: nil, fileBrowserNavigations: nil, submittedInteractions: [], resolvedInteractions: []
        ).trimmedForPersistence(activeSessionId: "session-history")

        XCTAssertLessThanOrEqual(try JSONEncoder().encode(cache).count, MobileRecoveryLimits.persistenceByteBudget)
        XCTAssertEqual(cache.pendingInteractions?["session-pending"]?.count, 1)
        XCTAssertEqual(feedItems(cache.pendingInteractions?["session-pending"] ?? []).count, 1)
    }

    func testRemovingSessionAlsoRemovesPendingInteraction() {
        let pending = approval(sessionId: "session-pending", sequence: 1, interactionId: "approval-1", description: "Approve")
        var cache = MobileRecoveryCache(
            projects: [], sessions: [:], sessionEvents: [:], pendingInteractions: ["session-pending": [pending]],
            sessionProjects: ["session-pending": "project-pending"], workspaceNavigations: nil,
            fileBrowserNavigations: nil, submittedInteractions: [], resolvedInteractions: []
        )
        cache.removeSession("session-pending")
        XCTAssertNil(cache.pendingInteractions?["session-pending"])
        XCTAssertNil(cache.sessionProjects["session-pending"])
    }

    func testDraftsParticipateInRecoveryRetentionAndSessionCleanup() throws {
        let activeSessionId = "session-active"
        let evictedSessionId = "session-evicted"
        var cache = MobileRecoveryCache(
            projects: [RemoteProject(id: "project-one", name: "One", createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true)],
            sessions: ["project-one": [session(id: activeSessionId, projectId: "project-one")]],
            sessionEvents: [:],
            sessionProjects: [activeSessionId: "project-one", evictedSessionId: "project-one"],
            workspaceNavigations: nil,
            fileBrowserNavigations: nil,
            sessionDrafts: [activeSessionId: "active draft", evictedSessionId: String(repeating: "x", count: 600_000)],
            submittedInteractions: [],
            resolvedInteractions: []
        ).trimmedForPersistence(activeSessionId: activeSessionId)

        XCTAssertEqual(cache.sessionDrafts?[activeSessionId], "active draft")
        XCTAssertNil(cache.sessionDrafts?[evictedSessionId])
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(cache).count, MobileRecoveryLimits.persistenceByteBudget)

        cache.removeSession(activeSessionId)
        XCTAssertNil(cache.sessionDrafts?[activeSessionId])
    }

    @MainActor
    func testDraftsRoundTripAndFollowPerProjectSessionCountEviction() throws {
        let projectId = "project-many"
        let values = (1...21).map { session(id: "session-\($0)", projectId: projectId) }
        let sessionProjects = Dictionary(uniqueKeysWithValues: values.map { ($0.id, projectId) })
        let drafts = Dictionary(uniqueKeysWithValues: values.map { ($0.id, "draft \($0.id)") })
        let cache = MobileRecoveryCache(
            projects: [RemoteProject(id: projectId, name: "Many", createdAt: "2026-09-27T00:00:00Z", enabledAgents: [.codex], online: true)],
            sessions: [projectId: values],
            sessionEvents: [:],
            sessionProjects: sessionProjects,
            workspaceNavigations: nil,
            fileBrowserNavigations: nil,
            sessionDrafts: drafts,
            submittedInteractions: [],
            resolvedInteractions: []
        )

        let restored = try JSONDecoder().decode(MobileRecoveryCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(restored.sessionDrafts, drafts)

        let trimmed = restored.trimmedForPersistence(activeSessionId: nil)
        let retainedIds = Set(trimmed.sessions[projectId]?.map(\.id) ?? [])
        XCTAssertEqual(retainedIds.count, MobileRecoveryLimits.sessionsPerProject)
        XCTAssertEqual(Set(trimmed.sessionDrafts?.keys.map { $0 } ?? []), retainedIds)
        XCTAssertEqual(Set(trimmed.sessionProjects.keys), retainedIds)

        let connection = MobileConnection(
            scenarioRuntime: MobileScenarioRuntime(scenario: .comprehensive),
            recoveryCacheOverride: restored
        )
        let runtimeRetainedIds = Set(connection.sessions[projectId]?.map(\.id) ?? [])
        XCTAssertEqual(runtimeRetainedIds.count, MobileRecoveryLimits.sessionsPerProject)
        XCTAssertEqual(Set(connection.sessionDrafts.keys), runtimeRetainedIds)
    }

    func testOversizedProtectedPendingRequiresDiscardAndIdentifiesAffectedSessions() {
        let first = approval(sessionId: "session-one", sequence: 1, interactionId: "approval-one", description: String(repeating: "x", count: 300_000))
        let second = approval(sessionId: "session-two", sequence: 1, interactionId: "approval-two", description: String(repeating: "y", count: 300_000))
        let cache = MobileRecoveryCache(
            projects: [], sessions: [:], sessionEvents: [:],
            pendingInteractions: ["session-one": [first], "session-two": [second]],
            sessionProjects: ["session-one": "project-one", "session-two": "project-two"],
            workspaceNavigations: nil, fileBrowserNavigations: nil, submittedInteractions: [], resolvedInteractions: []
        )

        XCTAssertTrue(MobileRecoveryPersistence.exceedsBudget(cache))
        XCTAssertEqual(MobileRecoveryPersistence.pendingSessionIds(in: cache), ["session-one", "session-two"])
        XCTAssertEqual(MobileRecoveryPersistence.recoveryErrors(for: cache).count, 2)
        XCTAssertEqual(cache.pendingInteractions?["session-one"]?.count, 1)
        XCTAssertEqual(cache.pendingInteractions?["session-two"]?.count, 1)
    }

    func testRecoveryErrorReducerKeepsFailureThroughSubscribeAndClearsOnlyOnRecoveryTransitions() {
        let pending = approval(sessionId: "session-pending", sequence: 1, interactionId: "approval-1", description: "Approve")
        let cache = MobileRecoveryCache(
            projects: [], sessions: [:], sessionEvents: [:], pendingInteractions: ["session-pending": [pending]],
            sessionProjects: ["session-pending": "project-pending"], workspaceNavigations: nil,
            fileBrowserNavigations: nil, submittedInteractions: [], resolvedInteractions: []
        )
        let failed = MobileRecoveryErrorState.recording([:], cache: cache)
        let afterSubscribeAndFinish = failed
        XCTAssertEqual(afterSubscribeAndFinish["session-pending"], "This session's pending interaction cannot be restored after restart")
        XCTAssertTrue(MobileRecoveryErrorState.clearingAll(afterSubscribeAndFinish).isEmpty)
        XCTAssertTrue(MobileRecoveryErrorState.clearing(afterSubscribeAndFinish, sessionId: "session-pending").isEmpty)
    }

    private func session(id: String, projectId: String, status: String = "idle") -> Session {
        try! JSONDecoder().decode(Session.self, from: Data("""
        {"id":"\(id)","projectId":"\(projectId)","agentType":"codex","title":"\(id)","status":"\(status)","createdAt":"2026-09-27T00:00:00Z","updatedAt":"2026-09-27T00:00:00Z"}
        """.utf8))
    }

    private func message(sessionId: String, sequence: Int, content: String) -> AgentEvent {
        try! JSONDecoder().decode(AgentEvent.self, from: try! JSONSerialization.data(withJSONObject: [
            "id": "\(sessionId)-\(sequence)",
            "sessionId": sessionId,
            "sequence": sequence,
            "timestamp": "2026-09-27T00:00:00Z",
            "type": "message",
            "role": "agent",
            "content": content,
            "format": "plain",
        ]))
    }

    private func completed(sessionId: String) -> AgentEvent {
        try! JSONDecoder().decode(AgentEvent.self, from: Data("""
        {"id":"\(sessionId)-completed","sessionId":"\(sessionId)","sequence":3,"timestamp":"2026-09-27T00:00:00Z","type":"session.completed","outcome":"completed"}
        """.utf8))
    }

    private func approval(sessionId: String, sequence: Int, interactionId: String, description: String) -> AgentEvent {
        try! JSONDecoder().decode(AgentEvent.self, from: try! JSONSerialization.data(withJSONObject: [
            "id": "\(sessionId)-approval-\(sequence)",
            "sessionId": sessionId,
            "sequence": sequence,
            "timestamp": "2026-09-27T00:00:00Z",
            "type": "approval.requested",
            "interactionId": interactionId,
            "title": "Approval",
            "description": description,
            "actions": ["approve_once"],
        ]))
    }
}
