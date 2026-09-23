import AgentIDEProtocol
import SwiftUI
import UIKit

struct TextFileSelection: Hashable {
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
}

struct ImageFileSelection: Identifiable {
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.name).font(.headline)
                Text(selection.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            content
        }
        .navigationTitle(selection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Copy File Name") { UIPasteboard.general.string = selection.name }
                Button("Copy Relative Path") { UIPasteboard.general.string = selection.relativePath }
            } label: { Image(systemName: "ellipsis.circle") }
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
            unavailable(title: "File Unavailable", icon: "doc.questionmark", error: error) {
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
    private var rendered: AttributedString {
        (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }
    var body: some View {
        ScrollView {
            Text(rendered)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

private struct SourceContent: View {
    let content: String
    private var lineNumbers: String {
        let count = max(1, content.split(separator: "\n", omittingEmptySubsequences: false).count)
        return (1...count).map(String.init).joined(separator: "\n")
    }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
                Text(lineNumbers).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                Divider()
                Text(content).textSelection(.enabled)
            }
            .font(.system(size: 14, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ImageViewer: View {
    @EnvironmentObject private var connection: MobileConnection
    @Environment(\.dismiss) private var dismiss
    let selection: ImageFileSelection
    @State private var selectedPath: String
    @State private var imageIsZoomed = false

    init(selection: ImageFileSelection) {
        self.selection = selection
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
                    Menu {
                        Button("Copy File Name") { UIPasteboard.general.string = selectedName }
                        Button("Copy Relative Path") { UIPasteboard.general.string = selectedPath }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle()) }
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
                Text(error)
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
                    Text(error)
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
