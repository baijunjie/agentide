import AVFoundation
import AgentIDEProtocol
import ImageIO
import Security
import SwiftUI
import UIKit

func normalizedProjectFileSearchQuery(_ query: String) -> String? {
    let normalized = projectFileSearchQueryTrimmingWhiteSpace(query)
    return (2...256).contains(normalized.unicodeScalars.count) ? normalized : nil
}

func projectFileSearchQueryTrimmingWhiteSpace(_ query: String) -> String {
    let scalars = query.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isProjectSearchWhiteSpace($0) }),
          let last = scalars.lastIndex(where: { !isProjectSearchWhiteSpace($0) }) else { return "" }
    return String(scalars[first...last])
}

private func isProjectSearchWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
        true
    default:
        false
    }
}

private struct PairingPayload: Codable { let version: Int; let server: String; let pairingId: String; let secret: String }
struct RemoteProject: Codable, Identifiable {
    let id: String
    let name: String
    let createdAt: String
    let enabledAgents: [AgentType]
    let online: Bool
}
private struct ProjectListPayload: Decodable { let projects: [RemoteProject] }
private struct FileListPayload: Decodable { let relativePath: String; let entries: [FileEntry] }
private struct SessionListPayload: Decodable { let sessions: [Session] }
private struct SessionCreatePayload: Decodable { let session: Session }
struct RemoteFileContent: Decodable {
    enum Encoding: String, Decodable { case utf8, base64 }
    let relativePath: String
    let encoding: Encoding
    let content: String
}
struct RemoteImageList: Decodable {
    let current: FileEntry
    let siblings: [FileEntry]
}
struct RemoteRequestError: Equatable {
    let code: String
    let message: String
    let retryable: Bool

    init(message: String, code: String = "PROJECT_REQUEST_FAILED", retryable: Bool = true) {
        self.message = message
        self.code = code
        self.retryable = retryable
    }
}

struct FileSearchHistoryStore {
    let defaults: UserDefaults

    func load(projectId: String) -> [String]? {
        defaults.stringArray(forKey: key(projectId))
    }

    func save(_ history: [String], projectId: String) {
        defaults.set(Array(history.prefix(10)), forKey: key(projectId))
    }

    private func key(_ projectId: String) -> String {
        "fileSearchHistory.\(projectId)"
    }
}
private struct DecodedImage: @unchecked Sendable {
    let image: UIImage
    let cost: Int
}
private extension PendingInteraction {
    var event: AgentEvent {
        switch self {
        case let .approvalRequested(value): .approvalRequested(value)
        case let .questionRequested(value): .questionRequested(value)
        }
    }

    var interactionId: String {
        switch self {
        case let .approvalRequested(value): value.interactionId
        case let .questionRequested(value): value.interactionId
        }
    }
}

@MainActor
final class MobileConnection: ObservableObject {
    struct Claim: Decodable { let token: String }
    /// `revision` is the draft version captured by Send. The text field then writes that same string once more; `absorbIdenticalWrite` ignores that one commit so it is not treated as an edit made while waiting.
    private struct SubmittedDraft {
        let revision: Int
        var absorbIdenticalWrite: Bool
    }
    private enum PendingRequest {
        case projectList
        case directory(String)
        case text(String)
        case image(String)
        case imageList(String)
        case search(String, String, String)
        case changes(String, Int)
        case diff(String, String, GitChangeArea, Int)
        case sessionList(String)
        case sessionCreate(String)
        case sessionSend(String, String)
        case sessionCancel(String, String)
        case sessionSnapshot(String, String)
        case sessionSubscribe(String, String)
        case interaction(String, String, String)

        var responseType: String {
            switch self {
            case .projectList: "project.list.response"
            case .directory: "project.listFiles.response"
            case .text, .image: "project.readFile.response"
            case .imageList: "project.listImages.response"
            case .search: "project.searchFiles.response"
            case .changes: "project.listChanges.response"
            case .diff: "project.readDiff.response"
            case .sessionList: "session.list.response"
            case .sessionCreate: "session.create.response"
            case .sessionSend: "session.sendMessage.response"
            case .sessionCancel: "session.cancel.response"
            case .sessionSnapshot: "session.getSnapshot.response"
            case .sessionSubscribe: "session.subscribe.response"
            case .interaction: "interaction.respond.response"
            }
        }

        var isInteraction: Bool {
            if case .interaction = self { return true }
            return false
        }
    }
    @Published var online = false
    @Published var paired = false
    @Published var projects: [RemoteProject] = []
    @Published var files: [String: [FileEntry]] = [:]
    @Published var loadingPaths: Set<String> = []
    @Published var fileContents: [String: RemoteFileContent] = [:]
    @Published var imageLists: [String: RemoteImageList] = [:]
    @Published var loadingFiles: Set<String> = []
    @Published var loadingImageLists: Set<String> = []
    @Published var directoryErrors: [String: String] = [:]
    @Published var fileErrors: [String: String] = [:]
    @Published var imageListErrors: [String: String] = [:]
    @Published var fileSearches: [String: ProjectSearchFilesResponse] = [:]
    @Published var loadingSearchProjects: Set<String> = []
    @Published var fileSearchErrors: [String: RemoteRequestError] = [:]
    @Published private(set) var fileSearchHistories: [String: [String]] = [:]
    @Published var projectChanges: [String: ProjectChangesResponse] = [:]
    @Published var loadingChanges: Set<String> = []
    @Published var changesErrors: [String: RemoteRequestError] = [:]
    @Published var changesCompletions: [String: ChangesRequestCompletion] = [:]
    @Published var diffs: [String: ProjectDiffResponse] = [:]
    @Published var loadingDiffs: Set<String> = []
    @Published var diffErrors: [String: RemoteRequestError] = [:]
    @Published var sessions: [String: [Session]] = [:]
    @Published var sessionEvents: [String: [AgentEvent]] = [:]
    @Published var sessionFeedItems: [String: [FeedItem]] = [:]
    @Published var eventSessionStatuses: [String: SessionStatus] = [:]
    @Published var historicallyResolvedInteractions: Set<String> = []
    @Published var loadingSessionProjects: Set<String> = []
    @Published var activeSessionOperations: Set<String> = []
    @Published var subscribingSessions: Set<String> = []
    @Published var respondingInteractions: Set<String> = []
    @Published var submittedInteractions: Set<String>
    @Published var resolvedInteractions: Set<String> = []
    @Published var sessionErrors: [String: String] = [:]
    @Published private(set) var sessionDrafts: [String: String]
    @Published private(set) var expandedReportIds: [String: [String]]
    @Published private(set) var recoveryErrors: [String: String] = [:]
    @Published var createdSession: Session?
    @Published private var imageRevision = 0
    @Published var error: String?
    @Published var unpairFailure: String?
    @Published var notificationNotice: String?
    @Published private(set) var pendingNotificationIntent: NotificationIntent?
    @Published private(set) var notificationReadyProjectId: String?
    @Published private(set) var notificationValidatedProjectId: String?
    @Published private(set) var notificationOutcomeProjectId: String?
    @Published private(set) var notificationRegistrationError: String?
    @Published private(set) var notificationNavigationRevision = 0
    private let deviceId: String
    private var acceptingRelayMessages = false
    var localDeviceId: String { deviceId }
    private let scenarioRuntime: MobileScenarioRuntime?
    private let fileSearchHistoryStore: FileSearchHistoryStore?
    private let requestTimeout: Duration
    private var macDeviceId: String?
    private var socket: URLSessionWebSocketTask?
    private var scenarioDeliveryTask: Task<Void, Never>?
    private var scenarioDeliveryRevision = 0
    private var pendingRequests: [String: PendingRequest] = [:]
    private var pendingTimeouts: [String: Task<Void, Never>] = [:]
    private var activeFileSearchIds: [String: String] = [:]
    private let changesDiffLifecycle = ChangesDiffLifecycle()
    private var activeImageKeys: Set<String> = []
    private var sessionOwnership: MobileSessionOwnership
    private var sessionProjects: [String: String] {
        get { sessionOwnership.recoveryProjects }
        set { sessionOwnership.recoveryProjects = newValue }
    }
    private var subscribedSessionProjects: [String: String] {
        get { sessionOwnership.subscriptionProjects }
        set { sessionOwnership.subscriptionProjects = newValue }
    }
    private var sessionEventSequences: [String: Int]
    private var pendingInteractionEvents: [String: [AgentEvent]]
    private var workspaceNavigations: [String: WorkspaceNavigationState]
    private var fileBrowserNavigations: [String: FileBrowserRecoveryState]
    private var draftRevisions: [String: Int]
    private var submittedDrafts: [String: SubmittedDraft] = [:]
    private var activeSessionId: String?
    private var notificationProjectListRequestId: String?
    private var notificationSessionListRequestId: String?
    private var pendingEventInteractions: [String: Set<String>] = [:]
    private var snapshottingSessions: Set<String> = []
    private var recoveryPersistenceTask: Task<Void, Never>?
    private lazy var pushRegistration = PushRegistrationCoordinator(
        submit: { [weak self] token, preferences in
            guard let self else { throw CancellationError() }
            try await self.submitPushRegistration(token: token, preferences: preferences)
        },
        failed: { [weak self] error in
            self?.notificationRegistrationError = error.localizedDescription
        },
        succeeded: { [weak self] in
            self?.notificationRegistrationError = nil
        }
    )
    private var pendingPushRegistration: (token: String, preferences: NotificationPreferences)?
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 3
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    init(
        scenarioRuntime: MobileScenarioRuntime? = MobileScenarioRuntime.fromLaunchArguments(),
        requestTimeout: Duration = .seconds(15),
        recoveryCacheOverride: MobileRecoveryCache? = nil,
        fileSearchHistoryDefaults: UserDefaults = .standard
    ) {
        self.scenarioRuntime = scenarioRuntime
        self.fileSearchHistoryStore = scenarioRuntime == nil ? FileSearchHistoryStore(defaults: fileSearchHistoryDefaults) : nil
        self.requestTimeout = requestTimeout
        let recoveryCache = recoveryCacheOverride ?? (scenarioRuntime == nil
            ? UserDefaults.standard.data(forKey: "mobileRecoveryCache")
                .flatMap { try? JSONDecoder().decode(MobileRecoveryCache.self, from: $0) }
            : nil)
        let restoredSessionProjects = recoveryCache?.sessionProjects
                ?? (scenarioRuntime == nil
                    ? UserDefaults.standard.dictionary(forKey: "sessionProjects") as? [String: String]
                    : nil)
                ?? [:]
        let restoredSessions = recoveryCache?.sessions ?? [:]
        let restoredEvents = recoveryCache?.sessionEvents ?? [:]
        sessionOwnership = MobileSessionOwnership(
            restoring: restoredSessionProjects,
            sessions: restoredSessions,
            sessionEvents: restoredEvents
        )
        sessionEventSequences = [:]
        pendingInteractionEvents = recoveryCache?.pendingInteractions ?? [:]
        workspaceNavigations = recoveryCache?.workspaceNavigations ?? [:]
        fileBrowserNavigations = recoveryCache?.fileBrowserNavigations ?? [:]
        let restoredDrafts = recoveryCache?.sessionDrafts ?? [:]
        sessionDrafts = restoredDrafts
        expandedReportIds = recoveryCache?.expandedReportIds ?? [:]
        draftRevisions = Dictionary(uniqueKeysWithValues: restoredDrafts.keys.map { ($0, 0) })
        submittedInteractions = Set(recoveryCache?.submittedInteractions
            ?? (scenarioRuntime == nil ? UserDefaults.standard.stringArray(forKey: "submittedInteractions") : nil) ?? [])
        resolvedInteractions = Set(recoveryCache?.resolvedInteractions
            ?? (scenarioRuntime == nil ? UserDefaults.standard.stringArray(forKey: "resolvedInteractions") : nil) ?? [])
        if scenarioRuntime == nil {
            UserDefaults.standard.removeObject(forKey: "sessionEventSequences")
            UserDefaults.standard.removeObject(forKey: "sessionProjects")
            UserDefaults.standard.removeObject(forKey: "submittedInteractions")
            UserDefaults.standard.removeObject(forKey: "resolvedInteractions")
        }
        projects = recoveryCache?.projects ?? scenarioRuntime?.seededProjects() ?? []
        sessions = restoredSessions
        sessionEvents = restoredEvents
        if scenarioRuntime != nil {
            deviceId = "scenario-ios"
        } else if let id = UserDefaults.standard.string(forKey: "deviceId") {
            deviceId = id
        } else {
            let id = UUID().uuidString
            deviceId = id
            UserDefaults.standard.set(id, forKey: "deviceId")
        }
        for sessionId in Set(sessionEvents.keys).union(pendingInteractionEvents.keys) {
            sessionEventSequences[sessionId] = sessionEvents[sessionId]?.last?.sequence ?? -1
            sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
            rebuildDerivedSessionState(sessionId: sessionId, events: allSessionEvents(sessionId))
        }
        for session in sessions.values.flatMap({ $0 }) where !isTerminal(eventSessionStatuses[session.id] ?? session.status) {
            subscribedSessionProjects[session.id] = session.projectId
        }
        trimRecoveryState()
        if let scenarioRuntime {
            paired = scenarioRuntime.presence.paired
            online = scenarioRuntime.presence.online
            macDeviceId = scenarioRuntime.presence.macDeviceId
            acceptingRelayMessages = true
            enqueueScenarioMessages(scenarioRuntime.start())
        } else if let server = UserDefaults.standard.string(forKey: "relayServer"), let token = CredentialStore.token(for: server) {
            paired = true
            acceptingRelayMessages = true
            connect(server: server, token: token)
        }
    }

