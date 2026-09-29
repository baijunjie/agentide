import AgentIDEProtocol
import SwiftUI

enum WorkspaceChangesRestore {
    static func needsRefresh(for level: WorkspaceLevel) -> Bool {
        switch level {
        case .changes, .diff:
            true
        case .session, .browser, .file:
            false
        }
    }
}

struct ChangedFileNavigationCoordinator: Equatable {
    struct Pending: Equatable {
        let path: String
        let generation: Int
    }

    private(set) var pending: Pending?

    mutating func begin(path: String, generation: Int) {
        pending = .init(path: path, generation: generation)
    }

    mutating func consume(
        completion: ChangesRequestCompletion?,
        response: ProjectChangesResponse?
    ) -> GitChange? {
        guard let pending, completion?.generation == pending.generation else { return nil }
        self.pending = nil
        guard case .succeeded = completion?.outcome else { return nil }
        return response?.changes.first { $0.relativePath == pending.path }
    }
}

extension AgentEvent {
    var sequence: Int {
        switch self {
        case let .sessionStarted(event): event.sequence
        case let .textDelta(event): event.sequence
        case let .message(event): event.sequence
        case let .toolStarted(event): event.sequence
        case let .toolFinished(event): event.sequence
        case let .command(event): event.sequence
        case let .fileChanged(event): event.sequence
        case let .approvalRequested(event): event.sequence
        case let .questionRequested(event): event.sequence
        case let .status(event): event.sequence
        case let .error(event): event.sequence
        case let .turnCompleted(event): event.sequence
        case let .sessionCompleted(event): event.sequence
        case let .report(event): event.sequence
        }
    }
}

struct SessionListView: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    @State private var creating = false
    @State private var selectedSession: Session?
    @State private var showingSession = false

    var body: some View {
        List {
            if connection.loadingSessionProjects.contains(project.id), connection.sessions[project.id] == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error = connection.sessionErrors[project.id] {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { connection.requestSessions(projectId: project.id) }
                    }
                }
            }
            Section("Sessions") {
                let sessions = connection.sessions[project.id] ?? []
                if sessions.isEmpty, !connection.loadingSessionProjects.contains(project.id) {
                    ContentUnavailableView("No Sessions", systemImage: "bubble.left.and.bubble.right", description: Text("Create a session to start working with an agent."))
                }
                ForEach(sessions, id: \.id) { session in
                    Button {
                        selectedSession = session
                        showingSession = true
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { FileBrowserView(project: project) } label: { Image(systemName: "folder") }
                    .accessibilityLabel("Browse files")
                NavigationLink { ChangesView(project: project) } label: { Image(systemName: "arrow.triangle.branch") }
                    .accessibilityLabel("Changes")
                    .accessibilityIdentifier("session-list-changes")
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Create session")
                    .disabled(!connection.online || project.enabledAgents.isEmpty)
            }
        }
        .refreshable { connection.requestSessions(projectId: project.id) }
        .sheet(isPresented: $creating) { NewSessionView(project: project) }
        .navigationDestination(isPresented: $showingSession) {
            if let selectedSession { AgentSessionView(project: project, session: selectedSession) }
        }
        .task { connection.requestSessions(projectId: project.id) }
        .onChange(of: connection.createdSession?.id) {
            guard let session = connection.createdSession, session.projectId == project.id else { return }
            creating = false
            selectedSession = session
            showingSession = true
            connection.createdSession = nil
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var connection: MobileConnection
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.agentType == .codex ? "terminal" : "sparkles")
                .frame(width: 28, height: 28)
                .foregroundStyle(session.agentType == .codex ? .blue : .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.headline).lineLimit(2)
                Text(session.agentType.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: connection.status(for: session))
        }
        .contentShape(Rectangle())
    }
}

private struct NewSessionView: View {
    @EnvironmentObject private var connection: MobileConnection
    @Environment(\.dismiss) private var dismiss
    let project: RemoteProject
    @State private var agentType: AgentType
    @State private var initialTask = ""

