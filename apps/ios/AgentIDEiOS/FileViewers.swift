import AgentIDEProtocol
import SwiftUI
import UIKit

enum AgentFileReference {
    static func format(relativePath: String) -> String? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("\\"),
              !relativePath.contains("\\") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return "@\(relativePath)"
    }
}

private struct FileActionsMenu<Label: View>: View {
    let name: String
    let relativePath: String
    let sendToAgent: ((String) -> Void)?
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Button("Copy File Name") { UIPasteboard.general.string = name }
            Button("Copy Relative Path") { UIPasteboard.general.string = relativePath }
            if let reference = AgentFileReference.format(relativePath: relativePath) {
                Button("Copy Agent Reference") { UIPasteboard.general.string = reference }
                    .accessibilityIdentifier("copy-agent-reference")
                if let sendToAgent {
                    Button("Add Reference to Draft") { sendToAgent(reference) }
                        .accessibilityIdentifier("send-reference-to-agent")
                }
            }
        } label: {
            label()
        }
        .accessibilityLabel("File actions")
        .accessibilityIdentifier("file-actions")
    }
}

struct TextFileSelection: Codable, Hashable {
    let projectId: String
    let name: String
    let relativePath: String
    let isMarkdown: Bool

    init(project: RemoteProject, entry: FileEntry) {
        projectId = project.id
        name = entry.name
        relativePath = entry.relativePath
        isMarkdown = entry.extension?.lowercased() == "md"
    }

    init(project: RemoteProject, relativePath: String) {
        projectId = project.id
        name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        self.relativePath = relativePath
        isMarkdown = relativePath.split(separator: ".").last?.lowercased() == "md"
    }
}

struct ImageFileSelection: Codable, Identifiable, Equatable {
    let projectId: String
    let name: String
    let relativePath: String
    var id: String { "\(projectId):\(relativePath)" }

    init(project: RemoteProject, entry: FileEntry) {
        projectId = project.id
        name = entry.name
        relativePath = entry.relativePath
    }
}

struct TextFileViewer: View {
    @EnvironmentObject private var connection: MobileConnection
    let selection: TextFileSelection
    let sendToAgent: ((String) -> Void)?

    init(selection: TextFileSelection, sendToAgent: ((String) -> Void)? = nil) {
        self.selection = selection
        self.sendToAgent = sendToAgent
    }

