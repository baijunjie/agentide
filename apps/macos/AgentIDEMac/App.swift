import AgentIDEProtocol
import SwiftUI

@main
struct AgentIDEMacApp: App {
    var body: some Scene {
        WindowGroup {
            MacHomeView()
        }
    }
}

private struct MacHomeView: View {
    // TODO: Replace the skeleton content with live pairing and project state in milestones 02 and 03.
    var body: some View {
        NavigationSplitView {
            List {
                Label("Pairing", systemImage: "link")
                Label("Projects", systemImage: "folder")
            }
            .navigationTitle("AgentIDE")
        } detail: {
            ContentUnavailableView(
                "No iPhone connected",
                systemImage: "iphone.gen3",
                description: Text("Pair a device to access local projects and agent sessions.")
            )
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