    init(project: RemoteProject) {
        self.project = project
        _agentType = State(initialValue: project.enabledAgents.first ?? .codex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: $agentType) {
                    ForEach(project.enabledAgents, id: \.rawValue) { agent in
                        Text(agent.rawValue.capitalized).tag(agent)
                    }
                }
                Section("Initial Task") {
                    ZStack(alignment: .topLeading) {
                        if initialTask.isEmpty {
                            Text("For example, fix the failing test")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $initialTask)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel("Initial task")
                            .frame(minHeight: 160)
                    }
                    if initialTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter a task to create the session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = connection.sessionErrors[project.id] {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { connection.createSession(projectId: project.id, agentType: agentType, initialTask: initialTask) }
                        .disabled(initialTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.activeSessionOperations.contains("create:\(project.id)"))
                }
            }
        }
    }
}

private struct AgentSessionView: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    let session: Session
    @State private var workspace = WorkspaceNavigationState()
    @State private var changedFileNavigation = ChangedFileNavigationCoordinator()

    init(project: RemoteProject, session: Session) {
        self.project = project
        self.session = session
    }

    private var events: [AgentEvent] { connection.sessionEvents[session.id] ?? [] }
    private var status: SessionStatus { connection.status(for: session) }
    private var isSending: Bool { connection.activeSessionOperations.contains("send:\(session.id)") }

    var body: some View {
        WorkspaceNavigationContainer(navigation: $workspace) { navigationInset in
            sessionContent(topClearance: navigationInset)
        } browserContent: {
            FileBrowserContent(
                project: project,
                openText: { selection in
                    workspace.prepareFile(selection)
                    // Mount the file layer offscreen for one render pass so its spatial properties animate instead of appearing at their final values.
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
                            workspace.activatePreparedFile()
                        }
                    }
                },
                openImage: { workspace.showImage($0) }
            )
        } fileContent: { selection in
            TextFileViewer(selection: selection, sendToAgent: addReferenceToDraft)
        } changesContent: {
            ChangesWorkspaceContent(project: project) { change in
                connection.requestDiff(projectId: project.id, change: change)
                workspace.prepareDiff(change)
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
                        workspace.activatePreparedDiff()
                    }
                }
            }
        } diffContent: { change in
            DiffViewer(project: project, change: change)
        }
        .navigationTitle(workspaceTitle)
        .navigationBarTitleDisplayMode(.inline)
        // The system back item pops this whole session. Spatial levels have to take that button over.
        .navigationBarBackButtonHidden(workspace.level != .session)
        .background(NavigationPopGuard(enabled: workspace.level == .session))
        .toolbar {
            if workspace.level != .session {
                ToolbarItem(placement: .topBarLeading) {
                    Button { retreatOneLevel() } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("Back")
                }
            }
            if workspace.level == .session {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
                            workspace.showBrowser()
                        }
                    } label: { Image(systemName: "folder") }
                    .accessibilityLabel("Browse files")
                    .accessibilityIdentifier("session-browse-files")
                    Button {
                        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
                            workspace.showChanges()
                        }
                        connection.requestChanges(projectId: project.id)
                    } label: { Image(systemName: "arrow.triangle.branch") }
                        .accessibilityLabel("Changes")
                        .accessibilityIdentifier("session-changes")
                }
            }
        }
        .fullScreenCover(item: $workspace.fullScreenImage) {
            ImageViewer(selection: $0, sendToAgent: addReferenceToDraft)
        }
        .task {
            workspace = connection.workspaceNavigation(for: session.id)
            connection.openSession(session)
            if WorkspaceChangesRestore.needsRefresh(for: workspace.level) {
                connection.requestChanges(projectId: project.id)
            }
        }
        .onChange(of: workspace) { connection.persistWorkspaceNavigation(workspace, for: session.id) }
        .onReceive(connection.$changesCompletions) { completions in
            completeChangedFileNavigation(completions[project.id])
        }
    }

    private var workspaceTitle: String {
        switch workspace.level {
        case .session: session.title
        case .browser: project.name
        case let .file(selection): selection.name
        case .changes: "Changes"
        case let .diff(change): change.relativePath
        }
    }

    private func sessionContent(topClearance: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if !pendingAttention.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(pendingAttention) { item in
                                    Button {
                                        proxy.scrollTo(item.id, anchor: .top)
                                    } label: {
                                        Label(item.label, systemImage: item.symbol)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier(item.identifier)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                        .background(.bar)
                        Divider()
                    }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        StatusBadge(status: status)
                            .accessibilityIdentifier("session-status")
                        if events.isEmpty {
                            if connection.subscribingSessions.contains(session.id) {
                                ProgressView("Loading activity…").frame(maxWidth: .infinity).padding(.top, 40)
                            } else {
                                ContentUnavailableView("No Activity", systemImage: "clock.arrow.circlepath", description: Text("Retry to load this session's event history."))
                                Button("Retry") { connection.openSession(session) }.buttonStyle(.borderedProminent)
                            }
                        }
                        ForEach(connection.sessionFeedItems[session.id] ?? []) { item in
                            FeedBlock(
                                item: item,
                                session: session,
                                project: project,
                                openChangedFile: openChangedFile,
                                openReportFile: openReportFile
                            ).id(item.id)
                        }
                        if let error = connection.sessionError(for: session.id) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .padding(12)
                                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
                .accessibilityIdentifier("session-feed")
                .onChange(of: events.last?.sequence) {
                    guard let id = connection.sessionFeedItems[session.id]?.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
            if let sendBlockedReason {
                Text(sendBlockedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message the agent", text: draftBinding, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("session-composer")
                    .disabled(!canSend(status) || isSending)
                if status == .running {
                    Button { connection.cancel(session: session) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Cancel current turn")
                } else {
                    Button {
                        connection.sendDraft(session: session)
                    } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.draft(for: session.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSend(status) || !connection.online || isSending)
                    .accessibilityLabel("Send message")
                }
            }
            }
            .padding()
        }
        .padding(.top, topClearance)
    }

    private struct PendingAttention: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let identifier: String
    }

    private var pendingAttention: [PendingAttention] {
        (connection.sessionFeedItems[session.id] ?? []).compactMap { item in
            guard case let .event(event) = item.content else { return nil }
            switch event {
            case let .questionRequested(value):
                guard interactionNeedsAttention(value.interactionId) else { return nil }
                return PendingAttention(id: item.id, label: "Answer question", symbol: "questionmark.bubble", identifier: "pending-question")
            case let .approvalRequested(value):
                guard interactionNeedsAttention(value.interactionId) else { return nil }
                return PendingAttention(id: item.id, label: "Review approval", symbol: "checkmark.shield", identifier: "pending-approval")
            default:
                return nil
            }
        }
    }

    private func interactionNeedsAttention(_ interactionId: String) -> Bool {
        !connection.isHistoricallyResolved(sessionId: session.id, interactionId: interactionId)
            && !connection.isSubmitted(sessionId: session.id, interactionId: interactionId)
            && !connection.isResolved(sessionId: session.id, interactionId: interactionId)
            && !connection.isResponding(sessionId: session.id, interactionId: interactionId)
    }

    private var sendBlockedReason: String? {
        if !connection.online { return "Mac is offline." }
        switch status {
        case .idle: return nil
        case .starting: return "This session is still starting."
        case .running: return "The agent is working. You can send when it is idle."
        case .waitingUser: return "Answer the question or approval before sending another message."
        case .completed: return "This session has ended."
        case .failed: return "This session failed."
        case .cancelled: return "This session was cancelled."
        }
    }

    private func retreatOneLevel() {
        let leavesFile = workspace.level.depth == 2
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86), completionCriteria: .logicallyComplete) {
            workspace.goBack()
        } completion: {
            if leavesFile { workspace.finishFileDismissal() }
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { connection.draft(for: session.id) },
            set: { connection.updateDraft($0, for: session.id) }
        )
    }

    private func addReferenceToDraft(_ reference: String) {
        connection.appendToDraft(reference, for: session.id)
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
            workspace.returnToSession()
        }
    }

    private func openChangedFile(_ relativePath: String) {
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
            workspace.showChanges()
        }
        changedFileNavigation.begin(path: relativePath, generation: connection.requestChanges(projectId: project.id))
        Task { @MainActor in
            await Task.yield()
            completeChangedFileNavigation(connection.changesCompletion(projectId: project.id))
        }
    }

    private func openReportFile(_ relativePath: String) {
        workspace.prepareFile(TextFileSelection(project: project, relativePath: relativePath))
        Task { @MainActor in
            await Task.yield()
            withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
                workspace.activatePreparedFile()
            }
        }
    }

    private func completeChangedFileNavigation(_ completion: ChangesRequestCompletion?) {
        guard let change = changedFileNavigation.consume(
            completion: completion,
            response: connection.changes(projectId: project.id)
        ) else { return }
        workspace.showChanges()
        connection.requestDiff(projectId: project.id, change: change)
        workspace.prepareDiff(change)
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) { workspace.activatePreparedDiff() }
    }
}