    func revokeSelf() async {
        if scenarioRuntime != nil {
            dropPairing(server: nil)
            return
        }
        guard let server = UserDefaults.standard.string(forKey: "relayServer"),
              let token = CredentialStore.token(for: server),
              let base = URL(string: server) else {
            dropPairing(server: UserDefaults.standard.string(forKey: "relayServer"))
            return
        }
        let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
        guard let url = URL(string: "/devices/\(encoded)", relativeTo: base) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
                unpairFailure = "Could not unpair this iPhone."
                return
            }
            dropPairing(server: server)
        } catch {
            unpairFailure = error.localizedDescription
        }
    }

    private func dropPairing(server: String?) {
        acceptingRelayMessages = false
        pushRegistration.reset()
        recoveryPersistenceTask?.cancel()
        let task = socket
        socket = nil
        task?.cancel()
        for id in pendingTimeouts.keys { pendingTimeouts[id]?.cancel() }
        pendingTimeouts.removeAll()
        pendingRequests.removeAll()
        if let server { CredentialStore.delete(for: server) }
        UserDefaults.standard.removeObject(forKey: "relayServer")
        paired = false
        online = false
        macDeviceId = nil
        error = nil
        unpairFailure = nil
        clearNotificationNavigationState(clearNotice: true, clearRegistrationError: true)
        projects = []
        files = [:]
        loadingPaths = []
        fileContents = [:]
        imageLists = [:]
        loadingFiles = []
        loadingImageLists = []
        directoryErrors = [:]
        fileErrors = [:]
        imageListErrors = [:]
        fileSearches = [:]
        loadingSearchProjects = []
        fileSearchErrors = [:]
        projectChanges = [:]
        loadingChanges = []
        changesErrors = [:]
        changesCompletions = [:]
        diffs = [:]
        loadingDiffs = []
        diffErrors = [:]
        sessions = [:]
        sessionEvents = [:]
        sessionFeedItems = [:]
        eventSessionStatuses = [:]
        historicallyResolvedInteractions = []
        loadingSessionProjects = []
        activeSessionOperations = []
        subscribingSessions = []
        respondingInteractions = []
        submittedInteractions = []
        resolvedInteractions = []
        sessionErrors = [:]
        sessionDrafts = [:]
        expandedReportIds = [:]
        createdSession = nil
        pendingEventInteractions = [:]
        pendingInteractionEvents = [:]
        sessionProjects = [:]
        subscribedSessionProjects = [:]
        sessionEventSequences = [:]
        workspaceNavigations = [:]
        fileBrowserNavigations = [:]
        draftRevisions = [:]
        submittedDrafts = [:]
        activeSessionId = nil
        activeImageKeys = []
        imageCache.removeAllObjects()
        persistRecoveryState()
    }

    func claim(qrValue: String) async {
        do {
            let payload = try JSONDecoder().decode(PairingPayload.self, from: Data(qrValue.utf8))
            guard payload.version == 1, let base = URL(string: payload.server), isSecure(base), let url = URL(string: "/pairing/claim", relativeTo: base) else { throw URLError(.badURL) }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["pairingId": payload.pairingId, "secret": payload.secret, "deviceId": deviceId, "name": UIDevice.current.name])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else { throw URLError(.userAuthenticationRequired) }
            let claim = try JSONDecoder().decode(Claim.self, from: data)
            UserDefaults.standard.set(payload.server, forKey: "relayServer"); CredentialStore.save(claim.token, for: payload.server); paired = true
            acceptingRelayMessages = true
            submitPendingPushRegistration()
            connect(server: payload.server, token: claim.token)
        } catch { self.error = error.localizedDescription }
    }

    func registerPushToken(_ pushToken: String, preferences: NotificationPreferences) {
        guard scenarioRuntime == nil else { return }
        pendingPushRegistration = (pushToken, preferences)
        submitPendingPushRegistration()
    }

    func retryPushRegistration() {
        guard scenarioRuntime == nil else { return }
        submitPendingPushRegistration()
        pushRegistration.retry()
    }

    private func submitPendingPushRegistration() {
        guard paired,
              let pendingPushRegistration,
              let server = UserDefaults.standard.string(forKey: "relayServer"),
              CredentialStore.token(for: server) != nil else { return }
        pushRegistration.update(token: pendingPushRegistration.token, preferences: pendingPushRegistration.preferences)
    }

    private func submitPushRegistration(token pushToken: String, preferences: NotificationPreferences) async throws {
        guard let server = UserDefaults.standard.string(forKey: "relayServer"),
              let token = CredentialStore.token(for: server),
              let base = URL(string: server),
              let url = URL(string: "/notifications/token", relativeTo: base) else { throw URLError(.notConnectedToInternet) }
        #if DEBUG
        let environment = PushEnvironment.development
        #else
        let environment = PushEnvironment.production
        #endif
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(PushTokenRegistration(
            token: pushToken, environment: environment, preferences: preferences
        ))
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
    }

    func receiveNotification(_ delivery: NotificationDelivery) {
        notificationNotice = notice(for: delivery.intent.category)
        guard delivery.opensSession else { return }
        pendingNotificationIntent = delivery.intent
        notificationReadyProjectId = nil
        notificationValidatedProjectId = nil
        notificationOutcomeProjectId = nil
        notificationProjectListRequestId = nil
        notificationSessionListRequestId = nil
        resumeNotificationNavigationIfPossible()
    }

    func clearPendingNotification(message: String? = nil, outcomeProjectId: String? = nil) {
        pendingNotificationIntent = nil
        notificationReadyProjectId = nil
        notificationValidatedProjectId = nil
        notificationOutcomeProjectId = outcomeProjectId
        notificationProjectListRequestId = nil
        notificationSessionListRequestId = nil
        if let message { notificationNotice = message }
    }

    func consumeNotificationNavigationOutcome() {
        clearNotificationNavigationState(clearNotice: false, clearRegistrationError: false)
    }

    private func clearNotificationNavigationState(clearNotice: Bool, clearRegistrationError: Bool) {
        pendingNotificationIntent = nil
        notificationReadyProjectId = nil
        notificationValidatedProjectId = nil
        notificationOutcomeProjectId = nil
        notificationProjectListRequestId = nil
        notificationSessionListRequestId = nil
        if clearNotice { notificationNotice = nil }
        if clearRegistrationError { notificationRegistrationError = nil }
    }

    var notificationNavigationProjectId: String? {
        if let notificationOutcomeProjectId { return notificationOutcomeProjectId }
        guard let intent = pendingNotificationIntent,
              notificationValidatedProjectId == intent.projectId,
              projects.contains(where: { $0.id == intent.projectId }) else { return nil }
        return intent.projectId
    }

    func retryNotificationNavigation() {
        resumeNotificationNavigationIfPossible()
    }

    func requestProjects() {
        guard online, let macDeviceId else { return }
        error = nil
        send(type: "project.list", target: macDeviceId, payload: [:], pending: .projectList)
    }

    func requestSessions(projectId: String) {
        guard online, let macDeviceId else { sessionErrors[projectId] = "Mac is offline"; return }
        guard !loadingSessionProjects.contains(projectId) else { return }
        sessionErrors.removeValue(forKey: projectId)
        loadingSessionProjects.insert(projectId)
        send(type: "session.list", target: macDeviceId, projectId: projectId, payload: [:], pending: .sessionList(projectId))
    }

    private func resumeNotificationNavigationIfPossible() {
        guard pendingNotificationIntent != nil else { return }
        guard online, let macDeviceId else {
            notificationNotice = "Your Mac is offline. This notification will open when it reconnects."
            return
        }
        guard notificationProjectListRequestId == nil, notificationSessionListRequestId == nil else { return }
        // A notification is an external pointer, so cached projects are never authoritative here.
        let requestId = UUID().uuidString
        notificationProjectListRequestId = requestId
        send(type: "project.list", target: macDeviceId, payload: [:], pending: .projectList, requestId: requestId)
    }

    private func requestNotificationSessions(projectId: String) {
        guard online, let macDeviceId else { return }
        if loadingSessionProjects.contains(projectId) {
            if let existing = pendingRequests.first(where: { _, pending in
                if case .sessionList(projectId) = pending { return true }
                return false
            })?.key {
                notificationSessionListRequestId = existing
                return
            }
            loadingSessionProjects.remove(projectId)
        }
        loadingSessionProjects.insert(projectId)
        let requestId = UUID().uuidString
        notificationSessionListRequestId = requestId
        send(type: "session.list", target: macDeviceId, projectId: projectId, payload: [:], pending: .sessionList(projectId), requestId: requestId)
    }

    func createSession(projectId: String, agentType: AgentType, initialTask: String) {
        let task = initialTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { sessionErrors[projectId] = "Enter an initial task"; return }
        guard online, let macDeviceId else { sessionErrors[projectId] = "Mac is offline"; return }
        let operation = "create:\(projectId)"
        guard !activeSessionOperations.contains(operation) else { return }
        sessionErrors.removeValue(forKey: projectId)
        activeSessionOperations.insert(operation)
        send(type: "session.create", target: macDeviceId, projectId: projectId,
             payload: ["agentType": agentType.rawValue, "initialTask": task], pending: .sessionCreate(projectId))
    }

    func openSession(_ session: Session) {
        activeSessionId = session.id
        sessionProjects[session.id] = session.projectId
        if !isTerminal(status(for: session)) {
            subscribedSessionProjects[session.id] = session.projectId
        }
        scheduleRecoveryPersistence()
        requestSnapshot(sessionId: session.id, projectId: session.projectId)
    }

    func workspaceNavigation(for sessionId: String) -> WorkspaceNavigationState {
        workspaceNavigations[sessionId] ?? WorkspaceNavigationState()
    }

    func persistWorkspaceNavigation(_ navigation: WorkspaceNavigationState, for sessionId: String) {
        workspaceNavigations[sessionId] = navigation
        scheduleRecoveryPersistence()
    }

    func draft(for sessionId: String) -> String {
        sessionDrafts[sessionId] ?? ""
    }

    func updateDraft(_ draft: String, for sessionId: String) {
        if var submitted = submittedDrafts[sessionId], submitted.absorbIdenticalWrite {
            submitted.absorbIdenticalWrite = false
            submittedDrafts[sessionId] = submitted
            if (sessionDrafts[sessionId] ?? "") == draft { return }
        }
        draftRevisions[sessionId, default: 0] += 1
        if draft.isEmpty { sessionDrafts.removeValue(forKey: sessionId) }
        else { sessionDrafts[sessionId] = draft }
        scheduleRecoveryPersistence()
    }

    func appendToDraft(_ text: String, for sessionId: String) {
        let current = draft(for: sessionId)
        updateDraft(current.isEmpty ? text : "\(current)\n\(text)", for: sessionId)
    }

    func isReportExpanded(sessionId: String, reportId: String) -> Bool {
        expandedReportIds[sessionId]?.contains(reportId) == true
    }

    func setReportExpanded(_ expanded: Bool, sessionId: String, reportId: String) {
        var ids = expandedReportIds[sessionId] ?? []
        ids.removeAll { $0 == reportId }
        if expanded { ids.append(reportId) }
        ids = Array(ids.suffix(MobileRecoveryLimits.expandedReportsPerSession))
        if ids.isEmpty { expandedReportIds.removeValue(forKey: sessionId) }
        else { expandedReportIds[sessionId] = ids }
        scheduleRecoveryPersistence()
    }

    func fileBrowserNavigation(for projectId: String) -> FileBrowserRecoveryState {
        fileBrowserNavigations[projectId] ?? FileBrowserRecoveryState(expandedPaths: [], scrollPosition: nil)
    }

    func persistFileBrowserNavigation(_ navigation: FileBrowserRecoveryState, for projectId: String) {
        fileBrowserNavigations[projectId] = navigation
        scheduleRecoveryPersistence()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard scenarioRuntime == nil else { return }
        switch phase {
        case .active:
            retryPushRegistration()
            retryNotificationNavigation()
            guard !online, let server = UserDefaults.standard.string(forKey: "relayServer"),
                  let token = CredentialStore.token(for: server) else { return }
            connect(server: server, token: token)
        case .inactive:
            persistRecoveryState()
        case .background:
            persistRecoveryState()
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            online = false
            failAllPending(message: "App entered background")
        @unknown default:
            break
        }
    }

    @discardableResult
    func sendMessage(session: Session, content: String) -> Bool {
        let message = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return false }
        guard online, let macDeviceId else { sessionErrors[session.id] = "Mac is offline"; return false }
        let operation = "send:\(session.id)"
        guard !activeSessionOperations.contains(operation) else { return false }
        sessionProjects[session.id] = session.projectId
        subscribedSessionProjects[session.id] = session.projectId
        scheduleRecoveryPersistence()
        sessionErrors.removeValue(forKey: session.id)
        activeSessionOperations.insert(operation)
        send(type: "session.sendMessage", target: macDeviceId, projectId: session.projectId, sessionId: session.id,
             payload: ["content": message, "afterSequence": sessionEventSequences[session.id] ?? -1], pending: .sessionSend(session.projectId, session.id))
        return true
    }

    @discardableResult
    func sendDraft(session: Session) -> Bool {
        let draft = draft(for: session.id)
        guard sendMessage(session: session, content: draft) else { return false }
        submittedDrafts[session.id] = SubmittedDraft(
            revision: draftRevisions[session.id, default: 0],
            absorbIdenticalWrite: true
        )
        return true
    }

    func cancel(session: Session) {
        guard online, let macDeviceId else { sessionErrors[session.id] = "Mac is offline"; return }
        let operation = "cancel:\(session.id)"
        guard !activeSessionOperations.contains(operation) else { return }
        sessionErrors.removeValue(forKey: session.id)
        activeSessionOperations.insert(operation)
        send(type: "session.cancel", target: macDeviceId, projectId: session.projectId, sessionId: session.id,
             payload: [:], pending: .sessionCancel(session.projectId, session.id))
    }

    func respondToApproval(session: Session, interactionId: String, action: ApprovalAction) {
        respond(session: session, interactionId: interactionId,
                payload: ["kind": "approval", "interactionId": interactionId, "action": action.rawValue])
    }

    func respondToQuestion(session: Session, interactionId: String, optionIds: [String], freeText: String?) {
        var payload: [String: Any] = ["kind": "question", "interactionId": interactionId]
        if !optionIds.isEmpty { payload["optionIds"] = optionIds }
        if let freeText, !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["freeText"] = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard payload["optionIds"] != nil || payload["freeText"] != nil else { return }
        respond(session: session, interactionId: interactionId, payload: payload)
    }

    func isResponding(sessionId: String, interactionId: String) -> Bool {
        respondingInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func isSubmitted(sessionId: String, interactionId: String) -> Bool {
        submittedInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func isResolved(sessionId: String, interactionId: String) -> Bool {
        resolvedInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func isHistoricallyResolved(sessionId: String, interactionId: String) -> Bool {
        historicallyResolvedInteractions.contains(interactionKey(sessionId: sessionId, interactionId: interactionId))
    }

    func status(for session: Session) -> SessionStatus { eventSessionStatuses[session.id] ?? session.status }
    func sessionError(for sessionId: String) -> String? { recoveryErrors[sessionId] ?? sessionErrors[sessionId] }

    func requestFiles(projectId: String, relativePath: String) {
        let key = fileKey(projectId: projectId, path: relativePath)
        guard online, let macDeviceId else { directoryErrors[key] = "Mac is offline"; return }
        guard !loadingPaths.contains(key) else { return }
        directoryErrors.removeValue(forKey: key)
        loadingPaths.insert(key)
        send(type: "project.listFiles", target: macDeviceId, projectId: projectId,
             payload: ["relativePath": relativePath], pending: .directory(key))
    }

    func requestFile(projectId: String, relativePath: String, binary: Bool) {
        let key = fileKey(projectId: projectId, path: relativePath)
        guard online, let macDeviceId else { fileErrors[key] = "Mac is offline"; return }
        let isCached = binary ? imageCache.object(forKey: key as NSString) != nil : fileContents[key] != nil
        guard !isCached, !loadingFiles.contains(key) else { return }
        fileErrors.removeValue(forKey: key)
        if binary { activeImageKeys.insert(key) }
        loadingFiles.insert(key)
        send(type: "project.readFile", target: macDeviceId, projectId: projectId,
             payload: ["relativePath": relativePath, "encoding": binary ? "base64" : "utf8"],
             pending: binary ? .image(key) : .text(key))
    }

    func requestImages(projectId: String, relativePath: String) {
        let key = fileKey(projectId: projectId, path: relativePath)
        guard online, let macDeviceId else { imageListErrors[key] = "Mac is offline"; return }
        guard imageLists[key] == nil, !loadingImageLists.contains(key) else { return }
        imageListErrors.removeValue(forKey: key)
        loadingImageLists.insert(key)
        send(type: "project.listImages", target: macDeviceId, projectId: projectId,
             payload: ["relativePath": relativePath], pending: .imageList(key))
    }

    @discardableResult
    func searchFiles(projectId: String, query: String, limit: Int = 50) -> String? {
        guard let normalized = normalizedProjectFileSearchQuery(query) else { return nil }
        cancelFileSearch(projectId: projectId)
        guard online, let macDeviceId else {
            fileSearchErrors[projectId] = .init(message: "Mac is offline", code: "MAC_OFFLINE")
            return nil
        }
        let searchId = UUID().uuidString
        activeFileSearchIds[projectId] = searchId
        fileSearchErrors.removeValue(forKey: projectId)
        fileSearches.removeValue(forKey: projectId)
        loadingSearchProjects.insert(projectId)
        send(type: "project.searchFiles", target: macDeviceId, projectId: projectId,
             payload: ["searchId": searchId, "query": normalized, "limit": min(max(limit, 1), 100)],
             pending: .search(projectId, searchId, normalized))
        return searchId
    }

    func cancelFileSearch(projectId: String) {
        guard let searchId = activeFileSearchIds.removeValue(forKey: projectId) else { return }
        let requestIds = pendingRequests.compactMap { id, pending -> String? in
            guard case let .search(expectedProjectId, expectedSearchId, _) = pending,
                  expectedProjectId == projectId, expectedSearchId == searchId else { return nil }
            return id
        }
        for id in requestIds { finishPending(id, error: nil) }
        sendFileSearchCancellation(projectId: projectId, searchId: searchId)
    }

    func clearFileSearch(projectId: String) {
        cancelFileSearch(projectId: projectId)
        fileSearches.removeValue(forKey: projectId)
        fileSearchErrors.removeValue(forKey: projectId)
    }

    func fileSearchHistory(projectId: String) -> [String] {
        if let cached = fileSearchHistories[projectId] { return cached }
        guard let values = fileSearchHistoryStore?.load(projectId: projectId) else {
            fileSearchHistories[projectId] = []
            return []
        }
        let bounded = Array(values.prefix(10))
        fileSearchHistories[projectId] = bounded
        return bounded
    }

    func recordFileSearch(projectId: String, query: String) {
        guard let value = normalizedProjectFileSearchQuery(query) else { return }
        var history = fileSearchHistory(projectId: projectId).filter { $0.caseInsensitiveCompare(value) != .orderedSame }
        history.insert(value, at: 0)
        history = Array(history.prefix(10))
        updateFileSearchHistory(projectId: projectId, history: history)
    }

    func removeFileSearchHistory(projectId: String, query: String) {
        updateFileSearchHistory(
            projectId: projectId,
            history: fileSearchHistory(projectId: projectId).filter { $0 != query }
        )
    }

    func clearFileSearchHistory(projectId: String) {
        updateFileSearchHistory(projectId: projectId, history: [])
    }

    @discardableResult
    func requestChanges(projectId: String) -> Int {
        let generation = changesDiffLifecycle.beginChangesRequest(projectId: projectId)
        let prefix = changesDiffLifecycle.projectDiffPrefix(projectId: projectId)
        diffs = diffs.filter { !$0.key.hasPrefix(prefix) }
        diffErrors = diffErrors.filter { !$0.key.hasPrefix(prefix) }
        loadingDiffs = loadingDiffs.filter { !$0.hasPrefix(prefix) }
        guard online, let macDeviceId else {
            let error = RemoteRequestError(message: "Mac is offline", code: "MAC_OFFLINE")
            changesErrors[projectId] = error
            changesCompletions[projectId] = .init(generation: generation, outcome: .failed(error))
            return generation
        }
        changesErrors.removeValue(forKey: projectId)
        loadingChanges.insert(projectId)
        send(type: "project.listChanges", target: macDeviceId, projectId: projectId, payload: [:], pending: .changes(projectId, generation))
        return generation
    }

    func requestDiff(projectId: String, change: GitChange) {
        let key = diffKey(projectId: projectId, path: change.relativePath, area: change.area)
        guard diffs[key] == nil, !loadingDiffs.contains(key) else { return }
        guard online, let macDeviceId else { diffErrors[key] = .init(message: "Mac is offline", code: "MAC_OFFLINE"); return }
        diffErrors.removeValue(forKey: key)
        loadingDiffs.insert(key)
        send(type: "project.readDiff", target: macDeviceId, projectId: projectId,
             payload: ["relativePath": change.relativePath, "area": change.area.rawValue],
             pending: .diff(projectId, change.relativePath, change.area, changesDiffLifecycle.currentGeneration(projectId: projectId)))
    }

    func entries(projectId: String, path: String) -> [FileEntry]? { files[fileKey(projectId: projectId, path: path)] }
    func isLoading(projectId: String, path: String) -> Bool { loadingPaths.contains(fileKey(projectId: projectId, path: path)) }
    func fileContent(projectId: String, path: String) -> RemoteFileContent? { fileContents[fileKey(projectId: projectId, path: path)] }
    func imageList(projectId: String, path: String) -> RemoteImageList? { imageLists[fileKey(projectId: projectId, path: path)] }
    func image(projectId: String, path: String) -> UIImage? {
        _ = imageRevision
        return imageCache.object(forKey: fileKey(projectId: projectId, path: path) as NSString)
    }
    func directoryError(projectId: String, path: String) -> String? { directoryErrors[fileKey(projectId: projectId, path: path)] }
    func fileError(projectId: String, path: String) -> String? { fileErrors[fileKey(projectId: projectId, path: path)] }
    func imageListError(projectId: String, path: String) -> String? { imageListErrors[fileKey(projectId: projectId, path: path)] }
    func isLoadingFile(projectId: String, path: String) -> Bool { loadingFiles.contains(fileKey(projectId: projectId, path: path)) }
    func isLoadingImageList(projectId: String, path: String) -> Bool { loadingImageLists.contains(fileKey(projectId: projectId, path: path)) }
    func fileSearch(projectId: String) -> ProjectSearchFilesResponse? { fileSearches[projectId] }
    func fileSearchError(projectId: String) -> RemoteRequestError? { fileSearchErrors[projectId] }
    func isSearchingFiles(projectId: String) -> Bool { loadingSearchProjects.contains(projectId) }
    func changes(projectId: String) -> ProjectChangesResponse? { projectChanges[projectId] }
    func changesError(projectId: String) -> RemoteRequestError? { changesErrors[projectId] }
    func changesCompletion(projectId: String) -> ChangesRequestCompletion? { changesCompletions[projectId] }
    func isLoadingChanges(projectId: String) -> Bool { loadingChanges.contains(projectId) }
    func diff(projectId: String, change: GitChange) -> ProjectDiffResponse? { diffs[diffKey(projectId: projectId, path: change.relativePath, area: change.area)] }
    func diffError(projectId: String, change: GitChange) -> RemoteRequestError? { diffErrors[diffKey(projectId: projectId, path: change.relativePath, area: change.area)] }
    func isLoadingDiff(projectId: String, change: GitChange) -> Bool { loadingDiffs.contains(diffKey(projectId: projectId, path: change.relativePath, area: change.area)) }
    func releaseImages(projectId: String, paths: [String]) {
        let keys = Set(paths.map { fileKey(projectId: projectId, path: $0) })
        let requestIds = pendingRequests.compactMap { id, pending -> String? in
            guard case let .image(key) = pending, keys.contains(key) else { return nil }
            return id
        }
        for id in requestIds { finishPending(id, error: nil) }
        for key in keys {
            activeImageKeys.remove(key)
            imageCache.removeObject(forKey: key as NSString)
        }
        imageRevision += 1
    }

    private func connect(server: String, token: String) {
        guard var parts = URLComponents(string: server) else { return }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = "/connect"; parts.queryItems = [.init(name: "deviceId", value: deviceId)]
        guard let url = parts.url else { return }; var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        socket?.cancel(); let task = URLSession.shared.webSocketTask(with: request); socket = task; task.resume(); receive(task, server: server, token: token)
    }

    private func receive(_ task: URLSessionWebSocketTask, server: String, token: String) {
        task.receive { [weak self] result in Task { @MainActor in
            guard let self, self.socket === task else { return }
            switch result {
            case let .success(message):
                let data: Data? = switch message { case let .data(value): value; case let .string(value): Data(value.utf8); @unknown default: nil }
                if let data { await self.handle(data) }
                self.receive(task, server: server, token: token)
            case .failure:
                self.online = false
                self.failAllPending(message: "Connection lost")
                if task.closeCode.rawValue == 4003 {
                    self.dropPairing(server: server)
                    return
                }
                try? await Task.sleep(for: .seconds(1)); guard self.socket === task else { return }; self.connect(server: server, token: token)
            }
        } }
    }

    private func handle(_ data: Data) async {
        guard acceptingRelayMessages else { return }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = message["type"] as? String else { return }
        if type == "system.presence", let payload = message["payload"] as? [String: Any] {
            online = payload["online"] as? Bool ?? false
            macDeviceId = message["sourceDeviceId"] as? String
            if online { requestProjects(); resubscribeSessions(); resumeNotificationNavigationIfPossible() }
            else {
                failAllPending(message: "Mac is offline")
                resumeNotificationNavigationIfPossible()
            }
            return
        }
        let replyTo = message["replyTo"] as? String
        if let replyTo, pendingRequests[replyTo] == nil { return }
        if let replyTo, let pending = pendingRequests[replyTo],
           !matchesResponse(pending, type: type, source: message["sourceDeviceId"] as? String,
                            projectId: message["projectId"] as? String, sessionId: message["sessionId"] as? String) {
            finishPending(replyTo, error: "Invalid response")
            return
        }
        if message["ok"] as? Bool == false {
            let failure = message["error"] as? [String: Any]
            let errorMessage = failure?["message"] as? String ?? "Project request failed"
            let errorCode = failure?["code"] as? String ?? "PROJECT_REQUEST_FAILED"
            if let replyTo, let pending = pendingRequests[replyTo] {
                switch pending {
                case let .changes(projectId, generation) where changesDiffLifecycle.isCurrent(projectId: projectId, generation: generation):
                    let error = RemoteRequestError(message: errorMessage, code: errorCode)
                    changesErrors[projectId] = error
                    changesCompletions[projectId] = .init(generation: generation, outcome: .failed(error))
                    finishPending(replyTo, error: nil)
                case let .diff(projectId, path, area, generation) where changesDiffLifecycle.isCurrent(projectId: projectId, generation: generation):
                    diffErrors[diffKey(projectId: projectId, path: path, area: area)] = .init(message: errorMessage, code: errorCode)
                    finishPending(replyTo, error: nil)
                case let .search(projectId, searchId, _) where activeFileSearchIds[projectId] == searchId:
                    fileSearchErrors[projectId] = .init(message: errorMessage, code: errorCode)
                    finishPending(replyTo, error: nil)
                default:
                    finishPending(replyTo, error: errorMessage)
                }
            } else { error = errorMessage }
            return
        }
        guard let payload = message["payload"], JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            if let replyTo { finishPending(replyTo, error: "Invalid response") }
            return
        }
        if type == "agent.event", let source = message["sourceDeviceId"] as? String,
           let projectId = message["projectId"] as? String, let sessionId = message["sessionId"] as? String,
           let value = payload as? [String: Any], let sequence = value["sequence"] as? Int,
           let event = try? JSONDecoder().decode(AgentEvent.self, from: payloadData) {
            sessionOwnership.receive(event, sessionId: sessionId, projectId: projectId)
            if isPendingInteractionEvent(event) {
                var pending = pendingInteractionEvents[sessionId] ?? []
                pending.removeAll { $0.sequence == sequence }
                pending.append(event)
                pendingInteractionEvents[sessionId] = pending.sorted { $0.sequence < $1.sequence }
                sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
                rebuildDerivedSessionState(sessionId: sessionId, events: allSessionEvents(sessionId))
                sessionEventSequences[sessionId] = max(sessionEventSequences[sessionId] ?? -1, sequence)
                trimRecoveryState()
                scheduleRecoveryPersistence()
                send(type: "agent.event.ack", target: source, projectId: projectId, sessionId: sessionId, payload: ["sequence": sequence])
                return
            }
            var events = sessionEvents[sessionId] ?? []
            if events.last?.sequence == sequence {
                // A lost ACK can cause the Mac to redeliver the latest event.
            } else if events.last?.sequence ?? -1 < sequence {
                events.append(event)
                sessionEvents[sessionId] = events
                sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
                updateDerivedSessionState(event, sessionId: sessionId)
            } else if !events.contains(where: { $0.sequence == sequence }) {
                let index = events.firstIndex(where: { $0.sequence > sequence }) ?? events.endIndex
                events.insert(event, at: index)
                sessionEvents[sessionId] = events
                sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
                rebuildDerivedSessionState(sessionId: sessionId, events: allSessionEvents(sessionId))
            }
            sessionEventSequences[sessionId] = max(sessionEventSequences[sessionId] ?? -1, sequence)
            trimRecoveryState()
            scheduleRecoveryPersistence()
            send(type: "agent.event.ack", target: source, projectId: projectId, sessionId: sessionId, payload: ["sequence": sequence])
            return
        }
        var handled = false
        if type == "project.list.response", let response = try? JSONDecoder().decode(ProjectListPayload.self, from: payloadData) {
            if let replyTo, case .some(.projectList) = pendingRequests[replyTo] {
                projects = response.projects
                scheduleRecoveryPersistence()
                if replyTo == notificationProjectListRequestId, let intent = pendingNotificationIntent {
                    notificationProjectListRequestId = nil
                    guard response.projects.contains(where: { $0.id == intent.projectId }) else {
                        clearPendingNotification(message: "The notification project is no longer available. Showing projects instead.")
                        finishPending(replyTo, error: nil)
                        return
                    }
                    notificationValidatedProjectId = intent.projectId
                    requestNotificationSessions(projectId: intent.projectId)
                }
                handled = true
            }
        } else if type == "session.list.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(SessionListPayload.self, from: payloadData) {
            if let replyTo, case let .some(.sessionList(expectedProjectId)) = pendingRequests[replyTo], expectedProjectId == projectId {
                sessions[projectId] = response.sessions.sorted { $0.updatedAt > $1.updatedAt }
                if replyTo == notificationSessionListRequestId, let intent = pendingNotificationIntent,
                   intent.projectId == projectId {
                    notificationSessionListRequestId = nil
                    guard let target = response.sessions.first(where: { $0.id == intent.sessionId }) else {
                        clearPendingNotification(message: "The notification target is no longer available. Showing this project's sessions instead.", outcomeProjectId: projectId)
                        notificationNavigationRevision += 1
                        finishPending(replyTo, error: nil)
                        return
                    }
                    guard !intent.category.isWaiting || target.status == .waitingUser else {
                        clearPendingNotification(message: "That request has already been resolved. Showing this project's sessions instead.", outcomeProjectId: projectId)
                        notificationNavigationRevision += 1
                        finishPending(replyTo, error: nil)
                        return
                    }
                    notificationReadyProjectId = projectId
                    notificationNavigationRevision += 1
                }
                for session in response.sessions {
                    sessionProjects[session.id] = projectId
                    if isTerminal(session.status) {
                        subscribedSessionProjects.removeValue(forKey: session.id)
                    } else {
                        subscribedSessionProjects[session.id] = projectId
                    }
                }
                trimRecoveryState()
                scheduleRecoveryPersistence()
                handled = true
            }
        } else if type == "session.create.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(SessionCreatePayload.self, from: payloadData) {
            if let replyTo, case let .some(.sessionCreate(expectedProjectId)) = pendingRequests[replyTo], expectedProjectId == projectId {
                guard message["sessionId"] as? String == response.session.id else {
                    finishPending(replyTo, error: "Invalid response")
                    return
                }
                var values = sessions[projectId] ?? []
                values.removeAll { $0.id == response.session.id }
                values.insert(response.session, at: 0)
                sessions[projectId] = values
                trimRecoveryState()
                createdSession = response.session
                scheduleRecoveryPersistence()
                openSession(response.session)
                handled = true
            }
        } else if type == "session.getSnapshot.response", let projectId = message["projectId"] as? String,
                  let sessionId = message["sessionId"] as? String,
                  let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: payloadData) {
            if let replyTo, case let .some(.sessionSnapshot(expectedProjectId, expectedSessionId)) = pendingRequests[replyTo],
               expectedProjectId == projectId, expectedSessionId == sessionId,
               snapshot.session.id == sessionId, snapshot.session.projectId == projectId {
                applySnapshot(snapshot, projectId: projectId, sessionId: sessionId)
                handled = true
            }
        } else if type == "session.sendMessage.response" || type == "session.cancel.response" || type == "session.subscribe.response" || type == "interaction.respond.response" {
            handled = replyTo.flatMap { pendingRequests[$0] } != nil
        } else if type == "project.listFiles.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(FileListPayload.self, from: payloadData) {
            let key = fileKey(projectId: projectId, path: response.relativePath)
            if let replyTo, case let .some(.directory(expectedKey)) = pendingRequests[replyTo], expectedKey == key {
                files[key] = response.entries; handled = true
            }
        } else if type == "project.readFile.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(RemoteFileContent.self, from: payloadData) {
            let key = fileKey(projectId: projectId, path: response.relativePath)
            if let replyTo, response.encoding == .utf8,
               case let .some(.text(expectedKey)) = pendingRequests[replyTo], expectedKey == key {
                fileContents[key] = response
                handled = true
            } else if let replyTo, response.encoding == .base64,
                      case let .some(.image(expectedKey)) = pendingRequests[replyTo], expectedKey == key,
                      let decoded = await Task.detached(priority: .userInitiated, operation: { decodeImage(response.content) }).value {
                if activeImageKeys.contains(key) {
                    imageCache.setObject(decoded.image, forKey: key as NSString, cost: decoded.cost)
                    imageRevision += 1
                }
                handled = true
            }
        } else if type == "project.listImages.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(RemoteImageList.self, from: payloadData) {
            let key = fileKey(projectId: projectId, path: response.current.relativePath)
            if let replyTo, case let .some(.imageList(expectedKey)) = pendingRequests[replyTo], expectedKey == key {
                imageLists[key] = response; handled = true
            }
        } else if type == "project.searchFiles.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(ProjectSearchFilesResponse.self, from: payloadData) {
            if let replyTo, case let .some(.search(expectedProjectId, expectedSearchId, expectedQuery)) = pendingRequests[replyTo],
               expectedProjectId == projectId, expectedSearchId == response.searchId,
               expectedQuery == response.query, activeFileSearchIds[projectId] == response.searchId {
                fileSearches[projectId] = response
                handled = true
            }
        } else if type == "project.listChanges.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(ProjectChangesResponse.self, from: payloadData) {
            if let replyTo, case let .some(.changes(expectedProjectId, generation)) = pendingRequests[replyTo],
               expectedProjectId == projectId, changesDiffLifecycle.isCurrent(projectId: projectId, generation: generation) {
                projectChanges[projectId] = response
                changesCompletions[projectId] = .init(generation: generation, outcome: .succeeded)
                handled = true
            }
        } else if type == "project.readDiff.response", let projectId = message["projectId"] as? String,
                  let response = try? JSONDecoder().decode(ProjectDiffResponse.self, from: payloadData) {
            if let replyTo, case let .some(.diff(expectedProjectId, path, area, generation)) = pendingRequests[replyTo],
               expectedProjectId == projectId, path == response.change.relativePath, area == response.change.area,
               changesDiffLifecycle.isCurrent(projectId: projectId, generation: generation) {
                diffs[diffKey(projectId: projectId, path: path, area: area)] = response
                handled = true
            }
        }
        if let replyTo { finishPending(replyTo, error: handled ? nil : "Invalid response") }
    }

    @discardableResult
    private func send(type: String, target: String, projectId: String? = nil, sessionId: String? = nil,
                      payload: [String: Any], pending: PendingRequest? = nil, requestId: String? = nil) -> String {
        let id = requestId ?? UUID().uuidString
        var message: [String: Any] = ["version": 1, "id": id, "type": type, "sourceDeviceId": deviceId,
                                      "targetDeviceId": target, "timestamp": ISO8601DateFormatter().string(from: Date()), "payload": payload]
        if let projectId { message["projectId"] = projectId }
        if let sessionId { message["sessionId"] = sessionId }
        if let pending {
            pendingRequests[id] = pending
            pendingTimeouts[id] = Task { [weak self, requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                guard !Task.isCancelled else { return }
                self?.finishPending(id, error: "Request timed out")
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            if let pending { finishPending(id, error: "Not connected", clearInteractionSubmission: pending.isInteraction) }
            return id
        }
        if let scenarioRuntime {
            enqueueScenarioMessages(scenarioRuntime.receive(data))
            enqueueScenarioMessages(scenarioRuntime.drain())
            return id
        }
        guard let text = String(data: data, encoding: .utf8), let socket else {
            if let pending { finishPending(id, error: "Not connected", clearInteractionSubmission: pending.isInteraction) }
            return id
        }
        socket.send(.string(text)) { [weak self] sendError in
            guard let sendError else { return }
            Task { @MainActor in self?.finishPending(id, error: sendError.localizedDescription, clearInteractionSubmission: pending?.isInteraction == true) }
        }
        return id
    }

    private func finishPending(_ id: String, error message: String?, clearInteractionSubmission: Bool = false) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        let retryNotificationNavigation = id == notificationProjectListRequestId || id == notificationSessionListRequestId
        if id == notificationProjectListRequestId { notificationProjectListRequestId = nil }
        if id == notificationSessionListRequestId { notificationSessionListRequestId = nil }
        switch pending {
        case .projectList:
            if let message { error = message }
        case let .directory(key):
            loadingPaths.remove(key)
            if let message { directoryErrors[key] = message }
        case let .text(key), let .image(key):
            loadingFiles.remove(key)
            if let message { fileErrors[key] = message }
        case let .imageList(key):
            loadingImageLists.remove(key)
            if let message { imageListErrors[key] = message }
        case let .search(projectId, searchId, _):
            if let activeSearchId = activeFileSearchIds[projectId], activeSearchId != searchId { return }
            if activeFileSearchIds[projectId] == searchId { activeFileSearchIds.removeValue(forKey: projectId) }
            loadingSearchProjects.remove(projectId)
            if let message {
                fileSearchErrors[projectId] = .init(
                    message: message,
                    code: message == "Request timed out" ? "TIMEOUT" : "PROJECT_SEARCH_FAILED"
                )
                sendFileSearchCancellation(projectId: projectId, searchId: searchId)
            }
        case let .changes(projectId, generation):
            guard changesDiffLifecycle.isCurrent(projectId: projectId, generation: generation) else { return }
            loadingChanges.remove(projectId)
            if let message {
                let error = RemoteRequestError(message: message, code: message == "Request timed out" ? "TIMEOUT" : "PROJECT_REQUEST_FAILED")
                changesErrors[projectId] = error
                changesCompletions[projectId] = .init(generation: generation, outcome: .failed(error))
            }
        case let .diff(projectId, path, area, generation):
            let key = diffKey(projectId: projectId, path: path, area: area)
            loadingDiffs.remove(key)
            // A newer changes refresh already owns this project. Keep the error off the stale response so the open diff can ask again.
            guard changesDiffLifecycle.isCurrent(projectId: projectId, generation: generation) else { return }
            if let message { diffErrors[key] = .init(message: message, code: message == "Request timed out" ? "TIMEOUT" : "PROJECT_REQUEST_FAILED") }
        case let .sessionList(projectId):
            loadingSessionProjects.remove(projectId)
            if let message { sessionErrors[projectId] = message }
        case let .sessionCreate(projectId):
            activeSessionOperations.remove("create:\(projectId)")
            if let message { sessionErrors[projectId] = message }
        case let .sessionSend(_, sessionId):
            activeSessionOperations.remove("send:\(sessionId)")
            if let message { sessionErrors[sessionId] = message }
            else {
                eventSessionStatuses[sessionId] = .running
                if let submittedDraft = submittedDrafts[sessionId],
                   draftRevisions[sessionId, default: 0] == submittedDraft.revision {
                    sessionDrafts.removeValue(forKey: sessionId)
                    scheduleRecoveryPersistence()
                }
            }
            submittedDrafts.removeValue(forKey: sessionId)
        case let .sessionCancel(_, sessionId):
            activeSessionOperations.remove("cancel:\(sessionId)")
            if let message { sessionErrors[sessionId] = message }
        case let .sessionSnapshot(_, sessionId):
            snapshottingSessions.remove(sessionId)
            if message != nil { subscribingSessions.remove(sessionId) }
            if let message { sessionErrors[sessionId] = message }
        case let .sessionSubscribe(_, sessionId):
            subscribingSessions.remove(sessionId)
            if let message { sessionErrors[sessionId] = message }
            else { sessionErrors.removeValue(forKey: sessionId) }
        case let .interaction(_, sessionId, interactionId):
            let key = interactionKey(sessionId: sessionId, interactionId: interactionId)
            respondingInteractions.remove(key)
            if let message, message.localizedCaseInsensitiveContains("not pending") {
                sessionErrors.removeValue(forKey: sessionId)
                submittedInteractions.remove(key)
                resolvedInteractions.insert(key)
                removePendingInteraction(sessionId: sessionId, interactionId: interactionId)
            } else if let message {
                sessionErrors[sessionId] = message
                submittedInteractions.remove(key)
            }
            if clearInteractionSubmission { submittedInteractions.remove(key) }
            if message == nil {
                submittedInteractions.remove(key)
                resolvedInteractions.insert(key)
                removePendingInteraction(sessionId: sessionId, interactionId: interactionId)
            }
            persistRecoveryState()
        }
        if retryNotificationNavigation, message != nil {
            notificationReadyProjectId = nil
        }
    }

    private func failAllPending(message: String) {
        notificationProjectListRequestId = nil
        notificationSessionListRequestId = nil
        for id in Array(pendingRequests.keys) { finishPending(id, error: message) }
    }

    private func resubscribeSessions() {
        for (sessionId, projectId) in sessionOwnership.subscriptionCandidates() {
            requestSnapshot(sessionId: sessionId, projectId: projectId)
        }
    }

    private func respond(session: Session, interactionId: String, payload: [String: Any]) {
        guard online, let macDeviceId else { sessionErrors[session.id] = "Mac is offline"; return }
        let key = interactionKey(sessionId: session.id, interactionId: interactionId)
        guard !respondingInteractions.contains(key), !resolvedInteractions.contains(key) else { return }
        sessionErrors.removeValue(forKey: session.id)
        respondingInteractions.insert(key)
        submittedInteractions.insert(key)
        persistRecoveryState()
        send(type: "interaction.respond", target: macDeviceId, projectId: session.projectId, sessionId: session.id,
             payload: payload, pending: .interaction(session.projectId, session.id, interactionId))
    }

    private func sendFileSearchCancellation(projectId: String, searchId: String) {
        guard online, let macDeviceId else { return }
        send(type: "project.cancelSearch", target: macDeviceId, projectId: projectId,
             payload: ["searchId": searchId])
    }

    private func updateFileSearchHistory(projectId: String, history: [String]) {
        fileSearchHistories[projectId] = history
        fileSearchHistoryStore?.save(history, projectId: projectId)
    }

    private func subscribe(sessionId: String, projectId: String) {
        guard online, let macDeviceId else { sessionErrors[sessionId] = "Mac is offline"; return }
        guard !subscribingSessions.contains(sessionId) else { return }
        subscribingSessions.insert(sessionId)
        sessionErrors.removeValue(forKey: sessionId)
        let afterSequence = sessionEventSequences[sessionId] ?? -1
        send(type: "session.subscribe", target: macDeviceId, projectId: projectId, sessionId: sessionId,
             payload: ["afterSequence": afterSequence], pending: .sessionSubscribe(projectId, sessionId))
    }

    private func requestSnapshot(sessionId: String, projectId: String) {
        guard online, let macDeviceId else { sessionErrors[sessionId] = "Mac is offline"; return }
        guard !snapshottingSessions.contains(sessionId) else { return }
        snapshottingSessions.insert(sessionId)
        subscribingSessions.insert(sessionId)
        sessionErrors.removeValue(forKey: sessionId)
        send(type: "session.getSnapshot", target: macDeviceId, projectId: projectId, sessionId: sessionId,
             payload: [:], pending: .sessionSnapshot(projectId, sessionId))
    }

    private func applySnapshot(_ snapshot: SessionSnapshot, projectId: String, sessionId: String) {
        var projectSessions = sessions[projectId] ?? []
        projectSessions.removeAll { $0.id == sessionId }
        projectSessions.append(snapshot.session)
        sessions[projectId] = projectSessions.sorted { $0.updatedAt > $1.updatedAt }

        let events = snapshot.recentEvents
        sessionEvents[sessionId] = events
        pendingInteractionEvents[sessionId] = snapshot.pendingInteractions.map(\.event)
        sessionEventSequences[sessionId] = snapshot.latestSequence
        eventSessionStatuses[sessionId] = snapshot.currentStatus
        sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
        rebuildDerivedSessionState(sessionId: sessionId, events: allSessionEvents(sessionId))
        eventSessionStatuses[sessionId] = snapshot.currentStatus
        sessionProjects[sessionId] = projectId
        if isTerminal(snapshot.currentStatus) {
            subscribedSessionProjects.removeValue(forKey: sessionId)
        } else {
            subscribedSessionProjects[sessionId] = projectId
        }

        let pendingKeys = Set(snapshot.pendingInteractions.map {
            interactionKey(sessionId: sessionId, interactionId: $0.interactionId)
        })
        submittedInteractions.subtract(pendingKeys)
        resolvedInteractions.subtract(pendingKeys)
        trimRecoveryState()
        persistRecoveryState()
        subscribingSessions.remove(sessionId)
        if !isTerminal(snapshot.currentStatus) {
            subscribe(sessionId: sessionId, projectId: projectId)
        }
    }

    private func scheduleRecoveryPersistence() {
        guard scenarioRuntime == nil else { return }
        recoveryPersistenceTask?.cancel()
        recoveryPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persistRecoveryState()
        }
    }

    private func persistRecoveryState() {
        guard scenarioRuntime == nil else { return }
        trimRecoveryState()
        let cache = recoveryCache().trimmedForPersistence(activeSessionId: activeSessionId)
        if let data = try? JSONEncoder().encode(cache), !MobileRecoveryPersistence.exceedsBudget(cache) {
            UserDefaults.standard.set(data, forKey: "mobileRecoveryCache")
            recoveryErrors = MobileRecoveryErrorState.clearingAll(recoveryErrors)
        } else {
            UserDefaults.standard.removeObject(forKey: "mobileRecoveryCache")
            let affectedSessionIds = MobileRecoveryPersistence.pendingSessionIds(in: cache)
            if !affectedSessionIds.isEmpty {
                recoveryErrors = MobileRecoveryErrorState.recording(recoveryErrors, cache: cache)
            }
        }
    }

    func waitForScenarioIdle() async {
        while let task = scenarioDeliveryTask {
            let revision = scenarioDeliveryRevision
            await task.value
            guard revision == scenarioDeliveryRevision else { continue }
            guard let scenarioRuntime else { return }
            let messages = scenarioRuntime.drain()
            guard !messages.isEmpty else { return }
            enqueueScenarioMessages(messages)
        }
    }

