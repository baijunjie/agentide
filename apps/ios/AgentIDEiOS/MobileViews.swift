import AgentIDEProtocol
import SwiftUI
import UIKit

struct MobileHomeView: View {
    @EnvironmentObject private var connection: MobileConnection
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            if connection.paired { projectList } else { pairingPrompt }
        }
        .navigationTitle("AgentIDE")
        .sheet(isPresented: $scanning) {
            QRScanner { value in scanning = false; Task { await connection.claim(qrValue: value) } }.ignoresSafeArea()
        }
    }
    private var projectList: some View {
        List {
            Section {
                Label(connection.online ? "Mac Online" : "Mac Offline", systemImage: connection.online ? "desktopcomputer.and.macbook" : "desktopcomputer")
                    .foregroundStyle(connection.online ? .green : .secondary)
            }
            Section("Projects") {
                if connection.projects.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "folder", description: Text(connection.online ? "Add a project on your Mac." : "Projects appear when your Mac is online."))
                }
                ForEach(connection.projects) { project in
                    NavigationLink(value: project.id) {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            VStack(alignment: .leading) { Text(project.name); Text(project.enabledAgents.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Circle().fill(project.online && connection.online ? .green : .gray).frame(width: 8, height: 8)
                        }
                    }
                }
            }
            if let error = connection.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .refreshable { connection.requestProjects() }
        .navigationDestination(for: String.self) { id in
            if let project = connection.projects.first(where: { $0.id == id }) { SessionListView(project: project) }
        }
    }
    private var pairingPrompt: some View {
        VStack(spacing: 24) {
            Image(systemName: "desktopcomputer").font(.system(size: 72)).foregroundStyle(.secondary)
            Text("No Mac paired").font(.title.bold())
            Button("Scan Pairing QR") { scanning = true }.buttonStyle(.borderedProminent)
            if let error = connection.error { Text(error).foregroundStyle(.red) }
        }
    }
}

struct FileBrowserView: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    @State private var expandedPaths: Set<String> = []
    @State private var scrollPosition: String?
    @State private var selectedImage: ImageFileSelection?
    var body: some View {
        List {
            if connection.entries(projectId: project.id, path: "") == nil {
                if connection.isLoading(projectId: project.id, path: "") { ProgressView() }
                else if let error = connection.directoryError(projectId: project.id, path: "") {
                    directoryError(error, path: "")
                }
            }
            ForEach(connection.entries(projectId: project.id, path: "") ?? [], id: \.relativePath) { entry in
                FileTreeRow(project: project, entry: entry, depth: 0, expandedPaths: $expandedPaths) { selectedImage = $0 }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: connection.files.count)
        .scrollPosition(id: $scrollPosition)
        .navigationTitle(project.name)
        .navigationDestination(for: TextFileSelection.self) { TextFileViewer(selection: $0) }
        .fullScreenCover(item: $selectedImage) { ImageViewer(selection: $0) }
        .task { if connection.entries(projectId: project.id, path: "") == nil { connection.requestFiles(projectId: project.id, relativePath: "") } }
    }
    private func directoryError(_ message: String, path: String) -> some View {
        VStack(spacing: 8) {
            Label("Folder Unavailable", systemImage: "folder.badge.questionmark")
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Retry") { connection.requestFiles(projectId: project.id, relativePath: path) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    let entry: FileEntry
    let depth: Int
    @Binding var expandedPaths: Set<String>
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
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { connection.requestFiles(projectId: project.id, relativePath: entry.relativePath) }
                    }
                    .padding(.leading, CGFloat(depth + 1) * 18)
                }
                ForEach(connection.entries(projectId: project.id, path: entry.relativePath) ?? [], id: \.relativePath) { child in
                    FileTreeRow(project: project, entry: child, depth: depth + 1, expandedPaths: $expandedPaths, openImage: openImage)
                }
            }
        }
    }
    @ViewBuilder private var rowAction: some View {
        if entry.type == .directory {
            Button {
                let wasExpanded = expanded
                withAnimation {
                    if wasExpanded { expandedPaths.remove(entry.relativePath) }
                    else { expandedPaths.insert(entry.relativePath) }
                }
                if !wasExpanded && connection.entries(projectId: project.id, path: entry.relativePath) == nil {
                    connection.requestFiles(projectId: project.id, relativePath: entry.relativePath)
                }
            } label: { rowLabel }.buttonStyle(.plain)
        } else if entry.isImage == true {
            Button { openImage(.init(project: project, entry: entry)) } label: { rowLabel }.buttonStyle(.plain)
        } else if entry.isText == true {
            NavigationLink(value: TextFileSelection(project: project, entry: entry)) { rowLabel }.buttonStyle(.plain)
        } else {
            rowLabel
        }
    }
    private var rowLabel: some View {
        HStack(spacing: 8) {
            if entry.type == .directory { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12) }
            else { Color.clear.frame(width: 12, height: 1) }
            Image(systemName: icon).foregroundStyle(entry.type == .directory ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) { Text(entry.name).foregroundStyle(.primary); Text(entry.relativePath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
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
