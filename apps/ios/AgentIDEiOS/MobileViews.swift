import AgentIDEProtocol
import SwiftUI
import UIKit

struct MobileHomeView: View {
    @EnvironmentObject private var connection: MobileConnection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scanning = false
    @State private var confirmingUnpair = false
    var body: some View {
        NavigationStack {
            if connection.paired { projectList } else { pairingPrompt }
        }
        .sheet(isPresented: $scanning) {
            ScannerSheet { value in
                scanning = false
                Task { await connection.claim(qrValue: value) }
            }
        }
        // A confirmation dialog treats the cancel role as a dismiss gesture, so Cancel is absent from the dialog and the accessibility tree.
        .alert("Unpair this iPhone?", isPresented: $confirmingUnpair) {
            Button("Unpair", role: .destructive) { Task { await connection.revokeSelf() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This phone will need a new pairing code from AgentIDE on your Mac.")
        }
        .alert("Could not unpair this iPhone", isPresented: unpairFailurePresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connection.unpairFailure ?? "")
        }
    }
    private var unpairFailurePresented: Binding<Bool> {
        Binding(
            get: { connection.unpairFailure != nil },
            set: { if !$0 { connection.unpairFailure = nil } }
        )
    }

    private var projectList: some View {
        List {
            if connection.online, let error = connection.error {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MobileFailureCopy.message(error)).foregroundStyle(.red)
                        Button("Retry") { connection.requestProjects() }
                    }
                }
            } else {
                Section {
                    Label(connection.online ? "Mac Online" : "Mac Offline", systemImage: connection.online ? "desktopcomputer.and.macbook" : "desktopcomputer")
                        .foregroundStyle(connection.online ? .green : .secondary)
                        .accessibilityLabel(connection.online ? "Mac Online" : "Mac Offline")
                }
                Section("Projects") {
                    if connection.projects.isEmpty {
                        ContentUnavailableView("No Projects", systemImage: "folder", description: Text(connection.online ? "Add a project on your Mac." : "Projects appear when your Mac is online."))
                    }
                    ForEach(connection.projects) { project in
                        NavigationLink(value: project.id) {
                            projectRow(project)
                        }
                    }
                }
            }
            Section("This iPhone") {
                deviceIdentifier
                Text("This identifier is for this iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Unpair this iPhone", role: .destructive) { confirmingUnpair = true }
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { connection.requestProjects() }
        .navigationDestination(for: String.self) { id in
            if let project = connection.projects.first(where: { $0.id == id }) { SessionListView(project: project) }
        }
    }

    @ViewBuilder private var deviceIdentifier: some View {
        let identifier = connection.localDeviceId
        let shown = DeviceIdentifierDisplay.visible(identifier)
        let text = Text(shown)
            .font(.caption.monospaced())
            .accessibilityLabel(identifier)
            .contextMenu {
                Button("Copy") { UIPasteboard.general.string = identifier }
            }
        // Selecting a shortened line would copy the shortened form. The menu copies the original string.
        if shown == identifier { text.textSelection(.enabled) } else { text }
    }