private struct FeedBlock: View {
    @EnvironmentObject private var connection: MobileConnection
    let item: FeedItem
    let session: Session
    let project: RemoteProject
    let openChangedFile: (String) -> Void
    let openReportFile: (String) -> Void

    @ViewBuilder var body: some View {
        switch item.content {
        case let .text(role, content, markdown):
            MessageBlock(role: role, content: content, markdown: markdown)
        case let .event(event):
            switch event {
            case let .toolStarted(value): ToolBlock(name: value.title ?? value.toolName, detail: jsonText(value.input), running: true, error: false)
            case let .toolFinished(value): ToolBlock(name: value.toolName, detail: value.error ?? jsonText(value.output), running: false, error: value.error != nil)
            case let .command(value): CommandBlock(event: value)
            case let .approvalRequested(value): ApprovalBlock(event: value, session: session, historicallyResolved: connection.isHistoricallyResolved(sessionId: session.id, interactionId: value.interactionId))
            case let .questionRequested(value): QuestionBlock(event: value, session: session, historicallyResolved: connection.isHistoricallyResolved(sessionId: session.id, interactionId: value.interactionId))
            case let .error(value): NoticeBlock(icon: "exclamationmark.triangle.fill", title: value.message, detail: value.code, color: .red)
            case let .status(value): NoticeBlock(icon: "circle.dotted", title: value.message ?? sessionStatusLabel(value.status), detail: nil, color: .secondary)
            case let .fileChanged(value):
                Button { openChangedFile(value.relativePath) } label: {
                    NoticeBlock(icon: "doc.badge.gearshape", title: value.relativePath, detail: "\(value.change.rawValue.capitalized) · View diff", color: .orange)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("View diff")
                .buttonStyle(.plain)
                .accessibilityIdentifier("file-changed-\(value.relativePath)")
            case let .report(value):
                ReportBlock(
                    event: value,
                    expanded: connection.isReportExpanded(sessionId: session.id, reportId: value.reportId),
                    toggleExpanded: { expanded in
                        connection.setReportExpanded(expanded, sessionId: session.id, reportId: value.reportId)
                    },
                    openFile: openReportFile
                )
            case let .turnCompleted(value): NoticeBlock(icon: "checkmark.circle", title: "Turn \(value.outcome.rawValue)", detail: nil, color: outcomeColor(value.outcome.rawValue))
            case let .sessionCompleted(value): NoticeBlock(icon: "checkmark.seal", title: "Session \(value.outcome.rawValue)", detail: nil, color: outcomeColor(value.outcome.rawValue))
            case .sessionStarted: NoticeBlock(icon: "play.circle", title: "Session started", detail: nil, color: .green)
            case .textDelta, .message: EmptyView()
            }
        }
    }
}

private struct MessageBlock: View {
    let role: MessageEvent.Role
    let content: String
    let markdown: Bool

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 44) }
            Group {
                if markdown, let attributed = try? AttributedString(markdown: content) { Text(attributed) }
                else { Text(content) }
            }
            .textSelection(.enabled)
            .padding(12)
            .background(role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            if role != .user { Spacer(minLength: 44) }
        }
    }
}

