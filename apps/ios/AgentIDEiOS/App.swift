import AgentIDEProtocol
import SwiftUI

@main
struct AgentIDEiOSApp: App {
    var body: some Scene {
        WindowGroup {
            MobileHomeView()
        }
    }
}

private struct MobileHomeView: View {
    // TODO: Replace the skeleton content with live pairing, sessions, and files across milestones 02, 03, and 07.
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Mac paired",
                systemImage: "desktopcomputer",
                description: Text("Pair with AgentIDE on your Mac to browse projects and sessions.")
            )
            .navigationTitle("AgentIDE")
        }
    }
}
