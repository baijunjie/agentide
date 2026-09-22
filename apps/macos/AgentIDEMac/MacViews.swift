import AgentIDEProtocol
import SwiftUI

private enum MacSection { case pairing, projects }

struct MacHomeView: View {
    @EnvironmentObject private var connection: MacConnection
    @State private var section = MacSection.pairing
    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("Pairing", systemImage: "link").tag(MacSection.pairing)
                Label("Projects", systemImage: "folder").tag(MacSection.projects)
            }.navigationTitle("AgentIDE")
        } detail: {
            if section == .pairing { PairingView() } else { ProjectListView() }
        }.frame(minWidth: 760, minHeight: 560)
    }
}

private struct PairingView: View {
    @EnvironmentObject private var connection: MacConnection
    var body: some View {
        VStack(spacing: 18) {
            Text("Pair iPhone").font(.largeTitle.bold())
            Label(connection.connectionState, systemImage: connection.connectionState == "Connected" ? "network" : "network.slash")
            TextField("Relay server", text: $connection.server).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
            if let pairing = connection.pairing {
                QRCode(value: pairing.qrPayload).frame(width: 220, height: 220)
                Text(pairing.secret.prefix(8)).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let expiry = ISO8601DateFormatter().date(from: pairing.expiresAt) ?? context.date
                    Text("Expires in \(max(0, Int(expiry.timeIntervalSince(context.date)))) seconds").foregroundStyle(.secondary)
                }
            }
            Button(connection.pairing == nil ? "Create Pairing Code" : "Refresh Pairing Code") { Task { await connection.preparePairing() } }.buttonStyle(.borderedProminent)
            ForEach(connection.devices) { device in
                HStack {
                    Label("\(device.name) — \(device.online ? "Connected" : "Offline")", systemImage: device.online ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    Button("Revoke") { Task { await connection.revoke(device) } }
                }
            }
            if let error = connection.error { Text(error).foregroundStyle(.red) }
        }.padding(36)
    }
}

private struct ProjectListView: View {
    @EnvironmentObject private var connection: MacConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Projects").font(.largeTitle.bold())
                Spacer()
                Button("Add Project", systemImage: "plus") { Task { await connection.addProject() } }.buttonStyle(.borderedProminent)
            }
            List(connection.projects, id: \.id) { project in ProjectRow(project: project) }
            if let error = connection.error { Text(error).foregroundStyle(.red) }
        }.padding(28)
    }
}

private struct ProjectRow: View {
    @EnvironmentObject private var connection: MacConnection
    let project: Project
    @State private var name = ""
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            VStack(alignment: .leading) {
                TextField("Project name", text: $name).onAppear { name = project.name }
                Text(project.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(project.enabledAgents.isEmpty ? "No Agent detected" : project.enabledAgents.map(\.rawValue).joined(separator: " · ")).font(.caption)
            }
            Label(connection.connectionState == "Connected" ? "Online" : "Offline", systemImage: connection.connectionState == "Connected" ? "circle.fill" : "circle")
                .foregroundStyle(connection.connectionState == "Connected" ? .green : .secondary)
            Button("Save") { Task { await connection.renameProject(project, name: name) } }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == project.name)
            Button("Remove", role: .destructive) { Task { await connection.removeProject(project) } }
        }.padding(.vertical, 6)
    }
}
