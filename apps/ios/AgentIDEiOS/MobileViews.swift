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
            if let project = connection.projects.first(where: { $0.id == id }) { FileBrowserView(project: project) }
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

private struct FileBrowserView: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    var body: some View {
        List {
            if connection.isLoading(projectId: project.id, path: "") && connection.entries(projectId: project.id, path: "") == nil { ProgressView() }
            ForEach(connection.entries(projectId: project.id, path: "") ?? [], id: \.relativePath) { entry in FileTreeRow(project: project, entry: entry, depth: 0) }
        }
        .animation(.easeInOut(duration: 0.2), value: connection.files.count)
        .navigationTitle(project.name)
        .task { if connection.entries(projectId: project.id, path: "") == nil { connection.requestFiles(projectId: project.id, relativePath: "") } }
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject private var connection: MobileConnection
    let project: RemoteProject
    let entry: FileEntry
    let depth: Int
    @State private var expanded = false
    var body: some View {
        Group {
            Button {
                guard entry.type == .directory else { return }
                withAnimation { expanded.toggle() }
                if expanded && connection.entries(projectId: project.id, path: entry.relativePath) == nil { connection.requestFiles(projectId: project.id, relativePath: entry.relativePath) }
            } label: {
                HStack(spacing: 8) {
                    if entry.type == .directory { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12) }
                    else { Color.clear.frame(width: 12, height: 1) }
                    Image(systemName: icon).foregroundStyle(entry.type == .directory ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) { Text(entry.name).foregroundStyle(.primary); Text(entry.relativePath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    Spacer()
                }.padding(.leading, CGFloat(depth) * 18)
            }.buttonStyle(.plain).contextMenu {
                Button("Copy Name") { UIPasteboard.general.string = entry.name }
                Button("Copy Relative Path") { UIPasteboard.general.string = entry.relativePath }
            }
            if expanded {
                if connection.isLoading(projectId: project.id, path: entry.relativePath) { ProgressView().padding(.leading, CGFloat(depth + 1) * 18) }
                ForEach(connection.entries(projectId: project.id, path: entry.relativePath) ?? [], id: \.relativePath) { child in FileTreeRow(project: project, entry: child, depth: depth + 1) }
            }
        }
    }
    private var icon: String {
        if entry.type == .directory { return expanded ? "folder.fill" : "folder" }
        if entry.isImage == true { return "photo" }
        if entry.extension == "md" { return "doc.richtext" }
        if entry.isText == true { return "doc.text" }
        return "doc"
    }
}