    var body: some View {
        VStack(spacing: 0) {
            if let subtitle = FileRowPresentation.subtitle(name: selection.name, relativePath: selection.relativePath) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .belowWorkspaceNavigationBar()
        .navigationTitle(selection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            FileActionsMenu(
                name: selection.name,
                relativePath: selection.relativePath,
                sendToAgent: sendToAgent
            ) {
                Image(systemName: "ellipsis.circle")
            }
        }
        .task {
            connection.requestFile(projectId: selection.projectId, relativePath: selection.relativePath, binary: false)
        }
    }

    @ViewBuilder private var content: some View {
        if let file = connection.fileContent(projectId: selection.projectId, path: selection.relativePath) {
            if selection.isMarkdown { MarkdownContent(content: file.content) }
            else { SourceContent(content: file.content) }
        } else if let error = connection.fileError(projectId: selection.projectId, path: selection.relativePath) {
            unavailable(title: "File Unavailable", icon: "doc.questionmark", error: MobileFailureCopy.message(error)) {
                connection.requestFile(projectId: selection.projectId, relativePath: selection.relativePath, binary: false)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func unavailable(title: String, icon: String, error: String, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(error)
        } actions: {
            Button("Retry", action: retry).buttonStyle(.borderedProminent)
        }
    }
}

private struct MarkdownContent: View {
    let content: String
    var body: some View {
        ScrollView {
            Text(MarkdownRendering.attributed(content))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum MarkdownRendering {
    /// SwiftUI Text draws markdown blocks without the newline that separated a heading from the next paragraph.
    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return AttributedString(markdown)
        }
        var result = AttributedString()
        var previousIdentity: Int?
        for run in parsed.runs {
            let identity = blockIdentity(run.presentationIntent)
            if let identity, let previousIdentity, identity != previousIdentity {
                result.append(AttributedString("\n\n"))
            }
            if let identity { previousIdentity = identity }
            result.append(AttributedString(parsed[run.range]))
        }
        return result.characters.isEmpty ? AttributedString(markdown) : result
    }

    private static func blockIdentity(_ intent: PresentationIntent?) -> Int? {
        intent?.components.first { component in
            switch component.kind {
            case .paragraph, .header, .codeBlock, .blockQuote, .thematicBreak, .listItem, .table:
                true
            default:
                false
            }
        }?.identity
    }
}

private struct SourceContent: View {
    let content: String
    private var lines: [String] {
        let split = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return split.isEmpty ? [""] : split
    }
    var body: some View {
        // 88 is the line number, rule, spacing, and padding. A sentence uses the remaining width; a longer line scrolls inside it and its number stays put.
        GeometryReader { geo in
            let textWidth = max(40, geo.size.width - 88)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 24, alignment: .trailing)
                                .accessibilityIdentifier("source-line-number-\(index + 1)")
                            Rectangle().fill(.quaternary).frame(width: 1)
                            lineBody(line, width: textWidth, identifier: "source-line-\(index + 1)")
                        }
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .padding()
            }
            .defaultScrollAnchor(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func lineBody(_ line: String, width: CGFloat, identifier: String) -> some View {
        let shown = line.isEmpty ? " " : line
        if line.isEmpty || SourceLineLayout.wraps(line) {
            Text(shown)
                .frame(width: width, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        } else {
            ScrollView(.horizontal) {
                Text(shown)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(identifier)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .defaultScrollAnchor(.leading)
            .scrollIndicators(.visible)
        }
    }
}

struct ImageViewer: View {
    @EnvironmentObject private var connection: MobileConnection
    @Environment(\.dismiss) private var dismiss
    let selection: ImageFileSelection
    let sendToAgent: ((String) -> Void)?
    @State private var selectedPath: String
    @State private var imageIsZoomed = false

    init(selection: ImageFileSelection, sendToAgent: ((String) -> Void)? = nil) {
        self.selection = selection
        self.sendToAgent = sendToAgent
        _selectedPath = State(initialValue: selection.relativePath)
    }

    private var entries: [FileEntry] {
        connection.imageList(projectId: selection.projectId, path: selection.relativePath)?.siblings ?? []
    }
    private var selectedName: String {
        entries.first(where: { $0.relativePath == selectedPath })?.name ?? selection.name
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if entries.isEmpty {
                imageListPlaceholder
            } else {
                TabView(selection: $selectedPath) {
                    ForEach(entries, id: \.relativePath) { entry in
                        ZoomableRemoteImage(projectId: selection.projectId, entry: entry) { zoomed in
                            if selectedPath == entry.relativePath { imageIsZoomed = zoomed }
                        }
                            .tag(entry.relativePath)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .scrollDisabled(imageIsZoomed)
            }
            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle()) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedName).font(.headline)
                        Text(selectedPath).font(.caption).lineLimit(1)
                    }
                    Spacer()
                    FileActionsMenu(name: selectedName, relativePath: selectedPath, sendToAgent: sendToAgent) {
                        Image(systemName: "ellipsis")
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .foregroundStyle(.white)
                .padding()
                Spacer()
            }
        }
        .statusBarHidden(true)
        .task {
            connection.requestImages(projectId: selection.projectId, relativePath: selection.relativePath)
            connection.requestFile(projectId: selection.projectId, relativePath: selection.relativePath, binary: true)
        }
        .onChange(of: selectedPath) { _, path in
            imageIsZoomed = false
            requestWindow(around: path)
        }
        .onChange(of: entries.map(\.relativePath), initial: true) { _, _ in
            requestWindow(around: selectedPath)
        }
        .onDisappear {
            connection.releaseImages(projectId: selection.projectId,
                                     paths: Array(Set(entries.map(\.relativePath) + [selection.relativePath])))
        }
    }

    @ViewBuilder private var imageListPlaceholder: some View {
        if let error = connection.imageListError(projectId: selection.projectId, path: selection.relativePath) {
            ContentUnavailableView {
                Label("Images Unavailable", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(MobileFailureCopy.message(error))
            } actions: {
                Button("Retry") {
                    connection.requestImages(projectId: selection.projectId, relativePath: selection.relativePath)
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        } else {
            ProgressView().tint(.white)
        }
    }

    private func requestWindow(around path: String) {
        guard let index = entries.firstIndex(where: { $0.relativePath == path }) else { return }
        for candidate in max(0, index - 1)...min(entries.count - 1, index + 1) {
            connection.requestFile(projectId: selection.projectId, relativePath: entries[candidate].relativePath, binary: true)
        }
    }
}

private struct ZoomableRemoteImage: View {
    @EnvironmentObject private var connection: MobileConnection
    let projectId: String
    let entry: FileEntry
    let onZoomChange: (Bool) -> Void
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Group {
            if let image = connection.image(projectId: projectId, path: entry.relativePath) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(scale).offset(offset)
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2
                            settledScale = scale
                            if scale == 1 { offset = .zero; settledOffset = .zero }
                            onZoomChange(scale > 1)
                        }
                    }
                    .simultaneousGesture(magnifyGesture)
                    .highPriorityGesture(dragGesture, including: scale > 1 ? .all : .none)
            } else if let error = connection.fileError(projectId: projectId, path: entry.relativePath) {
                ContentUnavailableView {
                    Label("Image Unavailable", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(MobileFailureCopy.message(error))
                } actions: {
                    Button("Retry") { connection.requestFile(projectId: projectId, relativePath: entry.relativePath, binary: true) }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .padding(.vertical, 64)
        .onDisappear { onZoomChange(false) }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(settledScale * value, 1), 5)
                onZoomChange(scale > 1)
            }
            .onEnded { _ in
                settledScale = scale
                if scale == 1 { offset = .zero; settledOffset = .zero }
                onZoomChange(scale > 1)
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: settledOffset.width + value.translation.width,
                                height: settledOffset.height + value.translation.height)
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                settledOffset = offset
            }
    }
}
