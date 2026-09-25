import AgentIDEProtocol
import SwiftUI

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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { FileBrowserView(project: project) } label: { Image(systemName: "folder") }
                Button { creating = true } label: { Image(systemName: "plus") }
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
                    TextEditor(text: $initialTask).frame(minHeight: 160)
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
    @State private var input = ""

    private var events: [AgentEvent] { connection.sessionEvents[session.id] ?? [] }
    private var status: SessionStatus { connection.status(for: session) }
    private var isSending: Bool { connection.activeSessionOperations.contains("send:\(session.id)") }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if events.isEmpty {
                            if connection.subscribingSessions.contains(session.id) {
                                ProgressView("Loading activity…").frame(maxWidth: .infinity).padding(.top, 40)
                            } else {
                                ContentUnavailableView("No Activity", systemImage: "clock.arrow.circlepath", description: Text("Retry to load this session's event history."))
                                Button("Retry") { connection.openSession(session) }.buttonStyle(.borderedProminent)
                            }
                        }
                        ForEach(connection.sessionFeedItems[session.id] ?? []) { item in
                            FeedBlock(item: item, session: session).id(item.id)
                        }
                        if let error = connection.sessionErrors[session.id] {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .padding(12)
                                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
                .onChange(of: events.last?.sequence) {
                    if let id = connection.sessionFeedItems[session.id]?.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message the agent", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canSend(status) || isSending)
                if status == .running {
                    Button { connection.cancel(session: session) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Cancel current turn")
                } else {
                    Button {
                        connection.sendMessage(session: session, content: input)
                    } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSend(status) || !connection.online || isSending)
                    .accessibilityLabel("Send message")
                }
            }
            .padding()
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { FileBrowserView(project: project) } label: { Image(systemName: "folder") }
            }
            ToolbarItem(placement: .principal) { StatusBadge(status: status) }
        }
        .task { connection.openSession(session) }
        .onChange(of: connection.acceptedMessage?.id) {
            guard let accepted = connection.acceptedMessage, accepted.sessionId == session.id else { return }
            if input.trimmingCharacters(in: .whitespacesAndNewlines) == accepted.content { input = "" }
        }
    }
}

private struct FeedBlock: View {
    @EnvironmentObject private var connection: MobileConnection
    let item: FeedItem
    let session: Session

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
            case let .status(value): NoticeBlock(icon: "circle.dotted", title: value.message ?? value.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, detail: nil, color: .secondary)
            case let .fileChanged(value): NoticeBlock(icon: "doc.badge.gearshape", title: value.relativePath, detail: value.change.rawValue.capitalized, color: .orange)
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
    private var inactive: Bool { historicallyResolved || connection.isResponding(sessionId: session.id, interactionId: event.interactionId) || connection.isSubmitted(sessionId: session.id, interactionId: event.interactionId) || connection.isResolved(sessionId: session.id, interactionId: event.interactionId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(event.question, systemImage: "questionmark.bubble").font(.headline)
            ForEach(event.options ?? [], id: \.id) { option in
                Button {
                    if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: selected.contains(option.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) { Text(option.label); if let description = option.description { Text(description).font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(inactive)
            }
            if event.allowFreeText { TextField("Your answer", text: $freeText, axis: .vertical).textFieldStyle(.roundedBorder).disabled(inactive) }
            Button("Submit") {
                connection.respondToQuestion(session: session, interactionId: event.interactionId, optionIds: Array(selected), freeText: freeText)
            }
            .buttonStyle(.borderedProminent)
            .disabled(inactive || (selected.isEmpty && freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
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
        Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
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