    @ViewBuilder private func projectRow(_ project: RemoteProject) -> some View {
        let agents = project.enabledAgents.map { $0.rawValue.capitalized }.joined(separator: " · ")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(agents).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    projectPresence(project)
                }
            }
        } else {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text(project.name)
                    Text(agents).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                projectPresence(project)
            }
        }
    }

    private func projectPresence(_ project: RemoteProject) -> some View {
        let online = project.online && connection.online
        return HStack(spacing: 4) {
            Circle().fill(online ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(online ? "Online" : "Offline").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(online ? "Online" : "Offline")
    }

    private var pairingPrompt: some View {
        VStack(spacing: 24) {
            Image(systemName: "desktopcomputer").font(.system(size: 72)).foregroundStyle(.secondary)
            Text("No Mac paired").font(.title2.bold())
            Text("On your Mac, open AgentIDE and choose Pairing. Create a pairing code, then scan its QR code here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Scan Pairing QR") { scanning = true }.buttonStyle(.borderedProminent)
            if let error = connection.error { Text(error).foregroundStyle(.red) }
        }
        .padding()
        .navigationTitle("AgentIDE")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FileBrowserView: View {
    let project: RemoteProject
    @State private var selectedText: TextFileSelection?
    @State private var selectedImage: ImageFileSelection?

    var body: some View {
        FileBrowserContent(
            project: project,
            openText: { selectedText = $0 },
            openImage: { selectedImage = $0 }
        )
        .navigationTitle(project.name)
        .toolbar {
            NavigationLink { ChangesView(project: project) } label: { Image(systemName: "arrow.triangle.branch") }
                .accessibilityLabel("Changes")
                .accessibilityIdentifier("file-browser-changes")
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedText != nil },
            set: { if !$0 { selectedText = nil } }
        )) {
            if let selectedText { TextFileViewer(selection: selectedText) }
        }
        .fullScreenCover(item: $selectedImage) { ImageViewer(selection: $0) }
    }
}

struct FileBrowserContent: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    let openText: (TextFileSelection) -> Void
    let openImage: (ImageFileSelection) -> Void
    @State private var expandedPaths: Set<String> = []
    @State private var scrollPosition: String?
    @State private var pendingScrollPosition: String?
    @State private var restorationQueue: [String] = []
    @State private var restoringPath: String?
    @State private var restoredRecoveryState = false
    @State private var searchQuery = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var locationError: String?

    init(project: RemoteProject, openText: @escaping (TextFileSelection) -> Void,
         openImage: @escaping (ImageFileSelection) -> Void) {
        self.project = project
        self.openText = openText
        self.openImage = openImage
        _expandedPaths = State(initialValue: [])
        _scrollPosition = State(initialValue: nil)
        _pendingScrollPosition = State(initialValue: nil)
        _restorationQueue = State(initialValue: [])
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("file-search-field")
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
            }

            if let locationError {
                Section {
                    Label(locationError, systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.orange)
                    Button("Dismiss") { self.locationError = nil }
                }
            }

            let trimmedQuery = projectFileSearchQueryTrimmingWhiteSpace(searchQuery)
            let scalarCount = trimmedQuery.unicodeScalars.count
            if scalarCount < 2 || scalarCount > 256 {
                if scalarCount > 0 {
                    Text(scalarCount < 2 ? "Enter at least two characters." : "Enter no more than 256 characters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("file-search-hint")
                }
                searchHistory
                fileTree
            } else {
                searchContent
            }
        }
        .animation(.easeInOut(duration: 0.2), value: connection.files.count)
        .scrollPosition(id: $scrollPosition)
        .task {
            restoreRecoveryState()
            _ = connection.fileSearchHistory(projectId: project.id)
            if connection.entries(projectId: project.id, path: "") == nil {
                connection.requestFiles(projectId: project.id, relativePath: "")
            }
            restoreNavigationIfPossible()
        }
        .onChange(of: connection.files.count) { restoreNavigationIfPossible() }
        .onChange(of: connection.directoryErrors.count) { restoreNavigationIfPossible() }
        .onChange(of: expandedPaths) { persistRecoveryState() }
        .onChange(of: scrollPosition) { persistRecoveryState() }
        .onChange(of: searchQuery) { _, query in scheduleSearch(query) }
        .onChange(of: connection.fileSearches[project.id]?.searchId) { _, searchId in
            guard searchId != nil, let response = connection.fileSearch(projectId: project.id) else { return }
            connection.recordFileSearch(projectId: project.id, query: response.query)
        }
        .onDisappear {
            searchDebounce?.cancel()
            connection.cancelFileSearch(projectId: project.id)
        }
    }

    @ViewBuilder private var searchHistory: some View {
        let history = connection.fileSearchHistories[project.id] ?? []
        if !history.isEmpty {
            Section("Recent Searches") {
                ForEach(history, id: \.self) { query in
                    Button {
                        searchQuery = query
                    } label: {
                        Label(query, systemImage: "clock.arrow.circlepath")
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            connection.removeFileSearchHistory(projectId: project.id, query: query)
                        }
                    }
                }
                Button("Clear Search History", role: .destructive) {
                    connection.clearFileSearchHistory(projectId: project.id)
                }
            }
        }
    }

    @ViewBuilder private var fileTree: some View {
        if connection.entries(projectId: project.id, path: "") == nil {
            if connection.isLoading(projectId: project.id, path: "") { ProgressView() }
            else if let error = connection.directoryError(projectId: project.id, path: "") {
                directoryError(error, path: "")
            }
        }
        ForEach(connection.entries(projectId: project.id, path: "") ?? [], id: \.relativePath) { entry in
            FileTreeRow(
                project: project,
                entry: entry,
                depth: 0,
                expandedPaths: $expandedPaths,
                openText: openText,
                openImage: openImage
            )
        }
    }

    @ViewBuilder private var searchContent: some View {
        let query = projectFileSearchQueryTrimmingWhiteSpace(searchQuery)
        if connection.isSearchingFiles(projectId: project.id) {
            ProgressView("Searching…").frame(maxWidth: .infinity)
        } else if let error = connection.fileSearchError(projectId: project.id) {
            ContentUnavailableView {
                Label("Search Unavailable", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(MobileFailureCopy.message(error.message, code: error.code))
            } actions: {
                Button("Retry") { connection.searchFiles(projectId: project.id, query: query) }
                    .buttonStyle(.borderedProminent)
            }
        } else if let response = connection.fileSearch(projectId: project.id) {
            if response.results.isEmpty {
                ContentUnavailableView.search(text: response.query)
            } else {
                Section {
                    ForEach(response.results, id: \.relativePath) { entry in
                        searchResult(entry)
                    }
                } footer: {
                    if response.hasMore { Text("More matches exist. Narrow your search.") }
                }
            }
        }
    }

    @ViewBuilder private func searchResult(_ entry: FileEntry) -> some View {
        let label = Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(.primary)
                if let subtitle = FileRowPresentation.subtitle(name: entry.name, relativePath: entry.relativePath) {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: searchResultIcon(entry)).foregroundStyle(entry.type == .directory ? .blue : .secondary)
        }
        Group {
            if entry.type == .directory {
                Button { locateDirectory(entry.relativePath) } label: { label }
            } else if entry.isImage == true {
                Button { openImage(.init(project: project, entry: entry)) } label: { label }
            } else if entry.isText == true {
                Button { openText(.init(project: project, entry: entry)) } label: { label }
            } else {
                label
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Name") { UIPasteboard.general.string = entry.name }
            Button("Copy Relative Path") { UIPasteboard.general.string = entry.relativePath }
        }
        .accessibilityIdentifier("file-search-result")
    }

    private func scheduleSearch(_ query: String) {
        searchDebounce?.cancel()
        connection.clearFileSearch(projectId: project.id)
        guard let normalized = normalizedProjectFileSearchQuery(query) else { return }
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            connection.searchFiles(projectId: project.id, query: normalized)
        }
    }

    private func locateDirectory(_ path: String) {
        searchQuery = ""
        locationError = nil
        var prefixes: [String] = []
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            prefixes.append(current)
        }
        expandedPaths.formUnion(prefixes)
        restorationQueue = prefixes
        pendingScrollPosition = path
        restoringPath = nil
        restoreNavigationIfPossible()
    }

    private func searchResultIcon(_ entry: FileEntry) -> String {
        if entry.type == .directory { return "folder" }
        if entry.isImage == true { return "photo" }
        if entry.extension?.lowercased() == "md" { return "doc.richtext" }
        if entry.isText == true { return "doc.text" }
        return "doc"
    }
    private func directoryError(_ message: String, path: String) -> some View {
        VStack(spacing: 8) {
            Label("Folder Unavailable", systemImage: "folder.badge.questionmark")
            Text(MobileFailureCopy.message(message)).font(.caption).foregroundStyle(.secondary)
            Button("Retry") { connection.requestFiles(projectId: project.id, relativePath: path) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }

    private func persistRecoveryState() {
        connection.persistFileBrowserNavigation(
            FileBrowserRecoveryState(expandedPaths: expandedPaths, scrollPosition: scrollPosition),
            for: project.id
        )
    }

    private func restoreRecoveryState() {
        guard !restoredRecoveryState else { return }
        restoredRecoveryState = true
        let state = connection.fileBrowserNavigation(for: project.id).trimmed()
        expandedPaths = state.expandedPaths
        pendingScrollPosition = state.scrollPosition
        restorationQueue = state.expandedPaths.sorted(by: FileBrowserRecoveryState.parentFirst)
    }

    private func restoreNavigationIfPossible() {
        if let restoringPath {
            let resolution = FileBrowserRestoringPathResolution.resolve(
                hasError: connection.directoryError(projectId: project.id, path: restoringPath) != nil,
                hasEntries: connection.entries(projectId: project.id, path: restoringPath) != nil
            )
            switch resolution {
            case .unavailable:
                self.restoringPath = nil
                removeUnavailablePath(restoringPath)
                locationError = "The folder is no longer available. Search again to refresh results."
            case .loaded:
                self.restoringPath = nil
            case .waiting:
                return
            }
        }

        while let nextPath = restorationQueue.first {
            let parentPath = FileBrowserRecoveryState.parentPath(of: nextPath)
            guard let parentEntries = connection.entries(projectId: project.id, path: parentPath) else { return }
            restorationQueue.removeFirst()
            guard parentEntries.contains(where: { $0.relativePath == nextPath && $0.type == .directory }) else {
                removeUnavailablePath(nextPath)
                locationError = "The folder is no longer available. Search again to refresh results."
                continue
            }
            if connection.entries(projectId: project.id, path: nextPath) == nil {
                restoringPath = nextPath
                connection.requestFiles(projectId: project.id, relativePath: nextPath)
                return
            }
        }

        guard let pendingScrollPosition else { return }
        if isVisible(path: pendingScrollPosition) { scrollPosition = pendingScrollPosition }
        self.pendingScrollPosition = nil
    }

    private func isVisible(path: String) -> Bool {
        let parentPath = FileBrowserRecoveryState.parentPath(of: path)
        return connection.entries(projectId: project.id, path: parentPath)?.contains(where: { $0.relativePath == path }) == true
    }

    private func removeUnavailablePath(_ path: String) {
        let state = FileBrowserRestorationState(
            expandedPaths: expandedPaths,
            pendingScrollPosition: pendingScrollPosition,
            restorationQueue: restorationQueue
        ).removingUnavailable(path)
        expandedPaths = state.expandedPaths
        pendingScrollPosition = state.pendingScrollPosition
        restorationQueue = state.restorationQueue
    }
}

struct FileBrowserRecoveryState: Codable {
    let expandedPaths: Set<String>
    let scrollPosition: String?

    func trimmed() -> FileBrowserRecoveryState {
        var retained = Set<String>()
        for path in expandedPaths.sorted(by: Self.parentFirst) {
            guard retained.count < MobileRecoveryLimits.expandedPathsPerProject else { break }
            let parent = Self.parentPath(of: path)
            if parent.isEmpty || retained.contains(parent) { retained.insert(path) }
        }
        let visibleScrollPosition = scrollPosition.flatMap { path in
            let parent = Self.parentPath(of: path)
            return parent.isEmpty || retained.contains(parent) ? path : nil
        }
        return FileBrowserRecoveryState(expandedPaths: retained, scrollPosition: visibleScrollPosition)
    }

    static func parentFirst(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = lhs.split(separator: "/").count
        let rhsDepth = rhs.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs < rhs
    }

    static func parentPath(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }

    static func collapsing(_ path: String, in expandedPaths: Set<String>) -> Set<String> {
        Set(expandedPaths.filter { $0 != path && !$0.hasPrefix("\(path)/") })
    }

    static func isInSubtree(_ path: String?, rootedAt root: String) -> Bool {
        guard let path else { return false }
        return path == root || path.hasPrefix("\(root)/")
    }
}

struct FileBrowserRestorationState: Equatable {
    var expandedPaths: Set<String>
    var pendingScrollPosition: String?
    var restorationQueue: [String]

    func removingUnavailable(_ path: String) -> FileBrowserRestorationState {
        FileBrowserRestorationState(
            expandedPaths: FileBrowserRecoveryState.collapsing(path, in: expandedPaths),
            pendingScrollPosition: FileBrowserRecoveryState.isInSubtree(pendingScrollPosition, rootedAt: path) ? nil : pendingScrollPosition,
            restorationQueue: restorationQueue.filter { !FileBrowserRecoveryState.isInSubtree($0, rootedAt: path) }
        )
    }
}

enum FileBrowserRestoringPathResolution: Equatable {
    case waiting
    case loaded
    case unavailable

    static func resolve(hasError: Bool, hasEntries: Bool) -> Self {
        if hasError { return .unavailable }
        return hasEntries ? .loaded : .waiting
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    let entry: FileEntry
    let depth: Int
    @Binding var expandedPaths: Set<String>
    let openText: (TextFileSelection) -> Void
    let openImage: (ImageFileSelection) -> Void
    private var expanded: Bool { expandedPaths.contains(entry.relativePath) }
    var body: some View {
        Group {
            rowAction.contextMenu {
                Button("Copy Name") { UIPasteboard.general.string = entry.name }
                Button("Copy Relative Path") { UIPasteboard.general.string = entry.relativePath }
            }
            if expanded {
                if connection.isLoading(projectId: project.id, path: entry.relativePath) { ProgressView().padding(.leading, CGFloat(depth + 1) * 18) }
                else if let error = connection.directoryError(projectId: project.id, path: entry.relativePath) {
                    HStack {
                        Text(MobileFailureCopy.message(error)).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { connection.requestFiles(projectId: project.id, relativePath: entry.relativePath) }
                    }
                    .padding(.leading, CGFloat(depth + 1) * 18)
                }
                ForEach(connection.entries(projectId: project.id, path: entry.relativePath) ?? [], id: \.relativePath) { child in
                    FileTreeRow(
                        project: project,
                        entry: child,
                        depth: depth + 1,
                        expandedPaths: $expandedPaths,
                        openText: openText,
                        openImage: openImage
                    )
                }
            }
        }
    }
    @ViewBuilder private var rowAction: some View {
        if entry.type == .directory {
            Button {
                let wasExpanded = expanded
                withAnimation {
                    if wasExpanded {
                        expandedPaths = FileBrowserRecoveryState.collapsing(entry.relativePath, in: expandedPaths)
                    }
                    else { expandedPaths.insert(entry.relativePath) }
                }
                if !wasExpanded && connection.entries(projectId: project.id, path: entry.relativePath) == nil {
                    connection.requestFiles(projectId: project.id, relativePath: entry.relativePath)
                }
            } label: { rowLabel }.buttonStyle(.plain)
        } else if entry.isImage == true {
            Button { openImage(.init(project: project, entry: entry)) } label: { rowLabel }.buttonStyle(.plain)
        } else if entry.isText == true {
            Button { openText(.init(project: project, entry: entry)) } label: { rowLabel }.buttonStyle(.plain)
        } else {
            rowLabel
        }
    }
    private var rowLabel: some View {
        HStack(spacing: 8) {
            if entry.type == .directory { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12) }
            else { Color.clear.frame(width: 12, height: 1) }
            Image(systemName: icon).foregroundStyle(entry.type == .directory ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 18)
        .id(entry.relativePath)
    }
    private var icon: String {
        if entry.type == .directory { return expanded ? "folder.fill" : "folder" }
        if entry.isImage == true { return "photo" }
        if entry.extension == "md" { return "doc.richtext" }
        if entry.isText == true { return "doc.text" }
        return "doc"
    }
}