private struct ToolBlock: View {
    let name: String
    let detail: String?
    let running: Bool
    let error: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Image(systemName: error ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver"); Text(name).font(.headline); Spacer(); if running { ProgressView() } }
            if let detail, !detail.isEmpty { Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(12)
        .background(error ? Color.red.opacity(0.08) : Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CommandBlock: View {
    let event: CommandEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Image(systemName: "terminal"); Text(event.command).font(.callout.monospaced()).textSelection(.enabled); Spacer() }
            Text(commandSummary).font(.caption).foregroundStyle(event.status == .failed ? .red : .secondary)
        }
        .padding(12)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private var commandSummary: String {
        if let exitCode = event.exitCode { return "\(event.status.rawValue.capitalized) · exit \(exitCode)" }
        return event.status.rawValue.capitalized
    }
}

private struct ApprovalBlock: View {
    @EnvironmentObject private var connection: MobileConnection
    let event: ApprovalRequestedEvent
    let session: Session
    let historicallyResolved: Bool
    private var inactive: Bool { historicallyResolved || connection.isResponding(sessionId: session.id, interactionId: event.interactionId) || connection.isSubmitted(sessionId: session.id, interactionId: event.interactionId) || connection.isResolved(sessionId: session.id, interactionId: event.interactionId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(event.title, systemImage: "checkmark.shield").font(.headline)
            if let description = event.description { Text(description).foregroundStyle(.secondary) }
            if let command = event.command { Text(command).font(.callout.monospaced()).textSelection(.enabled) }
            HStack {
                ForEach(event.actions, id: \.rawValue) { action in
                    Button(actionLabel(action)) { respond(action) }
                        .buttonStyle(.bordered)
                        .tint(action == .reject ? Color.red : Color.accentColor)
                        .disabled(inactive)
                }
            }
            if historicallyResolved || connection.isResolved(sessionId: session.id, interactionId: event.interactionId) { Label("Responded", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            else if connection.isSubmitted(sessionId: session.id, interactionId: event.interactionId) { Label("Response submitted", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func respond(_ action: ApprovalAction) {
        connection.respondToApproval(session: session, interactionId: event.interactionId, action: action)
    }
}

private struct QuestionBlock: View {
    @EnvironmentObject private var connection: MobileConnection
    let event: QuestionRequestedEvent
    let session: Session
    let historicallyResolved: Bool
    @State private var selected: Set<String> = []
    @State private var freeText = ""
    @FocusState private var freeTextFocused: Bool
    private var inactive: Bool { historicallyResolved || connection.isResponding(sessionId: session.id, interactionId: event.interactionId) || connection.isSubmitted(sessionId: session.id, interactionId: event.interactionId) || connection.isResolved(sessionId: session.id, interactionId: event.interactionId) }
    private var needsAnswer: Bool { selected.isEmpty && freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var submitHint: String {
        let hasOptions = !(event.options ?? []).isEmpty
        if hasOptions && event.allowFreeText { return "Select one or more options, or write an answer, to submit." }
        if hasOptions { return "Select one or more options to submit." }
        return "Write an answer to submit."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(event.question, systemImage: "questionmark.bubble").font(.headline)
            ForEach(event.options ?? [], id: \.id) { option in
                Button {
                    if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: selected.contains(option.id) ? "checkmark.square.fill" : "square")
                        VStack(alignment: .leading) { Text(option.label); if let description = option.description { Text(description).font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(inactive)
                .accessibilityIdentifier("question-option-\(option.id)")
                .accessibilityHint("Selects more than one option")
            }
            if event.allowFreeText {
                TextField("Your answer", text: $freeText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($freeTextFocused)
                    .disabled(inactive)
            }
            Button("Submit") {
                freeTextFocused = false
                connection.respondToQuestion(session: session, interactionId: event.interactionId, optionIds: Array(selected), freeText: freeText)
            }
            .buttonStyle(.borderedProminent)
            .disabled(inactive || needsAnswer)
            .accessibilityIdentifier("question-submit-\(event.interactionId)")
            if !inactive && needsAnswer {
                Text(submitHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if historicallyResolved || connection.isResolved(sessionId: session.id, interactionId: event.interactionId) { Label("Responded", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            else if connection.isSubmitted(sessionId: session.id, interactionId: event.interactionId) { Label("Response submitted", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct NoticeBlock: View {
    let icon: String
    let title: String
    let detail: String?
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) { Text(title); if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) } }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StatusBadge: View {
    let status: SessionStatus
    var body: some View {
        Text(sessionStatusLabel(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(statusColor(status))
            .background(statusColor(status).opacity(0.12), in: Capsule())
    }
}

struct FeedItem: Identifiable {
    enum Content { case text(MessageEvent.Role, String, Bool); case event(AgentEvent) }
    let id: String
    var content: Content
    var streaming: Bool
}

func feedItems(_ events: [AgentEvent]) -> [FeedItem] {
    var items: [FeedItem] = []
    for event in events.sorted(by: { $0.sequence < $1.sequence }) {
        appendFeedEvent(event, to: &items)
    }
    return items
}

func appendFeedEvent(_ event: AgentEvent, to items: inout [FeedItem]) {
    switch event {
    case let .textDelta(value):
        if let last = items.indices.last, items[last].streaming,
           case let .text(role, content, markdown) = items[last].content {
            items[last].content = .text(role, content + value.content, markdown)
        } else {
            items.append(.init(id: "stream-\(value.sequence)", content: .text(.agent, value.content, true), streaming: true))
        }
    case let .message(value):
        if value.role == .agent, let last = items.indices.last, items[last].streaming {
            items[last].content = .text(.agent, value.content, value.format == .markdown)
            items[last].streaming = false
        } else {
            items.append(.init(id: "event-\(value.sequence)", content: .text(value.role, value.content, value.format == .markdown), streaming: false))
        }
    default:
        if let last = items.indices.last { items[last].streaming = false }
        items.append(.init(id: "event-\(event.sequence)", content: .event(event), streaming: false))
    }
}

private func canSend(_ status: SessionStatus) -> Bool { status == .idle }

func sessionStatusLabel(_ status: SessionStatus) -> String {
    switch status {
    case .starting: "Starting"
    case .running: "Running"
    case .idle: "Idle"
    case .waitingUser: "Waiting for you"
    case .completed: "Completed"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
}

func sessionStatusLabel(_ status: StatusEvent.Status) -> String {
    switch status {
    case .running: "Running"
    case .idle: "Idle"
    case .waitingUser: "Waiting for you"
    }
}

private func statusColor(_ status: SessionStatus) -> Color {
    switch status {
    case .starting: .orange
    case .running: .blue
    case .idle: .green
    case .waitingUser: .purple
    case .completed: .green
    case .failed: .red
    case .cancelled: .secondary
    }
}

private func outcomeColor(_ outcome: String) -> Color { outcome == "failed" ? .red : outcome == "cancelled" ? .secondary : .green }

private func actionLabel(_ action: ApprovalAction) -> String {
    switch action { case .approveOnce: "Approve Once"; case .approveSession: "Approve Session"; case .reject: "Reject" }
}

private func jsonText(_ value: JSONValue?) -> String? {
    guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}
