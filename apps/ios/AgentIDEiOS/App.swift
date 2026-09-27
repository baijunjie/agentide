import SwiftUI

@main
struct AgentIDEiOSApp: App {
    @StateObject private var connection = MobileConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup { MobileHomeView().environmentObject(connection) }
            .onChange(of: scenePhase) { connection.handleScenePhase(scenePhase) }
    }
}