#if DEBUG
    func injectScenarioInbound(_ messages: [Data]) {
        guard scenarioRuntime != nil else { return }
        enqueueScenarioMessages(messages)
    }
#endif

    private func enqueueScenarioMessages(_ messages: [Data]) {
        guard !messages.isEmpty else { return }
        let previous = scenarioDeliveryTask
        scenarioDeliveryRevision += 1
        scenarioDeliveryTask = Task { @MainActor [weak self] in
            await previous?.value
            // Preserve the real socket's asynchronous boundary so UI controls finish their action before a response mutates them.
            try? await Task.sleep(for: .milliseconds(25))
            guard let self else { return }
            for message in messages {
                await self.handle(message)
            }
        }
    }

    private func trimRecoveryState() {
        let activeProjectId = activeSessionId.flatMap { projectId(for: $0) }
        var retainedProjectIds = MobileRecoveryRetention.retaining(
            orderedProjectIds(),
            limit: MobileRecoveryLimits.projectCount,
            protectedId: activeProjectId
        )
        let pendingSessionIds = Set(pendingInteractionEvents.compactMap { $0.value.isEmpty ? nil : $0.key })
        retainedProjectIds.formUnion(pendingSessionIds.compactMap { projectId(for: $0) })
        for projectId in Set(projects.map(\.id)).subtracting(retainedProjectIds) {
            removeRecoveryProject(projectId)
        }
        projects = projects.filter { retainedProjectIds.contains($0.id) }
        let listedSessionIdsBeforeTrim = Set(sessions.values.flatMap { $0.map(\.id) })
        sessions = sessions.reduce(into: [:]) { result, item in
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

        let listedSessionIdsAfterTrim = Set(sessions.values.flatMap { $0.map(\.id) })
        let evictedListedSessionIds = listedSessionIdsBeforeTrim.subtracting(listedSessionIdsAfterTrim)
        let sessionIdsInRetainedProjects = listedSessionIdsAfterTrim
            .union(sessionProjects.compactMap { retainedProjectIds.contains($0.value) ? $0.key : nil })
            .subtracting(evictedListedSessionIds)
        var retainedSessionIds = MobileRecoveryRetention.retaining(
            orderedSessionIds().filter { sessionIdsInRetainedProjects.contains($0) },
            limit: MobileRecoveryLimits.sessionCount,
            protectedId: activeSessionId
        )
        retainedSessionIds.formUnion(pendingSessionIds)
        sessionProjects = sessionProjects.filter { retainedSessionIds.contains($0.key) }
        subscribedSessionProjects = subscribedSessionProjects.filter { retainedSessionIds.contains($0.key) }
        sessionEvents = sessionEvents.reduce(into: [:]) { result, item in
            guard retainedSessionIds.contains(item.key) else { return }
            result[item.key] = Array(item.value
                .filter { encodedSize(of: $0) <= MobileRecoveryLimits.maximumEventBytes }
                .suffix(MobileRecoveryLimits.eventsPerSession))
        }
        pendingInteractionEvents = pendingInteractionEvents.filter { retainedSessionIds.contains($0.key) }
        sessionFeedItems = Set(sessionEvents.keys).union(pendingInteractionEvents.keys).reduce(into: [:]) { result, sessionId in
            result[sessionId] = feedItems(allSessionEvents(sessionId))
        }
        sessionEventSequences = sessionEventSequences.filter { retainedSessionIds.contains($0.key) }
        eventSessionStatuses = eventSessionStatuses.filter { retainedSessionIds.contains($0.key) }
        pendingEventInteractions = pendingEventInteractions.filter { retainedSessionIds.contains($0.key) }
        snapshottingSessions.formIntersection(retainedSessionIds)
        subscribingSessions.formIntersection(retainedSessionIds)
        workspaceNavigations = workspaceNavigations.filter { retainedSessionIds.contains($0.key) }
        sessionDrafts = sessionDrafts.filter { retainedSessionIds.contains($0.key) && !$0.value.isEmpty }
        expandedReportIds = expandedReportIds.reduce(into: [:]) { result, item in
            guard retainedSessionIds.contains(item.key) else { return }
            let retained = Array(item.value.suffix(MobileRecoveryLimits.expandedReportsPerSession))
            if !retained.isEmpty { result[item.key] = retained }
        }
        fileBrowserNavigations = fileBrowserNavigations.reduce(into: [:]) { result, item in
            guard retainedProjectIds.contains(item.key) else { return }
            result[item.key] = item.value.trimmed()
        }
        trimInteractionStates(retainedSessionIds: retainedSessionIds)
        trimRecoveryBytes()
    }

    private func orderedProjectIds() -> [String] {
        var ids = projects.map(\.id)
        ids.append(contentsOf: sessions.keys.sorted())
        ids.append(contentsOf: sessionProjects.values.sorted())
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func orderedSessionIds() -> [String] {
        let sessionsById = sessions.values.flatMap { $0 }.reduce(into: [String: Session]()) { result, session in
            if let current = result[session.id], current.updatedAt >= session.updatedAt { return }
            result[session.id] = session
        }
        let ids = Set(sessionProjects.keys).union(Set(sessionEvents.keys)).union(Set(sessionsById.keys))
            .union(sessionDrafts.keys)
        let ordered = ids.sorted { lhs, rhs in
            let lhsSession = sessionsById[lhs]
            let rhsSession = sessionsById[rhs]
            let lhsUpdatedAt = lhsSession?.updatedAt ?? ""
            let rhsUpdatedAt = rhsSession?.updatedAt ?? ""
            if lhsUpdatedAt != rhsUpdatedAt { return lhsUpdatedAt > rhsUpdatedAt }
            let lhsSequence = sessionEvents[lhs]?.last?.sequence ?? -1
            let rhsSequence = sessionEvents[rhs]?.last?.sequence ?? -1
            if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
            return lhs < rhs
        }
        guard let activeSessionId, ordered.contains(activeSessionId) else { return ordered }
        return [activeSessionId] + ordered.filter { $0 != activeSessionId }
    }

    private func trimInteractionStates(retainedSessionIds: Set<String>? = nil) {
        let ids = retainedSessionIds ?? Set(sessionProjects.keys)
        func retain(_ values: Set<String>) -> Set<String> {
            Set(values.filter { key in ids.contains { key.hasPrefix("\($0):") } }
                .sorted().prefix(MobileRecoveryLimits.interactionCount))
        }
        submittedInteractions = retain(submittedInteractions)
        resolvedInteractions = retain(resolvedInteractions)
        historicallyResolvedInteractions = retain(historicallyResolvedInteractions)
        respondingInteractions = retain(respondingInteractions)
        pendingEventInteractions = pendingEventInteractions.reduce(into: [:]) { result, item in
            guard ids.contains(item.key) else { return }
            result[item.key] = retain(item.value)
        }
    }

    private func rawEncodedRecoveryCache() -> Data? {
        try? JSONEncoder().encode(recoveryCache())
    }

    private func recoveryCache() -> MobileRecoveryCache {
        MobileRecoveryCache(
            projects: projects,
            sessions: sessions,
            sessionEvents: sessionEvents,
            pendingInteractions: pendingInteractionEvents,
            sessionProjects: sessionProjects,
            workspaceNavigations: workspaceNavigations,
            fileBrowserNavigations: fileBrowserNavigations,
            sessionDrafts: sessionDrafts,
            expandedReportIds: expandedReportIds,
            submittedInteractions: submittedInteractions.sorted(),
            resolvedInteractions: resolvedInteractions.sorted()
        )
    }

    private func encodedSize(of event: AgentEvent) -> Int {
        (try? JSONEncoder().encode(event).count) ?? Int.max
    }

    private func trimRecoveryBytes() {
        while let data = rawEncodedRecoveryCache(), data.count > MobileRecoveryLimits.persistenceByteBudget {
            let protectedSessionIds = Set(pendingInteractionEvents.compactMap { $0.value.isEmpty ? nil : $0.key })
            if let sessionId = expandedReportIds.keys.sorted().last {
                expandedReportIds.removeValue(forKey: sessionId)
                continue
            }
            if let sessionId = orderedSessionIds().reversed().first(where: { !(sessionEvents[$0] ?? []).isEmpty }) {
                sessionEvents[sessionId]?.removeFirst()
                sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
                continue
            }
            if let sessionId = orderedSessionIds().reversed().first(where: { !protectedSessionIds.contains($0) && $0 != activeSessionId }) {
                removeRecoverySession(sessionId)
                continue
            }
            if let sessionId = workspaceNavigations.keys.sorted().reversed().first(where: { $0 != activeSessionId }) {
                workspaceNavigations.removeValue(forKey: sessionId)
                continue
            }
            if let sessionId = workspaceNavigations.keys.sorted().last {
                workspaceNavigations.removeValue(forKey: sessionId)
                continue
            }
            if let projectId = fileBrowserNavigations.keys.sorted().last {
                fileBrowserNavigations.removeValue(forKey: projectId)
                continue
            }
            if let sessionId = sessionDrafts.keys.sorted().reversed().first(where: { $0 != activeSessionId }) {
                sessionDrafts.removeValue(forKey: sessionId)
                continue
            }
            if let sessionId = sessionDrafts.keys.sorted().last {
                sessionDrafts.removeValue(forKey: sessionId)
                continue
            }
            if let key = submittedInteractions.sorted().last {
                submittedInteractions.remove(key)
                continue
            }
            if let key = resolvedInteractions.sorted().last {
                resolvedInteractions.remove(key)
                continue
            }
            let protectedProjectIds = Set(protectedSessionIds.compactMap { projectId(for: $0) })
            if let projectId = orderedProjectIds().reversed().first(where: {
                !protectedProjectIds.contains($0) && $0 != activeSessionId.flatMap({ projectId(for: $0) })
            }) {
                removeRecoveryProject(projectId)
                continue
            }
            break
        }
    }

    private func removeRecoverySession(_ sessionId: String) {
        sessionProjects.removeValue(forKey: sessionId)
        subscribedSessionProjects.removeValue(forKey: sessionId)
        sessionEvents.removeValue(forKey: sessionId)
        pendingInteractionEvents.removeValue(forKey: sessionId)
        recoveryErrors = MobileRecoveryErrorState.clearing(recoveryErrors, sessionId: sessionId)
        sessionFeedItems.removeValue(forKey: sessionId)
        sessionEventSequences.removeValue(forKey: sessionId)
        eventSessionStatuses.removeValue(forKey: sessionId)
        pendingEventInteractions.removeValue(forKey: sessionId)
        workspaceNavigations.removeValue(forKey: sessionId)
        sessionDrafts.removeValue(forKey: sessionId)
        expandedReportIds.removeValue(forKey: sessionId)
        draftRevisions.removeValue(forKey: sessionId)
        submittedDrafts.removeValue(forKey: sessionId)
        snapshottingSessions.remove(sessionId)
        subscribingSessions.remove(sessionId)
        for projectId in Array(sessions.keys) {
            sessions[projectId]?.removeAll { $0.id == sessionId }
            if sessions[projectId]?.isEmpty == true { sessions.removeValue(forKey: projectId) }
        }
        let prefix = "\(sessionId):"
        submittedInteractions = Set(submittedInteractions.filter { !$0.hasPrefix(prefix) })
        resolvedInteractions = Set(resolvedInteractions.filter { !$0.hasPrefix(prefix) })
        historicallyResolvedInteractions = Set(historicallyResolvedInteractions.filter { !$0.hasPrefix(prefix) })
        respondingInteractions = Set(respondingInteractions.filter { !$0.hasPrefix(prefix) })
    }

    private func removeRecoveryProject(_ projectId: String) {
        let sessionIds = Set(sessions[projectId]?.map(\.id) ?? [])
            .union(sessionProjects.compactMap { $0.value == projectId ? $0.key : nil })
        for sessionId in sessionIds { removeRecoverySession(sessionId) }
        projects.removeAll { $0.id == projectId }
        sessions.removeValue(forKey: projectId)
        fileBrowserNavigations.removeValue(forKey: projectId)
    }

    private func updateDerivedSessionState(_ event: AgentEvent, sessionId: String) {
        switch event {
        case let .status(value):
            eventSessionStatuses[sessionId] = switch value.status { case .running: .running; case .idle: .idle; case .waitingUser: .waitingUser }
            if value.status == .running || value.status == .idle { resolvePendingEventInteractions(sessionId: sessionId) }
        case .turnCompleted:
            eventSessionStatuses[sessionId] = .idle
            resolvePendingEventInteractions(sessionId: sessionId)
        case let .sessionCompleted(value):
            eventSessionStatuses[sessionId] = switch value.outcome { case .completed: .completed; case .failed: .failed; case .cancelled: .cancelled }
            resolvePendingEventInteractions(sessionId: sessionId)
        case let .approvalRequested(value):
            pendingEventInteractions[sessionId, default: []].insert(interactionKey(sessionId: sessionId, interactionId: value.interactionId))
        case let .questionRequested(value):
            pendingEventInteractions[sessionId, default: []].insert(interactionKey(sessionId: sessionId, interactionId: value.interactionId))
        default: break
        }
    }

    private func rebuildDerivedSessionState(sessionId: String, events: [AgentEvent]) {
        eventSessionStatuses.removeValue(forKey: sessionId)
        pendingEventInteractions[sessionId] = []
        historicallyResolvedInteractions = Set(historicallyResolvedInteractions.filter { !$0.hasPrefix("\(sessionId):") })
        for event in events { updateDerivedSessionState(event, sessionId: sessionId) }
    }

    private func resolvePendingEventInteractions(sessionId: String) {
        historicallyResolvedInteractions.formUnion(pendingEventInteractions[sessionId] ?? [])
        pendingEventInteractions[sessionId] = []
        pendingInteractionEvents = MobilePendingInteractionRecovery.clearing(pendingInteractionEvents, sessionId: sessionId)
        recoveryErrors = MobileRecoveryErrorState.clearing(recoveryErrors, sessionId: sessionId)
        sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
    }

    private func removePendingInteraction(sessionId: String, interactionId: String) {
        pendingInteractionEvents = MobilePendingInteractionRecovery.removing(
            pendingInteractionEvents,
            sessionId: sessionId,
            interactionId: interactionId
        )
        if pendingInteractionEvents[sessionId]?.isEmpty != false {
            recoveryErrors = MobileRecoveryErrorState.clearing(recoveryErrors, sessionId: sessionId)
        }
        sessionFeedItems[sessionId] = feedItems(allSessionEvents(sessionId))
    }

    private func allSessionEvents(_ sessionId: String) -> [AgentEvent] {
        let events = (sessionEvents[sessionId] ?? []) + (pendingInteractionEvents[sessionId] ?? [])
        var bySequence = [Int: AgentEvent]()
        for event in events { bySequence[event.sequence] = event }
        return bySequence.values.sorted { $0.sequence < $1.sequence }
    }

    private func matchesResponse(_ pending: PendingRequest, type: String, source: String?, projectId: String?, sessionId: String?) -> Bool {
        guard type == pending.responseType, source == macDeviceId else { return false }
        switch pending {
        case .projectList:
            return projectId == nil && sessionId == nil
        case .directory, .text, .image, .imageList:
            return projectId != nil
        case let .search(expectedProjectId, _, _):
            return projectId == expectedProjectId && sessionId == nil
        case let .changes(expectedProjectId, _), let .diff(expectedProjectId, _, _, _):
            return projectId == expectedProjectId && sessionId == nil
        case let .sessionList(expectedProjectId), let .sessionCreate(expectedProjectId):
            return projectId == expectedProjectId
        case let .sessionSend(expectedProjectId, expectedSessionId), let .sessionCancel(expectedProjectId, expectedSessionId):
            return projectId == expectedProjectId && sessionId == expectedSessionId
        case let .sessionSnapshot(expectedProjectId, expectedSessionId), let .sessionSubscribe(expectedProjectId, expectedSessionId):
            return projectId == expectedProjectId && sessionId == expectedSessionId
        case let .interaction(expectedProjectId, expectedSessionId, _):
            return projectId == expectedProjectId && sessionId == expectedSessionId
        }
    }

    private func fileKey(projectId: String, path: String) -> String { "\(projectId):\(path)" }
    private func diffKey(projectId: String, path: String, area: GitChangeArea) -> String { changesDiffLifecycle.diffKey(projectId: projectId, path: path, area: area) }
    private func interactionKey(sessionId: String, interactionId: String) -> String { "\(sessionId):\(interactionId)" }

    private func projectId(for sessionId: String) -> String? {
        sessionProjects[sessionId]
            ?? sessions.values.lazy.flatMap({ $0 }).first(where: { $0.id == sessionId })?.projectId
    }
}


private func decodeImage(_ base64: String) -> DecodedImage? {
    guard let data = Data(base64Encoded: base64),
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true,
              kCGImageSourceThumbnailMaxPixelSize: 2048,
          ] as CFDictionary) else { return nil }
    return .init(image: UIImage(cgImage: image), cost: image.bytesPerRow * image.height)
}

private func isSecure(_ url: URL) -> Bool { url.scheme == "https" || (url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")) }

private func notice(for category: NotificationCategory) -> String {
    switch category {
    case .approvalWaiting: "An Agent session is waiting for approval."
    case .questionWaiting: "An Agent session is waiting for an answer."
    case .taskCompleted: "An Agent task completed."
    case .taskFailed: "An Agent task failed."
    }
}

private func isPendingInteractionEvent(_ event: AgentEvent) -> Bool {
    if case .approvalRequested = event { return true }
    if case .questionRequested = event { return true }
    return false
}
